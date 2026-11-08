// Bộ parse Ethernet / IPv4 / UDP + decode message ITCH rút gọn (xem server/itch.hpp).
//
// Giao diện: luồng byte 1 byte/chu kỳ, KHÔNG có backpressure (ready) - như dữ liệu từ MAC, phải xử lý
// kịp tốc độ đường truyền. Khung bắt đầu từ MAC đích, MAC đã bỏ preamble và FCS.
//
// Cách làm: đếm vị trí byte `idx` trong khung; mỗi trường nằm ở một offset CỐ ĐỊNH nên chỉ cần so
// `idx` với hằng số, không có vòng lặp hay tìm dấu phân cách. Đây là lý do giao thức nhị phân độ
// dài cố định hợp với phần cứng.
//
//   idx  0..5   MAC đích          idx 14..33  IPv4 header (20 byte, IHL=5)
//   idx  6..11  MAC nguồn           14: ver/IHL  16-17: total length  23: protocol
//   idx 12..13  EtherType           24-25: checksum  30-33: IP đích
//                                 idx 34..41  UDP header: 36-37 cổng đích, 38-39 độ dài
//                                 idx 42..49  seq (8 byte)      idx 50..  message ITCH
//
// Giới hạn đã chọn: IP không có options, bỏ qua UDP checksum và phân mảnh IP.
module eth_udp_itch_parser #(
    parameter [31:0] MCAST_IP = 32'hEF010101,  // 239.1.1.1
    parameter [15:0] UDP_PORT = 16'd30001
) (
    input  wire        clk,
    input  wire        rst,
    // luồng byte vào
    input  wire        in_valid,
    input  wire [7:0]  in_data,
    input  wire        in_last,
    // message đã decode: các trường chỉ có nghĩa trong chu kỳ msg_valid = 1
    output reg         msg_valid,
    output reg  [7:0]  msg_type,   // 'A' / 'E' / 'D'
    output reg  [63:0] seq,
    output reg  [63:0] order_id,
    output reg  [7:0]  side,       // 'B' / 'S' (chỉ message A)
    output reg  [31:0] qty,        // A, E
    output reg  [63:0] symbol,     // 8 ký tự ASCII (chỉ message A)
    output reg  [31:0] price,      // chỉ message A
    output reg  [63:0] match_no,   // chỉ message E
    output reg         msg_gap,    // seq != seq của message trước + 1 (mất gói, trùng hoặc đảo thứ tự)
    // khung bị loại: drop_reason cho biết lý do (xem localparam R_*)
    output reg         drop_valid,
    output reg  [3:0]  drop_reason
);

    localparam [3:0] R_NONE      = 4'd0,
                     R_ETHERTYPE = 4'd1,  // không phải IPv4
                     R_IP_HDR    = 4'd2,  // version != 4 hoặc có IP options (IHL != 5)
                     R_PROTO     = 4'd3,  // không phải UDP
                     R_IP_CSUM   = 4'd4,  // sai checksum IP header
                     R_DST_IP    = 4'd5,  // không phải nhóm multicast mong đợi
                     R_DST_PORT  = 4'd6,  // sai cổng UDP
                     R_LEN       = 4'd7,  // các trường độ dài không khớp nhau
                     R_MSG_TYPE  = 4'd8,  // loại message lạ
                     R_TRUNC     = 4'd9;  // khung kết thúc trước khi hết message

    reg [15:0] idx;      // vị trí byte trong khung (bão hoà ở 0xFFFF để không quay vòng)
    reg [3:0]  err;      // lỗi ĐẦU TIÊN gặp trong khung (0 = chưa có)
    reg        done;     // message của khung này đã phát
    reg [7:0]  prev;     // byte trước đó, để ghép từ 16 bit
    reg [19:0] csum;     // tổng cộng dồn checksum IP (20 bit để giữ số nhớ)
    reg [15:0] ip_len;
    reg [15:0] udp_p20, udp_m16;   // udp_len + 20 và udp_len - 16, tính sẵn khi biết udp_len để bỏ phép cộng khỏi đường kiểm tra độ dài
    reg [31:0] dst_ip;
    reg [15:0] csum_f;             // tổng checksum đã cuộn số nhớ (tính ở byte 34, kiểm tra ở byte 35)
    reg [7:0]  msg_len;  // độ dài message theo loại: A=26, E=21, D=9
    reg [63:0] exp_seq;  // seq mong đợi của message kế tiếp (= seq message trước + 1)
    reg        seq_seen; // đã nhận ít nhất một message (message đầu tiên không thể là "gap")

    // ---- tổ hợp: các phép kiểm tra trên byte đang đến ----
    wire [19:0] csum_next = csum + {4'd0, prev, in_data};
    // Cuộn số nhớ (one's complement) trên giá trị ĐÃ nằm trong thanh ghi csum (không nằm sau in_data): header đúng thì
    // tổng (gồm cả trường checksum) = 0xFFFF. Hai phép cộng nối tiếp này từng là đường găng khi tính ngay ở byte 33.
    wire [16:0] fold1     = {1'b0, csum[15:0]} + {13'd0, csum[19:16]};
    wire [15:0] fold2     = fold1[15:0] + {15'd0, fold1[16]};

    reg       type_ok;
    reg [7:0] msg_len_n;
    always @* begin
        type_ok   = 1'b1;
        msg_len_n = 8'd0;
        case (in_data)
            "A": msg_len_n = 8'd26;
            "E": msg_len_n = 8'd21;
            "D": msg_len_n = 8'd9;
            default: type_ok = 1'b0;
        endcase
    end
    wire len_ok = (ip_len == udp_p20) && (udp_m16 == {8'd0, msg_len_n});

    reg [3:0] err_n;  // lỗi sau khi tính cả byte hiện tại (ưu tiên lỗi gặp trước theo thứ tự byte)
    always @* begin
        err_n = err;
        if (in_valid && err == R_NONE) begin
            if      (idx == 16'd12 && in_data != 8'h08)               err_n = R_ETHERTYPE;
            else if (idx == 16'd13 && in_data != 8'h00)               err_n = R_ETHERTYPE;
            else if (idx == 16'd14 && in_data != 8'h45)               err_n = R_IP_HDR;
            else if (idx == 16'd23 && in_data != 8'd17)               err_n = R_PROTO;
            else if (idx == 16'd35 && csum_f != 16'hFFFF)             err_n = R_IP_CSUM;   // dời từ byte 33: dùng giá trị đã chốt
            else if (idx == 16'd35 && dst_ip != MCAST_IP)             err_n = R_DST_IP;
            else if (idx == 16'd37 && {prev, in_data} != UDP_PORT)    err_n = R_DST_PORT;
            else if (idx == 16'd50 && !type_ok)                       err_n = R_MSG_TYPE;
            else if (idx == 16'd50 && !len_ok)                        err_n = R_LEN;
        end
    end

    // byte cuối của message: message bắt đầu ở idx 50 và dài msg_len byte
    wire [15:0] end_idx  = 16'd49 + {8'd0, msg_len};
    wire        emit_now = in_valid && err_n == R_NONE && !done && idx > 16'd50 && idx == end_idx;

    always @(posedge clk) begin
        msg_valid  <= 1'b0;
        drop_valid <= 1'b0;

        if (rst) begin
            idx  <= 16'd0;
            err  <= R_NONE;
            done <= 1'b0;
            csum <= 20'd0;
            seq_seen <= 1'b0;
        end else if (in_valid) begin
            prev <= in_data;
            if (idx != 16'hFFFF) idx <= idx + 16'd1;
            err <= err_n;

            // ---- IPv4 header ----
            if (idx >= 16'd15 && idx <= 16'd33 && idx[0]) csum <= csum_next;  // mỗi 2 byte một từ 16 bit
            if (idx == 16'd17) ip_len  <= {prev, in_data};
            if (idx >= 16'd30 && idx <= 16'd33) dst_ip <= {dst_ip[23:0], in_data};
            if (idx == 16'd34) csum_f <= fold2;
            // ---- UDP header ----
            if (idx == 16'd39) begin
                udp_p20 <= {prev, in_data} + 16'd20;
                udp_m16 <= {prev, in_data} - 16'd16;
            end
            // ---- seq (big-endian: byte đến trước là byte cao) ----
            if (idx >= 16'd42 && idx <= 16'd49) seq <= {seq[55:0], in_data};
            // ---- message ITCH ----
            if (idx == 16'd50 && err_n == R_NONE) begin
                msg_type <= in_data;
                msg_len  <= msg_len_n;
                order_id <= 64'd0; side <= 8'd0; qty <= 32'd0;
                symbol <= 64'd0; price <= 32'd0; match_no <= 64'd0;  // trường không dùng của loại này = 0
            end
            if (idx > 16'd50 && err_n == R_NONE && !done) begin
                if (idx <= 16'd58) order_id <= {order_id[55:0], in_data};  // A, E, D đều có order_id ở byte 1..8
                if (msg_type == "A") begin
                    if (idx == 16'd59) side <= in_data;
                    else if (idx >= 16'd60 && idx <= 16'd63) qty    <= {qty[23:0], in_data};
                    else if (idx >= 16'd64 && idx <= 16'd71) symbol <= {symbol[55:0], in_data};
                    else if (idx >= 16'd72 && idx <= 16'd75) price  <= {price[23:0], in_data};
                end else if (msg_type == "E") begin
                    if (idx >= 16'd59 && idx <= 16'd62) qty      <= {qty[23:0], in_data};
                    else if (idx >= 16'd63 && idx <= 16'd70) match_no <= {match_no[55:0], in_data};
                end
            end

            if (emit_now) begin
                msg_valid <= 1'b1;
                done      <= 1'b1;
                // phát hiện gap: chỉ cập nhật theo message HỢP LỆ (khung bị loại thì seq của nó không đáng tin)
                msg_gap  <= seq_seen && (seq != exp_seq);
                exp_seq  <= seq + 64'd1;
                seq_seen <= 1'b1;
            end

            // ---- hết khung: báo loại nếu có lỗi/cụt, rồi reset cho khung kế tiếp ----
            if (in_last) begin
                if (err_n != R_NONE) begin
                    drop_valid  <= 1'b1;
                    drop_reason <= err_n;
                end else if (!done && !emit_now) begin
                    drop_valid  <= 1'b1;
                    drop_reason <= R_TRUNC;
                end
                idx  <= 16'd0;
                err  <= R_NONE;
                done <= 1'b0;
                csum <= 20'd0;
            end
        end
    end
endmodule
