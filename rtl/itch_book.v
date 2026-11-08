// Order book phía công ty giao dịch: dựng lại sổ lệnh từ các message ITCH A / E / D (output của eth_udp_itch_parser).
// PHIÊN BẢN HỢP BRAM (bản đọc bất đồng bộ cũ giữ ở itch_book_async.v để so tài nguyên).
//
// Khác với engine khớp lệnh của sàn: ở đây KHÔNG khớp lệnh (sàn đã khớp rồi, ta chỉ nghe lại), nên không cần hàng đợi FIFO
// theo từng mức giá. Chỉ cần:
//   1. Bảng lệnh   : order_id -> {mã, bên, giá, qty còn lại}, vì E và D chỉ mang order_id. Bảng băm địa chỉ mở (linear probing,
//                    xoá bằng tombstone + dọn ngược). Tách thành bảng KHOÁ {state, id} và bảng GIÁ TRỊ {mã, bên, giá, qty}.
//   2. Bảng mức giá: (mã, bên, giá) -> tổng qty, cùng BITMAP hai tầng để tìm giá tốt nhất mà không phải duyệt.
//   3. Giá tốt nhất: giữ trong THANH GHI, cập nhật khi ghi (thay cho truy vấn tổ hợp liên tục của bản cũ).
//
// Vì sao viết lại (đo ở giai đoạn 6): bản cũ đọc các bảng BẤT ĐỒNG BỘ và từ nhiều chỗ, nên Yosys trải ra ~17.500 ô RAM phân tán và
// hơn 23.900 LUT cho MỘT order book. BRAM thật chỉ đọc ĐỒNG BỘ (dữ liệu về sau 1 chu kỳ) và có tối đa 2 cổng. Quy tắc áp dụng:
//   - mọi bảng lớn (oid, oval, lvl, bm) có đúng 1 cổng đọc + 1 cổng ghi, đọc đồng bộ;
//   - địa chỉ đọc là hàm tổ hợp của trạng thái hiện tại => một quyết định có thể phát lệnh đọc kế tiếp NGAY trong chu kỳ đó;
//   - bitmap tầng trên (8 x 64 bit) và giá tốt nhất nằm trong thanh ghi (nhỏ, cần đọc tổ hợp);
//   - cổng debug dbg_qty dùng chung cổng đọc của bảng mức giá lúc book rảnh (đọc xong sau 1 chu kỳ).
// Cái giá: nhiều trạng thái hơn, mỗi message thêm vài chu kỳ (thêm lệnh: 3 chu kỳ; khớp/huỷ: 3+ chu kỳ; dò lại giá tốt nhất khi
// mức giá tốt nhất cạn: thêm 5 chu kỳ, hiếm).
//
// Giả định / giới hạn đã chọn (giống bản cũ):
//   - Giá nằm trong cửa sổ cố định 1..4095 (12 bit); giá ngoài cửa sổ bị báo lỗi PRICE.
//   - order_id không trùng nhau trong số lệnh đang sống (ITCH đảm bảo). Tombstone được dùng lại khi thêm lệnh.
//   - Xử lý MỘT message mỗi lần. Gửi message khi busy = 1 là lỗi của phía gọi.
//   - Bảng băm vẫn có thời gian tra KHÔNG xác định (phụ thuộc chuỗi thăm dò); bản này dò 1 ô/chu kỳ nhờ đọc trước ô kế tiếp.
module itch_book #(
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
    // giá tốt nhất của mã q_sym: đọc từ THANH GHI (luôn phản ánh trạng thái hiện tại). px = 0 nghĩa là bên đó trống
    input  wire [1:0]  q_sym,
    output wire [11:0] best_bid_px,
    output wire [31:0] best_bid_qty,
    output wire [11:0] best_ask_px,
    output wire [31:0] best_ask_qty,
    // cổng đọc debug bảng mức giá: dbg_addr = {mã[1:0], bên (1 = mua), giá[11:0]}. Đặt dbg_addr lúc book rảnh,
    // dbg_qty hợp lệ SAU 1 CHU KỲ (đọc đồng bộ)
    input  wire [14:0] dbg_addr,
    output wire [31:0] dbg_qty
);

    localparam [3:0] E_NONE = 4'd0, E_SYMBOL = 4'd1, E_PRICE = 4'd2, E_FULL = 4'd3,
                     E_UNKNOWN_ORDER = 4'd4, E_OVER_EXEC = 4'd5, E_FIELD = 4'd6;

    localparam NSLOT = 1 << ORDER_BITS;
    localparam [1:0] ST_EMPTY = 2'd0, ST_LIVE = 2'd1, ST_TOMB = 2'd2;

    localparam [3:0] S_INIT = 4'd0, S_IDLE = 4'd1, S_PROBE = 4'd2, S_UPD = 4'd3, S_CLEAN = 4'd4,
                     S_BEST0 = 4'd5, S_BEST1 = 4'd6, S_BEST2 = 4'd7, S_BEST3 = 4'd8, S_BEST4 = 4'd9;

    // ---- hàm tiện ích ----
    // Mã hoá ưu tiên 64 bit viết PHÂN CẤP (8 nhóm x 8 bit) thay cho một vòng lặp tuần tự: vòng lặp thành chuỗi ~12 mức LUT
    // nối tiếp (đo bằng nextpnr), còn dạng phân cấp chỉ cỡ 8 mức: OR từng nhóm, chọn nhóm ưu tiên, chọn byte, mã hoá trong byte.
    function [5:0] msb_idx(input [63:0] x);  // chỉ số bit 1 cao nhất
        reg [7:0] any_g, byt;
        reg [2:0] g, b;
        integer i;
        begin
            for (i = 0; i < 8; i = i + 1) any_g[i] = |x[8*i +: 8];
            g = 3'd0;
            for (i = 0; i < 8; i = i + 1) if (any_g[i]) g = i[2:0];
            byt = x[8*g +: 8];
            b = 3'd0;
            for (i = 0; i < 8; i = i + 1) if (byt[i]) b = i[2:0];
            msb_idx = {g, b};
        end
    endfunction
    function [5:0] lsb_idx(input [63:0] x);  // chỉ số bit 1 thấp nhất
        reg [7:0] any_g, byt;
        reg [2:0] g, b;
        integer i;
        begin
            for (i = 0; i < 8; i = i + 1) any_g[i] = |x[8*i +: 8];
            g = 3'd0;
            for (i = 7; i >= 0; i = i - 1) if (any_g[i]) g = i[2:0];
            byt = x[8*g +: 8];
            b = 3'd0;
            for (i = 7; i >= 0; i = i - 1) if (byt[i]) b = i[2:0];
            lsb_idx = {g, b};
        end
    endfunction
    // Băm: xor-fold cả 64 bit order_id thành các đoạn ORDER_BITS bit. Viết cho ORDER_BITS = 11: 6 đoạn x 11 = 66 bit >= 64.
    function [ORDER_BITS-1:0] hash(input [63:0] id);
        reg [65:0] x;
        integer i;
        begin
            x = {2'b00, id};
            hash = {ORDER_BITS{1'b0}};
            for (i = 0; i < 66; i = i + ORDER_BITS) hash = hash ^ x[i +: ORDER_BITS];
        end
    endfunction

    // ---- bộ nhớ lớn: mỗi bảng 1 cổng đọc (đồng bộ) + 1 cổng ghi => ánh xạ vào BRAM ----
    reg [65:0] oid_mem  [0:NSLOT-1];   // {state[65:64], id[63:0]}
    reg [46:0] oval_mem [0:NSLOT-1];   // {sym[46:45], bid[44], px[43:32], qty[31:0]}
    reg [31:0] lvl_mem  [0:32767];     // tổng qty theo {mã, bên, giá}
    reg [63:0] bm_mem   [0:511];       // bitmap tầng dưới: {mã, bên, nhóm[5:0]} -> 64 bit, bit = (giá có lệnh)
    reg [65:0] oid_rd;
    reg [46:0] oval_rd;
    reg [31:0] lvl_rd;
    reg [63:0] bm_rd;

    // cổng của các bộ nhớ: do logic tổ hợp bên dưới điều khiển theo trạng thái
    reg [ORDER_BITS-1:0] ot_ra, ot_wa;
    reg                  oid_we, oval_we;
    reg [65:0]           oid_wd;
    reg [46:0]           oval_wd;
    reg [14:0]           lvl_ra, lvl_wa;
    reg                  lvl_we;
    reg [31:0]           lvl_wd;
    reg [8:0]            bm_ra, bm_wa;
    reg                  bm_we;
    reg [63:0]           bm_wd;

    always @(posedge clk) begin
        if (oid_we)  oid_mem[ot_wa]  <= oid_wd;
        oid_rd  <= oid_mem[ot_ra];      // đọc đồng bộ: dữ liệu về SAU cạnh clock này
        if (oval_we) oval_mem[ot_wa] <= oval_wd;
        oval_rd <= oval_mem[ot_ra];
        if (lvl_we)  lvl_mem[lvl_wa] <= lvl_wd;
        lvl_rd  <= lvl_mem[lvl_ra];
        if (bm_we)   bm_mem[bm_wa]   <= bm_wd;
        bm_rd   <= bm_mem[bm_ra];
    end

    // ---- bộ nhớ nhỏ trong thanh ghi ----
    reg [63:0] bm_hi [0:7];                         // bitmap tầng trên: {mã, bên} -> 64 bit, bit = (nhóm có ít nhất một giá)
    reg [11:0] bb_px [0:3];  reg [31:0] bb_qty [0:3];   // giá / qty tốt nhất bên MUA của từng mã
    reg [11:0] ba_px [0:3];  reg [31:0] ba_qty [0:3];   // giá / qty tốt nhất bên BÁN
    assign best_bid_px  = bb_px[q_sym];
    assign best_bid_qty = bb_qty[q_sym];
    assign best_ask_px  = ba_px[q_sym];
    assign best_ask_qty = ba_qty[q_sym];
    assign dbg_qty      = lvl_rd;

    // ---- trạng thái FSM ----
    reg [3:0]  state;
    reg [14:0] init_cnt;                  // quét xoá bộ nhớ sau reset (BRAM không reset được trong 1 chu kỳ)

    reg [7:0]  m_type;                    // message đang xử lý
    reg [63:0] m_id;
    reg        m_bid;
    reg [31:0] m_qty;
    reg [11:0] m_px;
    reg [1:0]  m_sym;
    reg [ORDER_BITS-1:0] pi;              // ô đang thăm dò (dữ liệu của nó đang ở oid_rd / oval_rd)
    reg [ORDER_BITS:0]   pc;              // số ô đã thăm dò (chặn vòng lặp vô hạn khi bảng đầy)

    reg [1:0]  t_sym;                     // mức giá đích của message (thêm: của m_*; khớp/huỷ: lấy từ bảng lệnh)
    reg        t_bid;
    reg [11:0] t_px;
    reg [31:0] t_oldqty;                  // qty còn lại của lệnh trước khi áp message (khớp/huỷ)
    reg [31:0] exec_r;                    // lượng cộng vào (A) hoặc trừ khỏi (E/D) mức giá
    reg        is_del;                    // lệnh bị xoá hẳn khỏi bảng (D, hoặc E khớp hết)
    reg        need_best;                 // mức giá tốt nhất vừa cạn: phải dò lại sau khi dọn xong
    reg [5:0]  g_r, b_r;                  // nhóm / bit của giá tốt nhất mới, ĐĂNG KÝ trước khi làm địa chỉ bộ nhớ (cắt đường găng)

    // ---- tín hiệu tổ hợp dùng chung ----
    wire        is_add = (m_type == "A");

    // dữ liệu ô đang thăm dò (hợp lệ trong S_PROBE)
    wire [1:0]  k_state = oid_rd[65:64];
    wire [63:0] k_id    = oid_rd[63:0];
    wire [1:0]  v_sym   = oval_rd[46:45];
    wire        v_bid   = oval_rd[44];
    wire [11:0] v_px    = oval_rd[43:32];
    wire [31:0] v_qty   = oval_rd[31:0];
    wire        free     = (k_state != ST_LIVE);
    wire        hit      = (k_state == ST_LIVE) && (k_id == m_id);
    wire        over_exec = (m_type == "E") && (m_qty > v_qty);
    wire [31:0] exec_hit  = (m_type == "D") ? v_qty : m_qty;   // D xoá cả lệnh = khớp hết phần còn lại

    // S_UPD: cập nhật mức giá + bitmap + giá tốt nhất. lvl_rd / bm_rd là dữ liệu đã phát lệnh đọc từ S_PROBE.
    wire [14:0] t_lvl     = {t_sym, t_bid, t_px};
    wire [8:0]  t_lo      = {t_sym, t_bid, t_px[11:6]};
    wire [2:0]  t_hi      = {t_sym, t_bid};
    wire [63:0] bit_m     = 64'd1 << t_px[5:0];
    wire [63:0] grp_m     = 64'd1 << t_px[11:6];
    wire [31:0] new_lvl   = is_add ? (lvl_rd + exec_r) : (lvl_rd - exec_r);
    wire [63:0] word_new  = is_add ? (bm_rd | bit_m) : (bm_rd & ~bit_m);
    // Mức giá về 0 khi và chỉ khi lvl_rd == exec_r (chỉ với E/D). Phép so sánh BẰNG nông hơn nhiều so với cộng/trừ 32 bit rồi so với 0,
    // nên bộ cộng chỉ còn đi tới dữ liệu GHI chứ không nằm trên đường điều khiển (đường găng đo bằng nextpnr). Khác biệt duy nhất:
    // khi cộng, bỏ qua trường hợp tổng qty một mức giá tràn 32 bit.
    wire        lvl_zero  = !is_add && (lvl_rd == exec_r);
    wire        next_empty = (k_state == ST_EMPTY);          // trong S_UPD, oid_rd là ô pi+1 (đã đọc trước)
    wire [11:0] bpx       = t_bid ? bb_px[t_sym] : ba_px[t_sym];
    wire        is_best   = (t_px == bpx);
    wire        better    = t_bid ? (t_px > bpx) : (t_px < bpx);
    wire        best_gone = !is_add && is_best && lvl_zero;   // mức giá tốt nhất vừa cạn

    // Dò giá tốt nhất mới qua bitmap, tách thành các chu kỳ để KHÔNG có đường dữ-liệu-bộ-nhớ -> bộ mã hoá ưu tiên 64 bit ->
    // địa chỉ bộ nhớ trong cùng một chu kỳ (đường găng đo bằng nextpnr: Fmax 33 MHz trước khi tách):
    //   BEST0: g_r <= nhóm từ bitmap tầng trên (thanh ghi)      BEST1: đọc bm_mem[g_r]
    //   BEST2: b_r <= bit từ dữ liệu vừa đọc                    BEST3: đọc lvl_mem[g_r, b_r]      BEST4: nhận qty
    wire [63:0] hi_cur = bm_hi[t_hi];
    wire [5:0]  g_new  = t_bid ? msb_idx(hi_cur) : lsb_idx(hi_cur);
    wire [5:0]  b_new  = t_bid ? msb_idx(bm_rd)  : lsb_idx(bm_rd);

    // ---- cổng bộ nhớ theo trạng thái (tổ hợp) ----
    always @* begin
        ot_ra = pi + 1'b1;                 // mặc định: đọc trước ô kế tiếp để dò 1 ô/chu kỳ
        ot_wa = pi;  oid_we = 1'b0; oid_wd = 66'd0; oval_we = 1'b0; oval_wd = 47'd0;
        lvl_ra = 15'd0; lvl_wa = t_lvl; lvl_we = 1'b0; lvl_wd = new_lvl;
        bm_ra = 9'd0;   bm_wa = t_lo;   bm_we = 1'b0;  bm_wd = word_new;
        case (state)
            S_INIT: begin   // quét ghi 0 vào mọi bảng
                ot_wa  = init_cnt[ORDER_BITS-1:0]; oid_we = 1'b1;
                lvl_wa = init_cnt; lvl_wd = 32'd0; lvl_we = 1'b1;
                bm_wa  = init_cnt[8:0]; bm_wd = 64'd0; bm_we = (init_cnt < 15'd512);
            end
            S_IDLE: begin
                ot_ra  = hash(order_id);   // đọc ô băm của message đến NGAY trong chu kỳ nhận
                lvl_ra = dbg_addr;         // lúc rảnh, cổng đọc bảng mức giá phục vụ debug
            end
            S_PROBE: begin
                if (is_add) begin
                    if (free) begin        // ô trống: ghi lệnh mới vào cả hai bảng
                        oid_we = 1'b1;  oid_wd  = {ST_LIVE, m_id};
                        oval_we = 1'b1; oval_wd = {m_sym, m_bid, m_px, m_qty};
                    end
                    lvl_ra = {m_sym, m_bid, m_px};            bm_ra = {m_sym, m_bid, m_px[11:6]};
                end else begin
                    lvl_ra = {v_sym, v_bid, v_px};            bm_ra = {v_sym, v_bid, v_px[11:6]};
                end
            end
            S_UPD: begin
                lvl_we = 1'b1;
                bm_we  = is_add || lvl_zero;
                if (!is_add) begin
                    if (is_del) begin
                        oid_we = 1'b1; oid_wd = {(next_empty ? ST_EMPTY : ST_TOMB), m_id};
                    end else begin
                        oval_we = 1'b1; oval_wd = {t_sym, t_bid, t_px, t_oldqty - exec_r};
                    end
                end
                ot_ra = pi - 1'b1;         // phát lệnh đọc ô TRƯỚC để S_CLEAN dọn ngược tombstone
            end
            S_CLEAN: begin
                ot_ra = pi - {{(ORDER_BITS-2){1'b0}}, 2'd2};
                if (k_state == ST_TOMB) begin   // oid_rd là ô pi-1
                    ot_wa = pi - 1'b1; oid_we = 1'b1; oid_wd = {ST_EMPTY, k_id};
                end
            end
            S_BEST1: bm_ra  = {t_sym, t_bid, g_r};
            S_BEST3: lvl_ra = {t_sym, t_bid, g_r, b_r};
            default: ;
        endcase
    end

    // ---- cập nhật giá tốt nhất (theo t_sym / t_bid) ----
    task set_best(input [11:0] px, input [31:0] q);
        begin
            if (t_bid) begin bb_px[t_sym] <= px; bb_qty[t_sym] <= q; end
            else       begin ba_px[t_sym] <= px; ba_qty[t_sym] <= q; end
        end
    endtask
    task set_best_qty(input [31:0] q);
        begin
            if (t_bid) bb_qty[t_sym] <= q; else ba_qty[t_sym] <= q;
        end
    endtask

    // Kết thúc message: phát `done` (1 chu kỳ) + mã lỗi, rảnh lại để nhận message kế tiếp. (done_sym chỉ có nghĩa khi e = 0.)
    task finish(input [3:0] e);
        begin
            busy     <= 1'b0;
            done     <= 1'b1;
            err      <= e;
            done_sym <= m_sym;
            state    <= S_IDLE;
        end
    endtask

    integer ri;
    always @(posedge clk) begin
        done <= 1'b0;
        if (rst) begin
            state    <= S_INIT;
            init_cnt <= 15'd0;
            busy     <= 1'b1;
            err      <= E_NONE;
            need_best <= 1'b0;
            for (ri = 0; ri < 8; ri = ri + 1) bm_hi[ri] <= 64'd0;
            for (ri = 0; ri < 4; ri = ri + 1) begin
                bb_px[ri] <= 12'd0; bb_qty[ri] <= 32'd0; ba_px[ri] <= 12'd0; ba_qty[ri] <= 32'd0;
            end
        end else begin
            case (state)
                S_INIT: begin  // xoá bảng sau reset: 32768 chu kỳ
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
                        else state <= S_PROBE;
                    end else if (msg_type == "E" || msg_type == "D") begin
                        if (msg_type == "E" && qty == 32'd0) finish(E_FIELD);
                        else state <= S_PROBE;
                    end else begin
                        finish(E_FIELD);
                    end
                end

                S_PROBE: begin   // oid_rd / oval_rd = ô pi. Thêm lệnh: tìm ô không-LIVE đầu tiên. Khớp/huỷ: tìm đúng order_id.
                    if (is_add) begin
                        if (free) begin
                            t_sym <= m_sym; t_bid <= m_bid; t_px <= m_px; exec_r <= m_qty; is_del <= 1'b0;
                            state <= S_UPD;
                        end else begin
                            pi <= pi + 1'b1;
                            pc <= pc + 1'b1;
                            if (pc == NSLOT - 1) finish(E_FULL);
                        end
                    end else begin
                        if (hit) begin
                            if (over_exec) begin
                                finish(E_OVER_EXEC);   // khớp nhiều hơn phần còn lại: bỏ qua, không đổi trạng thái
                            end else begin
                                m_sym <= v_sym;        // E/D không mang mã: lấy từ bảng lệnh
                                t_sym <= v_sym; t_bid <= v_bid; t_px <= v_px; t_oldqty <= v_qty;
                                exec_r <= exec_hit;
                                is_del <= (m_type == "D") || (m_qty == v_qty);
                                state <= S_UPD;
                            end
                        end else if (k_state == ST_EMPTY) begin
                            finish(E_UNKNOWN_ORDER);   // gặp ô rỗng: order_id không có trong bảng
                        end else begin
                            pi <= pi + 1'b1;
                            pc <= pc + 1'b1;
                            if (pc == NSLOT - 1) finish(E_UNKNOWN_ORDER);
                        end
                    end
                end

                S_UPD: begin   // ghi mức giá / bitmap / bảng lệnh (qua cổng bộ nhớ ở trên) và cập nhật giá tốt nhất
                    if (is_add) begin
                        bm_hi[t_hi] <= bm_hi[t_hi] | grp_m;
                        if (bpx == 12'd0 || better) set_best(t_px, new_lvl);   // giá mới tốt hơn (hoặc bên này đang trống)
                        else if (is_best)           set_best_qty(new_lvl);     // cộng vào đúng mức giá tốt nhất
                    end else begin
                        if (lvl_zero && word_new == 64'd0) bm_hi[t_hi] <= bm_hi[t_hi] & ~grp_m;
                        if (is_best && !lvl_zero) set_best_qty(new_lvl);
                    end
                    need_best <= best_gone;
                    if (!is_add && is_del && next_empty) state <= S_CLEAN;    // dọn ngược tombstone trước
                    else if (best_gone)                  state <= S_BEST0;
                    else                                 finish(E_NONE);
                end

                S_CLEAN: begin  // pi là ô vừa thành RỖNG; oid_rd là ô pi-1: nếu là tombstone thì cũng thành RỖNG, đi tiếp ngược
                    if (k_state == ST_TOMB) pi <= pi - 1'b1;
                    else if (need_best)     state <= S_BEST0;
                    else                    finish(E_NONE);
                end

                S_BEST0: begin  // mức giá tốt nhất cạn: tìm nhóm bitmap của giá tốt nhất mới
                    if (hi_cur == 64'd0) begin
                        set_best(12'd0, 32'd0);               // bên này hết sạch
                        finish(E_NONE);
                    end else begin
                        g_r   <= g_new;
                        state <= S_BEST1;
                    end
                end

                S_BEST1: state <= S_BEST2;   // lệnh đọc bm_mem[g_r] đã phát ở cuối chu kỳ này; dữ liệu về ở chu kỳ sau

                S_BEST2: begin  // bm_rd = từ bitmap của nhóm g_r: bit cao nhất / thấp nhất cho giá tốt nhất mới
                    b_r <= b_new;
                    if (t_bid) bb_px[t_sym] <= {g_r, b_new}; else ba_px[t_sym] <= {g_r, b_new};
                    state <= S_BEST3;
                end

                S_BEST3: state <= S_BEST4;   // lệnh đọc lvl_mem[g_r, b_r] phát ở cuối chu kỳ này

                S_BEST4: begin  // lvl_rd = qty của mức giá tốt nhất mới
                    set_best_qty(lvl_rd);
                    finish(E_NONE);
                end

                default: state <= S_INIT;
            endcase
        end
    end
endmodule
