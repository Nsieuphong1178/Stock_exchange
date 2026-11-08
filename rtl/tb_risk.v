// Testbench kịch bản cho pretrade_risk: kết quả mong đợi viết cứng (khối này có yếu tố thời gian nên không dùng golden Python).
//   DUT A: kiểm tra từng lý do loại + thứ tự ưu tiên + cộng dồn exposure + kill switch (không giới hạn tốc độ)
//   DUT B: giới hạn tốc độ: tối đa 3 lệnh mỗi cửa sổ 40 chu kỳ
`timescale 1ns/1ps
/* verilator lint_off BLKSEQ */
/* verilator lint_off WIDTH */
/* verilator lint_off PROCASSINIT */
/* verilator lint_off UNUSEDSIGNAL */
module tb_risk;
    reg clk = 1'b0;
    always #5 clk = ~clk;
    reg rst = 1'b1, kill = 1'b0;
    reg va = 1'b0, vb = 1'b0, buy = 1'b0;
    reg [31:0] qty = 32'd0, price = 32'd0;
    reg [1:0]  sym = 2'd1;

    wire        ova, ovb, bya, byb, rja, rjb;
    wire [31:0] qa, qb, pa, pb;
    wire [1:0]  sa, sb;
    wire [3:0]  rra, rrb;

    localparam [3:0] KILL = 1, QTY = 2, PRICE = 3, NOTIONAL = 4, EXPOSURE = 5, RATE = 6;

    pretrade_risk #(.MAX_QTY(100), .MIN_PX(10), .MAX_PX(1000), .MAX_NOTIONAL(50000), .MAX_POS(250)) a (
        .clk(clk), .rst(rst), .kill(kill), .in_valid(va), .in_buy(buy), .in_qty(qty), .in_price(price), .in_sym(sym),
        .out_valid(ova), .out_buy(bya), .out_qty(qa), .out_price(pa), .out_sym(sa), .rej_valid(rja), .rej_reason(rra));
    pretrade_risk #(.MAX_QTY(100), .MIN_PX(10), .MAX_PX(1000), .MAX_NOTIONAL(50000), .MAX_POS(100000),
                    .RATE_MAX(3), .RATE_WINDOW(40)) b (
        .clk(clk), .rst(rst), .kill(1'b0), .in_valid(vb), .in_buy(buy), .in_qty(qty), .in_price(price), .in_sym(sym),
        .out_valid(ovb), .out_buy(byb), .out_qty(qb), .out_price(pb), .out_sym(sb), .rej_valid(rjb), .rej_reason(rrb));

    integer errors = 0, cases = 0;

    // Gửi một lệnh vào DUT `which` (0 = A, 1 = B) rồi kiểm tra kết quả khi DUT đã chốt (sau 3 tầng).
    task send(input which, input is_buy, input [31:0] q, input [31:0] px, input exp_pass, input [3:0] exp_reason);
        reg ov, rj;
        reg [3:0] rr;
        reg [31:0] oq, op;
        begin
            @(posedge clk);
            buy <= is_buy; qty <= q; price <= px;
            if (which) vb <= 1'b1; else va <= 1'b1;
            @(posedge clk);
            va <= 1'b0; vb <= 1'b0;
            @(posedge clk);
            @(posedge clk);   // risk có 3 tầng pipeline
            @(posedge clk);
            ov = which ? ovb : ova;  rj = which ? rjb : rja;  rr = which ? rrb : rra;
            oq = which ? qb : qa;    op = which ? pb : pa;
            cases = cases + 1;
            if (exp_pass) begin
                if (!(ov && !rj && oq === q && op === px)) begin
                    $display("FAIL case %0d: mong doi QUA (buy=%0d qty=%0d px=%0d), got ov=%0d rj=%0d reason=%0d",
                             cases, is_buy, q, px, ov, rj, rr);
                    errors = errors + 1;
                end
            end else if (!(rj && !ov && rr === exp_reason)) begin
                $display("FAIL case %0d: mong doi LOAI ly do %0d (buy=%0d qty=%0d px=%0d), got ov=%0d rj=%0d reason=%0d",
                         cases, exp_reason, is_buy, q, px, ov, rj, rr);
                errors = errors + 1;
            end
        end
    endtask

    initial begin
        repeat (4) @(posedge clk);
        rst <= 1'b0;
        repeat (2) @(posedge clk);

        // ---- DUT A ----
        send(0, 1, 100, 100, 1, 0);   //  1 qua; exposure mua = 100
        send(0, 1, 0,   100, 0, QTY);       //  2 qty = 0
        send(0, 1, 101, 100, 0, QTY);       //  3 qty > MAX_QTY
        send(0, 1, 10,  9,   0, PRICE);     //  4 giá dưới dải
        send(0, 1, 10,  1001, 0, PRICE);    //  5 giá trên dải
        send(0, 1, 100, 600, 0, NOTIONAL);  //  6 giá trị 60000 > 50000
        send(0, 1, 100, 100, 1, 0);   //  7 qua; exposure mua = 200
        send(0, 1, 100, 100, 0, EXPOSURE);  //  8 mua thêm 100 => 300 > 250
        send(0, 0, 100, 100, 1, 0);   //  9 bên bán tính riêng: 100
        send(0, 0, 100, 100, 1, 0);   // 10 bán 200
        send(0, 0, 100, 100, 0, EXPOSURE);  // 11 bán 300 > 250
        send(0, 1, 50,  100, 1, 0);   // 12 mua đúng chạm giới hạn: 250 (không vượt) vẫn qua
        send(0, 1, 1,   100, 0, EXPOSURE);  // 13 vượt 1 đơn vị
        send(0, 1, 0,   5,   0, QTY);       // 14 ưu tiên: qty xấu và giá xấu => QTY
        send(0, 1, 100, 1001, 0, PRICE);    // 15 ưu tiên: giá xấu và giá trị xấu => PRICE
        kill = 1'b1;
        send(0, 0, 1,   100, 0, KILL);      // 16 kill chặn lệnh hợp lệ
        send(0, 1, 0,   5,   0, KILL);      // 17 kill ưu tiên cao nhất
        kill = 1'b0;
        send(0, 0, 1,   100, 1, 0);   // 18 hết kill: qua (bán 201)

        // ---- DUT B: giới hạn tốc độ 3 lệnh / 40 chu kỳ ----
        rst = 1'b1; @(posedge clk); @(posedge clk); rst = 1'b0;  // cửa sổ bắt đầu lại từ 0
        send(1, 1, 1, 100, 1, 0);     // 19
        send(1, 1, 1, 100, 1, 0);     // 20
        send(1, 1, 1, 100, 1, 0);     // 21
        send(1, 1, 1, 100, 0, RATE);  // 22 lệnh thứ 4 trong cửa sổ
        send(1, 1, 1, 100, 0, RATE);  // 23
        repeat (45) @(posedge clk);   // sang cửa sổ mới
        send(1, 1, 1, 100, 1, 0);     // 24 cửa sổ mới: qua lại

        repeat (5) @(posedge clk);
        if (errors == 0) $display("PASS: %0d tinh huong risk (cac ly do loai, uu tien, exposure, kill, toc do) dung", cases);
        else             $display("FAILED: %0d loi", errors);
        $finish;
    end
endmodule
