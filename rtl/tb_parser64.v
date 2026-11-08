// Testbench eth_udp_itch_parser64: so TỪNG sự kiện (message hoặc khung bị loại) với golden Python.
// p64_frames.mem : mỗi dòng 1 từ 74 bit {idle[73], last[72], keep[71:64], data[63:0]}
// p64_expect.mem : từ 0 = số từ luồng, từ 1 = số sự kiện, rồi mỗi sự kiện 6 từ 64 bit (như tb_parser.v):
//                  w0 {kind, type, side, reason, 31'h0, gap}  w1 seq  w2 order_id  w3 match_no  w4 {qty, price}  w5 symbol
// Một chu kỳ có thể phát cả message lẫn drop (message cuối của một gói lỗi giữa chừng): message được so TRƯỚC, drop SAU.
`timescale 1ns/1ps
/* verilator lint_off BLKSEQ */
/* verilator lint_off WIDTH */
/* verilator lint_off PROCASSINIT */
/* verilator lint_off UNUSEDSIGNAL */
module tb_parser64;
    reg clk = 1'b0;
    always #5 clk = ~clk;

    reg         rst = 1'b1;
    reg         in_valid = 1'b0, in_last = 1'b0;
    reg  [63:0] in_data = 64'd0;
    reg  [7:0]  in_keep = 8'd0;

    wire         msg_valid, msg_gap, drop_valid;
    wire [7:0]   msg_type, side;
    wire [63:0]  seq, order_id, symbol, match_no;
    wire [31:0]  qty, price;
    wire [3:0]   drop_reason;

    eth_udp_itch_parser64 dut (
        .clk(clk), .rst(rst), .in_valid(in_valid), .in_data(in_data), .in_keep(in_keep), .in_last(in_last),
        .msg_valid(msg_valid), .msg_type(msg_type), .seq(seq), .order_id(order_id), .side(side), .qty(qty),
        .symbol(symbol), .price(price), .match_no(match_no), .msg_gap(msg_gap),
        .drop_valid(drop_valid), .drop_reason(drop_reason));

    reg [73:0] stream [0:4194303];
    reg [63:0] expv   [0:2097151];
    integer n_words, n_events, i, rec, errors, b, n_msg, n_drop, n_gap;
    reg [73:0] w;

    always @(posedge clk) begin
        if (msg_valid) begin
            b = 2 + rec * 6;
            n_msg = n_msg + 1;
            if (msg_gap) n_gap = n_gap + 1;
            if (rec >= n_events) begin
                if (errors < 10) $display("FAIL: DUT phat them su kien thu %0d", rec);
                errors = errors + 1;
            end else if (expv[b] !== {8'h01, msg_type, side, 8'h00, 31'h0, msg_gap} || expv[b+1] !== seq ||
                         expv[b+2] !== order_id || expv[b+3] !== match_no ||
                         expv[b+4] !== {qty, price} || expv[b+5] !== symbol) begin
                if (errors < 10) begin
                    $display("FAIL rec %0d (msg): got type=%c seq=%0d id=%h qty=%0d px=%0d match=%0d gap=%0d",
                             rec, msg_type, seq, order_id, qty, price, match_no, msg_gap);
                    $display("             exp w0=%h seq=%0d id=%h qty/px=%h match=%0d", expv[b], expv[b+1], expv[b+2], expv[b+4], expv[b+3]);
                end
                errors = errors + 1;
            end
            rec = rec + 1;
        end
        if (drop_valid) begin
            b = 2 + rec * 6;
            n_drop = n_drop + 1;
            if (rec >= n_events) begin
                if (errors < 10) $display("FAIL: DUT phat them drop thu %0d", rec);
                errors = errors + 1;
            end else if (expv[b] !== {8'h02, 16'h0000, 4'h0, drop_reason, 32'h0}) begin
                if (errors < 10) $display("FAIL rec %0d (drop): got reason=%0d, exp w0=%h", rec, drop_reason, expv[b]);
                errors = errors + 1;
            end
            rec = rec + 1;
        end
    end

    initial begin
        errors = 0; rec = 0; n_msg = 0; n_drop = 0; n_gap = 0;
        $readmemh("p64_frames.mem", stream);
        $readmemh("p64_expect.mem", expv);
        n_words  = expv[0];
        n_events = expv[1];
        repeat (4) @(posedge clk);
        rst <= 1'b0;
        for (i = 0; i < n_words; i = i + 1) begin
            w = stream[i];
            @(posedge clk);
            in_valid <= ~w[73];
            in_data  <= w[63:0];
            in_keep  <= w[71:64];
            in_last  <= w[72] & ~w[73];
        end
        @(posedge clk);
        in_valid <= 1'b0; in_last <= 1'b0;
        repeat (10) @(posedge clk);
        if (rec != n_events) begin $display("FAIL: mong doi %0d su kien, DUT phat %0d", n_events, rec); errors = errors + 1; end
        if (errors == 0) $display("PASS: %0d su kien (%0d message gom %0d co gap, %0d khung bi loai) khop golden, 1 tu 64 bit moi chu ky",
                                  rec, n_msg, n_gap, n_drop);
        else             $display("FAILED: %0d loi", errors);
        $finish;
    end
endmodule
