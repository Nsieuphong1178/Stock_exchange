// Testbench ouch_encoder: đẩy lệnh từ ouch_vec.mem vào DUT, so TỪNG BYTE phát ra với ouch_bytes.mem
// (do client/ouch.py mã hoá). Cũng kiểm tra độ dài gói (out_last đúng chỗ) và các lệnh đưa vào sát nhau.
// Định dạng file: xem gen_ouch_vectors.py.
`timescale 1ns/1ps
/* verilator lint_off BLKSEQ */
/* verilator lint_off WIDTH */
/* verilator lint_off PROCASSINIT */
/* verilator lint_off UNUSEDSIGNAL */
module tb_ouch;
    reg clk = 1'b0;
    always #5 clk = ~clk;

    reg          rst = 1'b1, start = 1'b0, is_cancel = 1'b0, side_buy = 1'b0, is_market = 1'b0;
    reg  [111:0] token = 112'd0;
    reg  [31:0]  qty = 32'd0, price = 32'd0;
    reg  [63:0]  symbol = 64'd0;
    wire         busy, out_valid, out_last;
    wire [7:0]   out_data;

    ouch_encoder dut (.clk(clk), .rst(rst), .start(start), .is_cancel(is_cancel), .token(token), .side_buy(side_buy),
                      .qty(qty), .symbol(symbol), .price(price), .is_market(is_market), .busy(busy),
                      .out_valid(out_valid), .out_data(out_data), .out_last(out_last));

    reg [63:0] vec   [0:65535];
    reg [7:0]  bytes [0:4194303];
    reg [63:0] w0, w1, w2, w3, w4;
    integer n, r, b, ep, errors, cr, pos, got_pkts, first_byte_cycle, cyc, start_cyc, min_gap;
    reg        is_x;

    // ---- bộ kiểm tra: mọi byte ra phải bằng byte kỳ vọng kế tiếp ----
    always @(posedge clk) begin
        cyc = cyc + 1;
        if (out_valid) begin
            if (out_data !== bytes[ep]) begin
                if (errors < 10) $display("FAIL goi %0d byte %0d: got %h, mong doi %h", cr, pos, out_data, bytes[ep]);
                errors = errors + 1;
            end
            ep = ep + 1;
            pos = pos + 1;
            if (out_last) begin
                // gói Cancel dài 18 byte, Enter Order dài 36 byte
                if (pos != ((vec[1 + cr * 5][63:56] == "X") ? 18 : 36)) begin
                    if (errors < 10) $display("FAIL goi %0d: dai %0d byte", cr, pos);
                    errors = errors + 1;
                end
                pos = 0; cr = cr + 1; got_pkts = got_pkts + 1;
            end
        end
    end

    initial begin
        errors = 0; ep = 0; cr = 0; pos = 0; got_pkts = 0; cyc = 0; start_cyc = 0; min_gap = 1000000;
        $readmemh("ouch_vec.mem", vec);
        $readmemh("ouch_bytes.mem", bytes);
        n = vec[0];
        repeat (4) @(posedge clk);
        rst <= 1'b0;
        repeat (2) @(posedge clk);

        for (r = 0; r < n; r = r + 1) begin
            b = 1 + r * 5;
            w0 = vec[b]; w1 = vec[b+1]; w2 = vec[b+2]; w3 = vec[b+3]; w4 = vec[b+4];
            while (busy) @(posedge clk);          // đưa lệnh kế tiếp NGAY khi DUT rảnh (sát nhau nhất có thể)
            is_cancel <= (w0[63:56] == "X");
            side_buy  <= (w0[55:48] == "B");
            is_market <= w0[40];
            token     <= {w1, w2[47:0]};
            symbol    <= w3;
            qty       <= w4[63:32];
            price     <= w4[31:0];
            start     <= 1'b1;
            @(posedge clk);
            start     <= 1'b0;
            if (r > 0 && cyc - start_cyc < min_gap) min_gap = cyc - start_cyc;
            start_cyc = cyc;
            @(posedge clk);                       // busy lên sau cạnh nhận start
        end
        b = 0;
        while (got_pkts < n && b < 1000) begin @(posedge clk); b = b + 1; end

        if (got_pkts != n) begin $display("FAIL: nhan %0d goi, mong doi %0d", got_pkts, n); errors = errors + 1; end
        if (errors == 0) $display("PASS: %0d goi (%0d byte) khop tung byte voi golden Python", n, ep);
        else             $display("FAILED: %0d loi", errors);
        $finish;
    end
endmodule
