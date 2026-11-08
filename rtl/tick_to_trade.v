// Đường tick-to-trade hoàn chỉnh trong mô phỏng:
//
//   byte Ethernet ─► parser ─► FIFO ─► order book ─► chiến lược ─► risk ─► FIFO lệnh ─► mã hoá OUCH ─► byte ra
//   (market data)                       (itch_pipeline)                                               (gói 'U')
//
// "Tick" = một message market data làm sổ lệnh đổi. "Trade" = byte đầu tiên của lệnh rời module. Độ trễ cần đo là số chu
// kỳ giữa hai thời điểm đó (xem tb_t2t.v). Ra khỏi module là luồng byte của gói OUCH; tầng TCP/IP + MAC phía sau chưa làm.
//
// FIFO lệnh: hai tick sát nhau (do book có lúc xử lý lâu, xem itch_book) có thể sinh hai lệnh cách nhau ít hơn 36 chu kỳ
// mà bộ mã hoá cần 36 chu kỳ để phát một lệnh, nên cần một hàng đợi nhỏ ở giữa.
module tick_to_trade #(
    parameter [63:0] SYM0 = "AAA     ",
    parameter [63:0] SYM1 = "BBB     ",
    parameter [63:0] SYM2 = "CCC     ",
    parameter [1:0]  STRAT_SYM   = 2'd0,
    parameter [11:0] BUY_BELOW   = 12'd500,
    parameter [11:0] SELL_ABOVE  = 12'd3700,
    parameter [31:0] ORDER_QTY   = 32'd10,
    parameter [31:0] MAX_QTY      = 32'd1000,
    parameter [31:0] MIN_PX       = 32'd1,
    parameter [31:0] MAX_PX       = 32'd4095,
    parameter [63:0] MAX_NOTIONAL = 64'd1000000,
    parameter [31:0] MAX_POS      = 32'd100000,
    parameter [31:0] RATE_MAX     = 32'hFFFFFFFF,
    parameter [31:0] RATE_WINDOW  = 32'd1000
) (
    input  wire        clk,
    input  wire        rst,
    input  wire        kill,            // ngắt khẩn cấp: risk loại mọi lệnh
    // market data vào
    input  wire        in_valid,
    input  wire [7:0]  in_data,
    input  wire        in_last,
    // lệnh ra (gói OUCH 'U', 1 byte/chu kỳ)
    output wire        out_valid,
    output wire [7:0]  out_data,
    output wire        out_last,
    // quan sát (cho testbench / thống kê)
    output wire        parsed_valid,
    output wire        book_done,
    output wire        order_started,   // bộ mã hoá bắt đầu một lệnh mới
    output wire        rej_valid,       // risk vừa loại một lệnh
    output wire [3:0]  rej_reason,
    output wire        overflow,        // bất kỳ FIFO nào tràn: kết quả không còn tin được
    output wire        pipe_idle        // FIFO message rỗng và book rảnh (hết việc phía market data)
);
    // ---- 1) market data -> sổ lệnh ----
    wire [3:0]  book_err;
    wire [1:0]  done_sym;
    wire [11:0] bid_px, ask_px;
    wire        msg_fifo_overflow;
    /* verilator lint_off UNUSEDSIGNAL */
    wire        parsed_gap, drop_valid;
    wire [3:0]  drop_reason;
    wire [31:0] bid_qty, ask_qty, dbg_qty;
    /* verilator lint_on UNUSEDSIGNAL */

    itch_pipeline pipe (
        .clk(clk), .rst(rst), .in_valid(in_valid), .in_data(in_data), .in_last(in_last),
        .parsed_valid(parsed_valid), .parsed_gap(parsed_gap), .drop_valid(drop_valid), .drop_reason(drop_reason),
        .book_done(book_done), .book_err(book_err), .book_done_sym(done_sym), .fifo_overflow(msg_fifo_overflow),
        .q_sym(done_sym),   // hỏi giá tốt nhất của đúng mã vừa đổi
        .best_bid_px(bid_px), .best_bid_qty(bid_qty), .best_ask_px(ask_px), .best_ask_qty(ask_qty),
        .dbg_addr(15'd0), .dbg_qty(dbg_qty), .idle(pipe_idle));

    // ---- 2) chiến lược ----
    wire        s_valid, s_buy;
    wire [31:0] s_qty, s_price;
    wire [1:0]  s_sym;
    strategy_threshold #(.SYM(STRAT_SYM), .BUY_BELOW(BUY_BELOW), .SELL_ABOVE(SELL_ABOVE), .QTY(ORDER_QTY)) strat (
        .clk(clk), .rst(rst), .tick(book_done && book_err == 4'd0), .tick_sym(done_sym),
        .bid_px(bid_px), .ask_px(ask_px),
        .order_valid(s_valid), .order_buy(s_buy), .order_qty(s_qty), .order_price(s_price), .order_sym(s_sym));

    // ---- 3) risk ----
    wire        r_valid, r_buy;
    wire [31:0] r_qty, r_price;
    wire [1:0]  r_sym;
    pretrade_risk #(.MAX_QTY(MAX_QTY), .MIN_PX(MIN_PX), .MAX_PX(MAX_PX), .MAX_NOTIONAL(MAX_NOTIONAL),
                    .MAX_POS(MAX_POS), .RATE_MAX(RATE_MAX), .RATE_WINDOW(RATE_WINDOW)) risk (
        .clk(clk), .rst(rst), .kill(kill),
        .in_valid(s_valid), .in_buy(s_buy), .in_qty(s_qty), .in_price(s_price), .in_sym(s_sym),
        .out_valid(r_valid), .out_buy(r_buy), .out_qty(r_qty), .out_price(r_price), .out_sym(r_sym),
        .rej_valid(rej_valid), .rej_reason(rej_reason));

    // ---- 4) FIFO lệnh -> bộ mã hoá ----
    wire [66:0] f_word;
    wire        f_empty, ord_fifo_overflow;
    wire        enc_busy;
    /* verilator lint_off UNUSEDSIGNAL */
    wire [3:0]  ord_max_level;
    /* verilator lint_on UNUSEDSIGNAL */
    reg         enc_start;
    reg  [66:0] e_word;
    reg  [31:0] tok_cnt;
    reg  [111:0] e_token;
    wire        can_issue = !f_empty && !enc_busy && !enc_start;

    sfifo #(.W(67), .AW(3)) ord_fifo (
        .clk(clk), .rst(rst), .wr_en(r_valid), .wr_data({r_buy, r_qty, r_price, r_sym}),
        .rd_en(can_issue), .rd_data(f_word), .empty(f_empty), .overflow(ord_fifo_overflow), .max_level(ord_max_level));

    // token = "FPGA" + 8 chữ số hex của bộ đếm + 2 khoảng trắng (14 byte). Mỗi lệnh phát ra dùng một token mới.
    function [7:0] hexc(input [3:0] n);
        hexc = (n < 4'd10) ? (8'h30 + {4'd0, n}) : (8'h41 + {4'd0, n} - 8'd10);
    endfunction
    wire [63:0] tok_hex = {hexc(tok_cnt[31:28]), hexc(tok_cnt[27:24]), hexc(tok_cnt[23:20]), hexc(tok_cnt[19:16]),
                           hexc(tok_cnt[15:12]), hexc(tok_cnt[11:8]),  hexc(tok_cnt[7:4]),   hexc(tok_cnt[3:0])};

    always @(posedge clk) begin
        if (rst) begin
            enc_start <= 1'b0;
            tok_cnt   <= 32'd0;
        end else begin
            enc_start <= can_issue;
            if (can_issue) begin
                e_word  <= f_word;
                e_token <= {"FPGA", tok_hex, "  "};
                tok_cnt <= tok_cnt + 32'd1;
            end
        end
    end
    assign order_started = enc_start;

    // e_word = {buy, qty[31:0], price[31:0], sym[1:0]}
    ouch_encoder enc (
        .clk(clk), .rst(rst), .start(enc_start), .is_cancel(1'b0), .token(e_token), .side_buy(e_word[66]),
        .qty(e_word[65:34]), .symbol((e_word[1:0] == 2'd0) ? SYM0 : (e_word[1:0] == 2'd1) ? SYM1 : SYM2),
        .price(e_word[33:2]), .is_market(1'b0),
        .busy(enc_busy), .out_valid(out_valid), .out_data(out_data), .out_last(out_last));

    assign overflow = msg_fifo_overflow | ord_fifo_overflow;
endmodule
