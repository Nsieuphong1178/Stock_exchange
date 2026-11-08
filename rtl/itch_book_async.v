// [BẢN CŨ, giữ để so sánh tài nguyên với itch_book.v — KHÔNG hợp BRAM: bảng đọc bất đồng bộ, nhiều cổng đọc]
// Order book phía công ty giao dịch: dựng lại sổ lệnh từ các message ITCH A / E / D (output của eth_udp_itch_parser).
//
// Khác với engine khớp lệnh của sàn: ở đây KHÔNG khớp lệnh (sàn đã khớp rồi, ta chỉ nghe lại), nên không cần
// hàng đợi FIFO theo từng mức giá. Chỉ cần hai thứ:
//   1. Bảng lệnh   : order_id -> {mã, bên, giá, qty còn lại}, vì E và D chỉ mang order_id.
//   2. Bảng mức giá: (mã, bên, giá) -> tổng qty, cùng BITMAP hai tầng để tìm giá tốt nhất mà không phải duyệt.
//
// Bảng lệnh là bảng băm địa chỉ mở (linear probing, xoá bằng tombstone): order_id 64 bit không dùng làm địa chỉ
// trực tiếp được. Đây là điểm mà thiết kế thật phải đánh đổi (CAM, băm nhiều bậc, hay ép sàn cấp ID dày đặc).
//
// Giả định / giới hạn đã chọn:
//   - Giá nằm trong cửa sổ cố định 1..4095 (12 bit); giá ngoài cửa sổ bị báo lỗi PRICE. Hệ thống thật dùng
//     "giá gốc + offset" quanh giá thị trường.
//   - order_id không trùng nhau trong số lệnh đang sống (ITCH đảm bảo). Tombstone chỉ được dùng lại khi thêm lệnh.
//   - Xử lý MỘT message mỗi lần, nhiều chu kỳ. Message chỉ cách nhau >= ~50 chu kỳ vì parser nhận 1 byte/chu kỳ,
//     nên chưa cần pipeline. Gửi message khi busy = 1 là lỗi của phía gọi.
module itch_book_async #(
    parameter [63:0] SYM0 = "AAA     ",
    parameter [63:0] SYM1 = "BBB     ",
    parameter [63:0] SYM2 = "CCC     ",
    parameter        ORDER_BITS = 11          // bảng lệnh có 2^ORDER_BITS ô
) (
    input  wire        clk,
    input  wire        rst,
    // message vào (nối với output của parser)
    input  wire        msg_valid,
    input  wire [7:0]  msg_type,   // 'A' / 'E' / 'D'
    input  wire [63:0] order_id,
    input  wire [7:0]  side,       // 'B' / 'S' (chỉ A)
    input  wire [31:0] qty,        // A: qty; E: qty được khớp
    input  wire [63:0] symbol,     // chỉ A
    input  wire [31:0] price,      // chỉ A
    // trạng thái xử lý
    output reg         busy,
    output reg         done,       // 1 chu kỳ sau khi xử lý xong một message
    output reg  [3:0]  err,        // lỗi của message vừa xong (hợp lệ khi done = 1; 0 = không lỗi)
    output reg  [1:0]  done_sym,   // mã bị message vừa xong ảnh hưởng (hợp lệ khi done = 1 và err = 0)
    // truy vấn giá tốt nhất của mã q_sym (tổ hợp, luôn phản ánh trạng thái hiện tại). px = 0 nghĩa là bên đó trống
    input  wire [1:0]  q_sym,
    output wire [11:0] best_bid_px,
    output wire [31:0] best_bid_qty,
    output wire [11:0] best_ask_px,
    output wire [31:0] best_ask_qty,
    // cổng đọc debug toàn bộ bảng mức giá: dbg_addr = {mã[1:0], bên (1 = mua), giá[11:0]}
    input  wire [14:0] dbg_addr,
    output wire [31:0] dbg_qty
);

    localparam [3:0] E_NONE = 4'd0, E_SYMBOL = 4'd1, E_PRICE = 4'd2, E_FULL = 4'd3,
                     E_UNKNOWN_ORDER = 4'd4, E_OVER_EXEC = 4'd5, E_FIELD = 4'd6;

    localparam NSLOT = 1 << ORDER_BITS;
    localparam [1:0] ST_EMPTY = 2'd0, ST_LIVE = 2'd1, ST_TOMB = 2'd2;

    // ---- bộ nhớ ----
    reg [1:0]  ot_state [0:NSLOT-1];
    reg [63:0] ot_id    [0:NSLOT-1];
    reg [1:0]  ot_sym   [0:NSLOT-1];
    reg        ot_bid   [0:NSLOT-1];   // 1 = lệnh mua
    reg [11:0] ot_px    [0:NSLOT-1];
    reg [31:0] ot_qty   [0:NSLOT-1];

    reg [31:0] lvl   [0:32767];        // tổng qty theo {mã, bên, giá}
    reg [63:0] bm_lo [0:511];          // bitmap tầng dưới: {mã, bên, nhóm[5:0]} -> 64 bit, bit = (giá có lệnh)
    reg [63:0] bm_hi [0:7];            // bitmap tầng trên: {mã, bên} -> 64 bit, bit = (nhóm có ít nhất một giá)

    // ---- hàm tiện ích ----
    function [5:0] msb_idx(input [63:0] x);  // chỉ số bit 1 cao nhất
        integer i;
        begin
            msb_idx = 6'd0;
            for (i = 0; i < 64; i = i + 1) if (x[i]) msb_idx = i[5:0];
        end
    endfunction
    function [5:0] lsb_idx(input [63:0] x);  // chỉ số bit 1 thấp nhất
        integer i;
        begin
            lsb_idx = 6'd0;
            for (i = 63; i >= 0; i = i - 1) if (x[i]) lsb_idx = i[5:0];
        end
    endfunction
    // Băm: xor-fold cả 64 bit order_id thành các đoạn ORDER_BITS bit (dùng cả bit cao để ID chỉ khác ở bit cao
    // không luôn trùng ô). Viết cho ORDER_BITS = 11: 6 đoạn x 11 = 66 bit >= 64.
    function [ORDER_BITS-1:0] hash(input [63:0] id);
        reg [65:0] x;
        integer i;
        begin
            x = {2'b00, id};
            hash = {ORDER_BITS{1'b0}};
            for (i = 0; i < 66; i = i + ORDER_BITS) hash = hash ^ x[i +: ORDER_BITS];
        end
    endfunction

    // ---- giá tốt nhất: tìm bit 1 qua bitmap hai tầng, KHÔNG duyệt bảng giá ----
    wire [63:0] bid_hi = bm_hi[{q_sym, 1'b1}];
    wire [63:0] ask_hi = bm_hi[{q_sym, 1'b0}];
    wire [5:0]  bid_g  = msb_idx(bid_hi);   // mua: giá cao nhất
    wire [5:0]  ask_g  = lsb_idx(ask_hi);   // bán: giá thấp nhất
    wire [63:0] bid_w  = bm_lo[{q_sym, 1'b1, bid_g}];
    wire [63:0] ask_w  = bm_lo[{q_sym, 1'b0, ask_g}];
    assign best_bid_px  = (bid_hi != 64'd0) ? {bid_g, msb_idx(bid_w)} : 12'd0;
    assign best_ask_px  = (ask_hi != 64'd0) ? {ask_g, lsb_idx(ask_w)} : 12'd0;
    assign best_bid_qty = (bid_hi != 64'd0) ? lvl[{q_sym, 1'b1, best_bid_px}] : 32'd0;
    assign best_ask_qty = (ask_hi != 64'd0) ? lvl[{q_sym, 1'b0, best_ask_px}] : 32'd0;
    assign dbg_qty      = lvl[dbg_addr];

    // ---- FSM ----
    localparam [2:0] S_INIT = 3'd0, S_IDLE = 3'd1, S_ADD = 3'd2, S_LOOKUP = 3'd3, S_APPLY = 3'd4, S_CLEAN = 3'd6;
    reg [2:0]  state;
    reg [14:0] init_cnt;                  // quét xoá bộ nhớ sau reset (BRAM không reset được trong 1 chu kỳ)

    reg [7:0]  m_type;                    // message đang xử lý
    reg [63:0] m_id;
    reg        m_bid;
    reg [31:0] m_qty;
    reg [11:0] m_px;
    reg [1:0]  m_sym;
    reg [ORDER_BITS-1:0] pi;              // ô đang thăm dò
    reg [ORDER_BITS:0]   pc;              // số ô đã thăm dò (chặn vòng lặp vô hạn khi bảng đầy)

    // đọc ô đang thăm dò
    wire [1:0]  cur_state = ot_state[pi];
    wire [63:0] cur_id    = ot_id[pi];
    wire        cur_hit   = (cur_state == ST_LIVE) && (cur_id == m_id);

    // chỉ số mức giá + bitmap của lệnh đang xử lý. Với E/D, mã/bên/giá lấy từ bảng lệnh (đã tìm thấy ở pi).
    wire [1:0]  a_sym = (m_type == "A") ? m_sym : ot_sym[pi];
    wire        a_bid = (m_type == "A") ? m_bid : ot_bid[pi];
    wire [11:0] a_px  = (m_type == "A") ? m_px  : ot_px[pi];
    wire [14:0] a_lvl = {a_sym, a_bid, a_px};
    wire [8:0]  a_lo  = {a_sym, a_bid, a_px[11:6]};
    wire [2:0]  a_hi  = {a_sym, a_bid};
    wire [63:0] a_word    = bm_lo[a_lo];
    wire [63:0] a_bit     = 64'd1 << a_px[5:0];
    wire [63:0] a_grp_bit = 64'd1 << a_px[11:6];

    wire [31:0] o_qty     = ot_qty[pi];
    wire [31:0] exec_qty  = (m_type == "D") ? o_qty : m_qty;  // D xoá cả lệnh = khớp hết phần còn lại
    wire [31:0] lvl_after = lvl[a_lvl] - exec_qty;

    // Kết thúc message: phát `done` (1 chu kỳ) + mã lỗi, rảnh lại để nhận message kế tiếp. Không có trạng thái DONE riêng:
    // mỗi message nhanh hơn một chu kỳ so với bản đầu. (done_sym chỉ có nghĩa khi e = 0.)
    task finish(input [3:0] e);
        begin
            busy     <= 1'b0;
            done     <= 1'b1;
            err      <= e;
            done_sym <= m_sym;
            state    <= S_IDLE;
        end
    endtask

    always @(posedge clk) begin
        done <= 1'b0;
        if (rst) begin
            state    <= S_INIT;
            init_cnt <= 15'd0;
            busy     <= 1'b1;
            err      <= E_NONE;
        end else begin
            case (state)
                S_INIT: begin  // xoá bảng sau reset: 32768 chu kỳ
                    lvl[init_cnt] <= 32'd0;
                    if (init_cnt < NSLOT) ot_state[init_cnt[ORDER_BITS-1:0]] <= ST_EMPTY;
                    if (init_cnt < 512)   bm_lo[init_cnt[8:0]] <= 64'd0;
                    if (init_cnt < 8)     bm_hi[init_cnt[2:0]] <= 64'd0;
                    init_cnt <= init_cnt + 15'd1;
                    if (init_cnt == 15'h7FFF) begin state <= S_IDLE; busy <= 1'b0; end
                end

                S_IDLE: if (msg_valid) begin
                    busy   <= 1'b1;
                    m_type <= msg_type;
                    m_id   <= order_id;
                    m_bid  <= (side == "B");
                    m_qty  <= qty;
                    m_px   <= price[11:0];
                    m_sym  <= (symbol == SYM0) ? 2'd0 : (symbol == SYM1) ? 2'd1 : 2'd2;
                    pi     <= hash(order_id);
                    pc     <= 0;
                    if (msg_type == "A") begin
                        if (symbol != SYM0 && symbol != SYM1 && symbol != SYM2) finish(E_SYMBOL);
                        else if (price == 32'd0 || price > 32'd4095)            finish(E_PRICE);
                        else if ((side != "B" && side != "S") || qty == 32'd0)  finish(E_FIELD);
                        else state <= S_ADD;
                    end else if (msg_type == "E" || msg_type == "D") begin
                        if (msg_type == "E" && qty == 32'd0) finish(E_FIELD);
                        else state <= S_LOOKUP;
                    end else begin
                        finish(E_FIELD);
                    end
                end

                S_ADD: begin  // tìm ô trống đầu tiên (rỗng hoặc tombstone) rồi ghi lệnh + cộng vào mức giá + đặt bitmap
                    if (cur_state != ST_LIVE) begin
                        ot_state[pi] <= ST_LIVE;
                        ot_id[pi]    <= m_id;
                        ot_sym[pi]   <= m_sym;
                        ot_bid[pi]   <= m_bid;
                        ot_px[pi]    <= m_px;
                        ot_qty[pi]   <= m_qty;
                        lvl[a_lvl]   <= lvl[a_lvl] + m_qty;
                        bm_lo[a_lo]  <= a_word | a_bit;
                        bm_hi[a_hi]  <= bm_hi[a_hi] | a_grp_bit;
                        finish(E_NONE);
                    end else begin
                        pi <= pi + 1'b1;
                        pc <= pc + 1'b1;
                        if (pc == NSLOT - 1) finish(E_FULL);
                    end
                end

                S_LOOKUP: begin  // tìm order_id: đi qua tombstone, dừng ở ô rỗng (= không có)
                    if (cur_hit) begin
                        m_sym <= ot_sym[pi];  // E/D không mang mã: lấy từ bảng lệnh
                        state <= S_APPLY;
                    end
                    else if (cur_state == ST_EMPTY) finish(E_UNKNOWN_ORDER);
                    else begin
                        pi <= pi + 1'b1;
                        pc <= pc + 1'b1;
                        if (pc == NSLOT - 1) finish(E_UNKNOWN_ORDER);
                    end
                end

                S_APPLY: begin  // E: giảm qty (hết thì xoá lệnh). D: xoá lệnh. Cả hai trừ qty khỏi mức giá, xoá bit nếu mức giá về 0.
                    if (m_type == "E" && m_qty > o_qty) begin
                        finish(E_OVER_EXEC);  // khớp nhiều hơn phần còn lại: bỏ qua, không đổi trạng thái
                    end else begin
                        lvl[a_lvl] <= lvl_after;
                        if (m_type == "D" || m_qty == o_qty) begin
                            // Xoá ô. Nếu ô kế tiếp RỖNG thì không chuỗi thăm dò nào đi xuyên qua ô này nữa => ô này
                            // cũng có thể là RỖNG (thay vì tombstone), rồi dọn ngược các tombstone liền trước (S_CLEAN).
                            // Nếu không, tombstone chất đống và tra một khoá KHÔNG có phải quét cả bảng.
                            if (ot_state[pi + 1'b1] == ST_EMPTY) begin
                                ot_state[pi] <= ST_EMPTY;
                                state <= S_CLEAN;
                            end else begin
                                ot_state[pi] <= ST_TOMB;
                                finish(E_NONE);
                            end
                        end else begin
                            ot_qty[pi] <= o_qty - m_qty;
                            finish(E_NONE);
                        end
                        if (lvl_after == 32'd0) begin
                            bm_lo[a_lo] <= a_word & ~a_bit;
                            if ((a_word & ~a_bit) == 64'd0) bm_hi[a_hi] <= bm_hi[a_hi] & ~a_grp_bit;
                        end
                    end
                end

                S_CLEAN: begin  // pi là ô vừa thành RỖNG: các tombstone ngay trước nó cũng thành RỖNG
                    if (ot_state[pi - 1'b1] == ST_TOMB) begin
                        ot_state[pi - 1'b1] <= ST_EMPTY;
                        pi <= pi - 1'b1;
                    end else begin
                        finish(E_NONE);
                    end
                end

                default: state <= S_INIT;
            endcase
        end
    end
endmodule
