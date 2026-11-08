// Bộ parse Ethernet / (VLAN) / IPv4 / UDP + decode ITCH, 64 bit (8 byte) MỖI CHU KỲ, gói chứa NHIỀU message.
//
// Khác eth_udp_itch_parser.v (1 byte/chu kỳ) ở ba điểm:
//   1. Datapath rộng: mỗi chu kỳ nhận một "từ" 8 byte. in_keep[k] = 1 nếu byte k (k = 0 là byte ĐẦU TIÊN theo thứ tự trên
//      dây = in_data[7:0], như AXI-Stream của MAC) hợp lệ. Chỉ từ cuối khung mới có thể keep thiếu (các byte thấp hợp lệ).
//   2. Hỗ trợ MỘT thẻ VLAN (0x8100) tuỳ chọn: mọi offset phía sau dịch +4 byte, ta theo dõi bằng `off`.
//   3. Payload UDP kiểu MoldUDP64 rút gọn: seq[8] | count[2] | { len[2] | message ITCH } x count.
//      seq là số thứ tự của message ĐẦU TIÊN; message thứ k mang seq + k. Cờ msg_gap tính theo từng message.
//
// Cách làm: giữ nguyên logic đếm vị trí byte của bản 1 byte/chu kỳ, nhưng MỞ VÒNG ("unroll"): trong một chu kỳ chạy logic
// đó 8 lần nối tiếp, mỗi lần cho một byte. Đây là kỹ thuật quen thuộc để nới rộng một FSM byte-nối-tiếp; cái giá là
// đường tổ hợp dài gấp 8 (Fmax sẽ thấp hơn bản 1 byte; trong thực tế người ta tách pha hoặc dùng mảng song song).
// Mỗi record dài >= 11 byte (2 byte độ dài + message D = 9 byte) > 8 nên MỘT TỪ chứa tối đa MỘT message hoàn chỉnh:
// đầu ra vẫn chỉ cần tối đa một message mỗi chu kỳ.
//
// Khung lỗi: nếu lỗi xuất hiện giữa gói, các message ĐÃ hoàn chỉnh trước đó vẫn được phát (chúng hợp lệ),
// rồi cuối khung báo drop_valid với lý do của lỗi đầu tiên. Message và drop có thể cùng chu kỳ (message trước, drop sau).
module eth_udp_itch_parser64 #(
    parameter [31:0] MCAST_IP = 32'hEF010101,  // 239.1.1.1
    parameter [15:0] UDP_PORT = 16'd30001
) (
    input  wire        clk,
    input  wire        rst,
    input  wire        in_valid,       // từ này có dữ liệu (chu kỳ rảnh: 0). Không có backpressure, như dữ liệu từ MAC.
    input  wire [63:0] in_data,
    input  wire [7:0]  in_keep,
    input  wire        in_last,        // từ cuối của khung
    output reg         msg_valid,
    output reg  [7:0]  msg_type,
    output reg  [63:0] seq,            // seq của RIÊNG message này
    output reg  [63:0] order_id,
    output reg  [7:0]  side,
    output reg  [31:0] qty,
    output reg  [63:0] symbol,
    output reg  [31:0] price,
    output reg  [63:0] match_no,
    output reg         msg_gap,
    output reg         drop_valid,
    output reg  [3:0]  drop_reason
);
    localparam [3:0] R_NONE = 4'd0, R_ETHERTYPE = 4'd1, R_IP_HDR = 4'd2, R_PROTO = 4'd3, R_IP_CSUM = 4'd4,
                     R_DST_IP = 4'd5, R_DST_PORT = 4'd6, R_LEN = 4'd7, R_MSG_TYPE = 4'd8, R_TRUNC = 4'd9;

    // ---- trạng thái; chỉ được gán trong MỘT khối always (gán blocking để nối tiếp 8 byte trong 1 chu kỳ) ----
    reg [15:0] idx;                  // vị trí byte trong khung
    reg [15:0] off;                  // 0, hoặc 4 nếu có thẻ VLAN
    reg [3:0]  err;                  // lỗi đầu tiên của khung
    reg [7:0]  prev;
    reg [19:0] csum;
    reg [15:0] ip_len, udp_len;
    reg [23:0] dst;
    reg [63:0] pseq;                 // seq của message đầu tiên trong gói
    reg [15:0] cnt, cnt_done;        // số message khai báo / đã xong
    reg [15:0] rec_pos, rec_len;     // vị trí trong record hiện tại (0,1 = 2 byte độ dài) và độ dài message
    reg        pdone;                // đã xử lý hết payload: bỏ qua phần đệm còn lại
    reg [7:0]  cur_type;
    reg [63:0] w_id, w_symbol, w_match;   // message đang ghép dở
    reg [7:0]  w_side;
    reg [31:0] w_qty, w_price;
    reg [63:0] exp_seq;
    reg        seq_seen;

    // ---- biến tạm trong một chu kỳ ----
    integer     i;
    reg [7:0]   b;
    reg [15:0]  rel, mp;
    reg [16:0]  f1;
    reg [15:0]  f2;
    reg         emit, adv;
    reg [7:0]   s_type, s_side;
    reg [63:0]  s_seq, s_id, s_symbol, s_match;
    reg [31:0]  s_qty, s_price;
    reg         s_gap;

    task setf(input [3:0] code);   // ghi lỗi nếu chưa có lỗi nào (giữ lỗi ĐẦU TIÊN)
        if (err == R_NONE) err = code;
    endtask

    // Gán BLOCKING có chủ đích: các biến trạng thái ở trên chỉ được dùng trong khối này, và việc nối tiếp 8 byte trong
    // một chu kỳ cần byte sau thấy kết quả của byte trước. Ngõ ra (msg_*, drop_*) vẫn dùng gán non-blocking.
    /* verilator lint_off BLKSEQ */
    always @(posedge clk) begin
        msg_valid  <= 1'b0;
        drop_valid <= 1'b0;
        if (rst) begin
            idx = 16'd0; off = 16'd0; err = R_NONE; csum = 20'd0; pdone = 1'b0; seq_seen = 1'b0;
            cnt = 16'd0; cnt_done = 16'd0; rec_pos = 16'd0; rec_len = 16'd0;
        end else if (in_valid) begin
            emit = 1'b0;
            for (i = 0; i < 8; i = i + 1) begin
                if (in_keep[i]) begin
                    b   = in_data[8*i +: 8];
                    rel = idx - off;

                    // ---- Ethernet / VLAN ----
                    if (idx == 16'd12) begin
                        if (b != 8'h08 && b != 8'h81) setf(R_ETHERTYPE);
                    end else if (idx == 16'd13) begin
                        if (prev == 8'h81) begin
                            if (b != 8'h00) setf(R_ETHERTYPE); else off = 16'd4;   // 0x8100: có VLAN
                        end else if (b != 8'h00) setf(R_ETHERTYPE);                // 0x0800 cần byte thứ hai = 0x00
                    end else if (off == 16'd4 && idx == 16'd16 && b != 8'h08) setf(R_ETHERTYPE);  // EtherType bên trong thẻ
                    else if (off == 16'd4 && idx == 16'd17 && b != 8'h00)      setf(R_ETHERTYPE);

                    // ---- IPv4 + UDP: từ đây dùng `rel` (đã trừ offset VLAN) với đúng các hằng số của bản 1 byte ----
                    if (idx >= 16'd14 && rel >= 16'd14) begin
                        if (rel == 16'd14 && b != 8'h45) setf(R_IP_HDR);
                        if (rel == 16'd17) ip_len = {prev, b};
                        if (rel == 16'd23 && b != 8'd17) setf(R_PROTO);
                        if (rel >= 16'd15 && rel <= 16'd33 && rel[0]) csum = csum + {4'd0, prev, b};
                        if (rel >= 16'd30 && rel <= 16'd32) dst = {dst[15:0], b};
                        if (rel == 16'd33) begin
                            f1 = {1'b0, csum[15:0]} + {13'd0, csum[19:16]};   // cuộn số nhớ (one's complement)
                            f2 = f1[15:0] + {15'd0, f1[16]};
                            if (f2 != 16'hFFFF)            setf(R_IP_CSUM);
                            else if ({dst, b} != MCAST_IP) setf(R_DST_IP);
                        end
                        if (rel == 16'd37 && {prev, b} != UDP_PORT) setf(R_DST_PORT);
                        if (rel == 16'd39) begin
                            udp_len = {prev, b};
                            if (ip_len != {prev, b} + 16'd20) setf(R_LEN);
                        end
                        if (rel >= 16'd42 && rel <= 16'd49) pseq = {pseq[55:0], b};
                        if (rel == 16'd51) begin                              // đủ 2 byte `count`
                            cnt = {prev, b}; cnt_done = 16'd0; rec_pos = 16'd0; pdone = 1'b0;
                            if ({prev, b} == 16'd0) begin                     // gói rỗng (heartbeat): phải hết payload ngay
                                if (rel + 16'd1 != udp_len + 16'd34) setf(R_LEN);
                                pdone = 1'b1;
                            end
                        end

                        // ---- các record { len[2] | message } ----
                        if (rel >= 16'd52 && !pdone && err == R_NONE) begin
                            adv = 1'b1;
                            if (rec_pos == 16'd0) rec_len[15:8] = b;
                            else if (rec_pos == 16'd1) rec_len[7:0] = b;
                            else begin
                                mp = rec_pos - 16'd2;                         // vị trí trong message (0 = byte loại)
                                if (mp == 16'd0) begin
                                    cur_type = b;
                                    w_id = 64'd0; w_side = 8'd0; w_qty = 32'd0; w_symbol = 64'd0; w_price = 32'd0; w_match = 64'd0;
                                    if (b == "A")      begin if (rec_len != 16'd26) setf(R_LEN); end
                                    else if (b == "E") begin if (rec_len != 16'd21) setf(R_LEN); end
                                    else if (b == "D") begin if (rec_len != 16'd9)  setf(R_LEN); end
                                    else setf(R_MSG_TYPE);
                                end else if (mp <= 16'd8) begin
                                    w_id = {w_id[55:0], b};
                                end else if (cur_type == "A") begin
                                    if (mp == 16'd9)        w_side = b;
                                    else if (mp <= 16'd13)  w_qty = {w_qty[23:0], b};
                                    else if (mp <= 16'd21)  w_symbol = {w_symbol[55:0], b};
                                    else                    w_price = {w_price[23:0], b};
                                end else if (cur_type == "E") begin
                                    if (mp <= 16'd12)       w_qty = {w_qty[23:0], b};
                                    else                    w_match = {w_match[55:0], b};
                                end

                                if (err == R_NONE && mp == rec_len - 16'd1) begin   // byte cuối của message: phát nó
                                    emit = 1'b1;
                                    s_type = cur_type; s_id = w_id; s_side = w_side; s_qty = w_qty;
                                    s_symbol = w_symbol; s_price = w_price; s_match = w_match;
                                    s_seq  = pseq + {48'd0, cnt_done};
                                    s_gap  = seq_seen && (s_seq != exp_seq);
                                    exp_seq = s_seq + 64'd1; seq_seen = 1'b1;
                                    cnt_done = cnt_done + 16'd1;
                                    rec_pos = 16'd0; adv = 1'b0;
                                    if (cnt_done == cnt) begin                      // message cuối của gói: payload phải kết thúc đúng chỗ
                                        pdone = 1'b1;
                                        if (rel + 16'd1 != udp_len + 16'd34) setf(R_LEN);
                                    end
                                end
                            end
                            if (adv) rec_pos = rec_pos + 16'd1;
                        end
                    end

                    prev = b;
                    if (idx != 16'hFFFF) idx = idx + 16'd1;
                end
            end

            if (emit) begin
                msg_valid <= 1'b1;
                msg_type  <= s_type;  seq <= s_seq;   order_id <= s_id;   side <= s_side;
                qty       <= s_qty;   symbol <= s_symbol; price <= s_price; match_no <= s_match;
                msg_gap   <= s_gap;
            end

            if (in_last) begin
                if (err != R_NONE) begin
                    drop_valid  <= 1'b1;
                    drop_reason <= err;
                end else if (!pdone) begin
                    drop_valid  <= 1'b1;
                    drop_reason <= R_TRUNC;
                end
                idx = 16'd0; off = 16'd0; err = R_NONE; csum = 20'd0; pdone = 1'b0;
            end
        end
    end
    /* verilator lint_on BLKSEQ */
endmodule
