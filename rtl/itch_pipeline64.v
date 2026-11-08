// Ghép: luồng 64 bit/chu kỳ -> eth_udp_itch_parser64 -> FIFO -> itch_book.
//
// Parser mới có thể phát một message gần như MỖI vài chu kỳ (gói có nhiều message, 8 byte/chu kỳ), trong khi book xử lý
// MỘT message mỗi lần bằng FSM nhiều chu kỳ. FIFO ở giữa hấp thụ các đợt dồn dập; độ sâu cần có đo được qua fifo_max_level.
// FIFO đầy => message bị bỏ và `fifo_overflow` bật (dính tới reset): phía trên phải coi sổ lệnh là hỏng.
module itch_pipeline64 #(
    parameter FIFO_BITS = 6   // 2^6 = 64 message
) (
    input  wire        clk,
    input  wire        rst,
    input  wire        in_valid,
    input  wire [63:0] in_data,
    input  wire [7:0]  in_keep,
    input  wire        in_last,
    output wire        parsed_valid,
    output wire        parsed_gap,
    output wire        drop_valid,
    output wire [3:0]  drop_reason,
    output wire        book_done,
    output wire [3:0]  book_err,
    output wire        fifo_overflow,
    output wire [FIFO_BITS:0] fifo_max_level,
    input  wire [1:0]  q_sym,
    output wire [11:0] best_bid_px,
    output wire [31:0] best_bid_qty,
    output wire [11:0] best_ask_px,
    output wire [31:0] best_ask_qty,
    input  wire [14:0] dbg_addr,
    output wire [31:0] dbg_qty,
    output wire        idle
);
    wire        p_valid;
    wire [7:0]  p_type, p_side;
    wire [63:0] p_id, p_symbol;
    wire [31:0] p_qty, p_price;
    /* verilator lint_off UNUSEDSIGNAL */
    wire [63:0] p_seq, p_match;
    wire [1:0]  book_done_sym;
    /* verilator lint_on UNUSEDSIGNAL */

    eth_udp_itch_parser64 parser (
        .clk(clk), .rst(rst), .in_valid(in_valid), .in_data(in_data), .in_keep(in_keep), .in_last(in_last),
        .msg_valid(p_valid), .msg_type(p_type), .seq(p_seq), .order_id(p_id), .side(p_side), .qty(p_qty),
        .symbol(p_symbol), .price(p_price), .match_no(p_match), .msg_gap(parsed_gap),
        .drop_valid(drop_valid), .drop_reason(drop_reason));
    assign parsed_valid = p_valid;

    localparam W = 8 + 64 + 8 + 32 + 64 + 32;
    wire [W-1:0] f_word;
    wire         f_empty;
    reg          b_valid;
    reg  [W-1:0] b_word;
    wire         b_busy;
    wire         can_issue = !f_empty && !b_busy && !b_valid;

    sfifo #(.W(W), .AW(FIFO_BITS)) fifo (
        .clk(clk), .rst(rst), .wr_en(p_valid), .wr_data({p_type, p_id, p_side, p_qty, p_symbol, p_price}),
        .rd_en(can_issue), .rd_data(f_word), .empty(f_empty), .overflow(fifo_overflow), .max_level(fifo_max_level));

    always @(posedge clk) begin
        if (rst) b_valid <= 1'b0;
        else begin
            b_valid <= can_issue;
            if (can_issue) b_word <= f_word;
        end
    end

    itch_book book (
        .clk(clk), .rst(rst),
        .msg_valid(b_valid), .msg_type(b_word[W-1:W-8]), .order_id(b_word[W-9:W-72]), .side(b_word[W-73:W-80]),
        .qty(b_word[W-81:W-112]), .symbol(b_word[W-113:W-176]), .price(b_word[W-177:0]),
        .busy(b_busy), .done(book_done), .err(book_err), .done_sym(book_done_sym), .q_sym(q_sym),
        .best_bid_px(best_bid_px), .best_bid_qty(best_bid_qty), .best_ask_px(best_ask_px),
        .best_ask_qty(best_ask_qty), .dbg_addr(dbg_addr), .dbg_qty(dbg_qty));

    assign idle = f_empty && !b_busy && !b_valid;
endmodule
