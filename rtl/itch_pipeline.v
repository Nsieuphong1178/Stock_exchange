// Ghép: luồng byte Ethernet -> eth_udp_itch_parser -> FIFO nhỏ -> itch_book.
//
// Vì sao cần FIFO: parser có thể phát một message mỗi ~60 chu kỳ (khung ngắn nhất, 1 byte/chu kỳ), trung bình book
// xử lý trong ~9 chu kỳ nhưng TỆ NHẤT hơn 100 chu kỳ (chuỗi thăm dò bảng băm dài). FIFO hấp thụ các đợt chậm đó.
// Nếu FIFO đầy, message mới bị bỏ và cờ `fifo_overflow` bật (dính cho tới reset) - phía trên phải coi sổ là hỏng.
module itch_pipeline #(
    parameter FIFO_BITS = 3   // 2^3 = 8 message
) (
    input  wire        clk,
    input  wire        rst,
    // luồng byte vào (như parser)
    input  wire        in_valid,
    input  wire [7:0]  in_data,
    input  wire        in_last,
    // sự kiện từ parser
    output wire        parsed_valid,   // parser vừa decode một message hợp lệ
    output wire        parsed_gap,     // ... và seq của nó bị nhảy cóc / trùng
    output wire        drop_valid,
    output wire [3:0]  drop_reason,
    // sự kiện từ book
    output wire        book_done,
    output wire [3:0]  book_err,
    output wire [1:0]  book_done_sym,  // mã bị message vừa xử lý ảnh hưởng (hợp lệ khi book_done = 1 và book_err = 0)
    output reg         fifo_overflow,
    // truy vấn sổ lệnh (xem itch_book)
    input  wire [1:0]  q_sym,
    output wire [11:0] best_bid_px,
    output wire [31:0] best_bid_qty,
    output wire [11:0] best_ask_px,
    output wire [31:0] best_ask_qty,
    input  wire [14:0] dbg_addr,
    output wire [31:0] dbg_qty,
    output wire        idle            // FIFO rỗng và book rảnh
);
    wire        p_valid;
    wire [7:0]  p_type, p_side;
    wire [63:0] p_id, p_symbol;
    wire [31:0] p_qty, p_price;
    /* verilator lint_off UNUSEDSIGNAL */
    wire [63:0] p_seq, p_match;   // book không dùng seq (cờ gap đã tính trong parser) và match_no
    /* verilator lint_on UNUSEDSIGNAL */

    eth_udp_itch_parser parser (
        .clk(clk), .rst(rst), .in_valid(in_valid), .in_data(in_data), .in_last(in_last),
        .msg_valid(p_valid), .msg_type(p_type), .seq(p_seq), .order_id(p_id), .side(p_side), .qty(p_qty),
        .symbol(p_symbol), .price(p_price), .match_no(p_match), .msg_gap(parsed_gap),
        .drop_valid(drop_valid), .drop_reason(drop_reason));
    assign parsed_valid = p_valid;

    // ---- FIFO: mỗi phần tử giữ các trường mà book cần ----
    localparam W = 8 + 64 + 8 + 32 + 64 + 32;
    reg [W-1:0]         mem [0:(1<<FIFO_BITS)-1];
    reg [FIFO_BITS:0]   wr, rd;                      // thừa 1 bit để phân biệt đầy / rỗng
    wire                empty = (wr == rd);
    wire                full  = (wr[FIFO_BITS-1:0] == rd[FIFO_BITS-1:0]) && (wr[FIFO_BITS] != rd[FIFO_BITS]);

    reg         b_valid;                              // đang đẩy một message vào book (1 chu kỳ)
    reg [W-1:0] b_word;
    wire        b_busy;
    wire        can_issue = !empty && !b_busy && !b_valid;

    always @(posedge clk) begin
        if (rst) begin
            wr <= 0; rd <= 0; b_valid <= 1'b0; fifo_overflow <= 1'b0;
        end else begin
            if (p_valid) begin
                if (full) fifo_overflow <= 1'b1;
                else begin
                    mem[wr[FIFO_BITS-1:0]] <= {p_type, p_id, p_side, p_qty, p_symbol, p_price};
                    wr <= wr + 1'b1;
                end
            end
            b_valid <= can_issue;
            if (can_issue) begin
                b_word <= mem[rd[FIFO_BITS-1:0]];
                rd     <= rd + 1'b1;
            end
        end
    end

    itch_book book (
        .clk(clk), .rst(rst),
        .msg_valid(b_valid), .msg_type(b_word[W-1:W-8]), .order_id(b_word[W-9:W-72]), .side(b_word[W-73:W-80]),
        .qty(b_word[W-81:W-112]), .symbol(b_word[W-113:W-176]), .price(b_word[W-177:0]),
        .busy(b_busy), .done(book_done), .err(book_err), .done_sym(book_done_sym), .q_sym(q_sym),
        .best_bid_px(best_bid_px), .best_bid_qty(best_bid_qty), .best_ask_px(best_ask_px),
        .best_ask_qty(best_ask_qty), .dbg_addr(dbg_addr), .dbg_qty(dbg_qty));

    assign idle = empty && !b_busy && !b_valid;
endmodule
