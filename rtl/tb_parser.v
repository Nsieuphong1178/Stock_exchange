// Testbench: đọc luồng byte từ frames.mem, so từng sự kiện ra với expected.mem (do gen_vectors.py sinh).
//
// frames.mem  : mỗi dòng 1 từ 32 bit hex. Từ 0 = số từ phía sau. Từ còn lại: bit9 = chu kỳ rảnh (valid=0),
//               bit8 = byte cuối khung (last), bit7:0 = dữ liệu.
// expected.mem: mỗi dòng 1 từ 64 bit hex. Từ 0 = số bản ghi. Mỗi bản ghi 6 từ:
//               w0 {kind, type, side, reason, 31'h0, gap} (kind 1 = message, 2 = khung bị loại; gap = msg_gap)
//               w1 seq, w2 order_id, w3 match_no, w4 {qty, price}, w5 symbol   (w1..w5 chỉ so khi kind = 1)
`timescale 1ns/1ps
// Testbench: cho phép kiểu viết mô phỏng (gán blocking trong always, chỉ số rộng...) mà lint của RTL sẽ cấm
/* verilator lint_off BLKSEQ */
/* verilator lint_off WIDTH */
/* verilator lint_off PROCASSINIT */
/* verilator lint_off UNUSEDSIGNAL */
module tb_parser;
    reg clk = 1'b0;
    always #5 clk = ~clk;

    reg        rst = 1'b1;
    reg        in_valid = 1'b0;
    reg  [7:0] in_data = 8'd0;
    reg        in_last = 1'b0;

    wire        msg_valid, drop_valid, msg_gap;
    wire [7:0]  msg_type, side;
    wire [63:0] seq, order_id, symbol, match_no;
    wire [31:0] qty, price;
    wire [3:0]  drop_reason;

    eth_udp_itch_parser dut (
        .clk(clk), .rst(rst), .in_valid(in_valid), .in_data(in_data), .in_last(in_last),
        .msg_valid(msg_valid), .msg_type(msg_type), .seq(seq), .order_id(order_id), .side(side),
        .qty(qty), .symbol(symbol), .price(price), .match_no(match_no), .msg_gap(msg_gap),
        .drop_valid(drop_valid), .drop_reason(drop_reason));

    reg [31:0] stream [0:65535];
    reg [63:0] expv   [0:16383];
    integer n_words, n_rec, i, rec, errors, n_msg, n_drop;
    reg [31:0] w;

    // ---- bộ kiểm tra: mỗi khi DUT báo một sự kiện, so với bản ghi kế tiếp ----
    reg [63:0] b;
    always @(posedge clk) begin
        if (msg_valid || drop_valid) begin
            if (msg_valid && drop_valid) begin
                $display("FAIL: msg_valid va drop_valid cung luc"); errors = errors + 1;
            end
            b = 1 + rec * 6;
            if (rec >= n_rec) begin
                $display("FAIL: DUT phat them su kien thu %0d (chi mong doi %0d)", rec, n_rec); errors = errors + 1;
            end else if (msg_valid) begin
                n_msg = n_msg + 1;
                if (expv[b] !== {8'h01, msg_type, side, 8'h00, 31'h0, msg_gap} || expv[b+1] !== seq ||
                    expv[b+2] !== order_id || expv[b+3] !== match_no ||
                    expv[b+4] !== {qty, price} || expv[b+5] !== symbol) begin
                    $display("FAIL rec %0d (msg): got type=%c side=%0d seq=%0d id=%0d qty=%0d px=%0d match=%0d",
                             rec, msg_type, side, seq, order_id, qty, price, match_no);
                    $display("             exp w0=%h seq=%0d id=%0d qty/px=%h match=%0d",
                             expv[b], expv[b+1], expv[b+2], expv[b+4], expv[b+3]);
                    errors = errors + 1;
                end
            end else begin
                n_drop = n_drop + 1;
                if (expv[b] !== {8'h02, 16'h0000, 4'h0, drop_reason, 32'h0}) begin
                    $display("FAIL rec %0d (drop): got reason=%0d, exp w0=%h", rec, drop_reason, expv[b]);
                    errors = errors + 1;
                end
            end
            rec = rec + 1;
        end
    end

    // ---- kích thích ----
    initial begin
        errors = 0; rec = 0; n_msg = 0; n_drop = 0;
        $readmemh("frames.mem", stream);
        $readmemh("expected.mem", expv);
        n_words = stream[0];
        n_rec   = expv[0];
        repeat (4) @(posedge clk);
        rst <= 1'b0;
        for (i = 1; i <= n_words; i = i + 1) begin
            w = stream[i];
            @(posedge clk);
            in_valid <= ~w[9];
            in_data  <= w[7:0];
            in_last  <= w[8] & ~w[9];
        end
        @(posedge clk);
        in_valid <= 1'b0; in_last <= 1'b0;
        repeat (10) @(posedge clk);
        if (rec != n_rec) begin
            $display("FAIL: mong doi %0d su kien, DUT chi phat %0d", n_rec, rec); errors = errors + 1;
        end
        if (errors == 0) $display("PASS: %0d su kien (%0d message, %0d khung bi loai) khop golden", rec, n_msg, n_drop);
        else             $display("FAILED: %0d loi", errors);
        $finish;
    end
endmodule
