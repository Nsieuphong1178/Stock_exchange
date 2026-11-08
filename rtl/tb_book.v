// Testbench cho itch_book: đọc luồng message + kỳ vọng từ book_msgs.mem (gen_book_vectors.py sinh).
//
// Mỗi message: đẩy vào DUT, đợi `done`, rồi so (a) mã lỗi, (b) giá/qty tốt nhất của mã bị ảnh hưởng.
// Cuối cùng quét TOÀN BỘ bảng mức giá qua cổng debug và so với book_final.mem.
// Cũng đo số chu kỳ xử lý (từ lúc DUT nhận message tới lúc `done`) cho từng loại message.
//
// book_msgs.mem: từ 0 = số bản ghi; mỗi bản ghi 8 từ 64 bit
//   w0 {type[63:56], side[55:48], exp_err[47:40], exp_sym[39:32], 32'h0}
//   w1 order_id    w2 {qty, price}    w3 symbol
//   w4 bid_px  w5 bid_qty  w6 ask_px  w7 ask_qty    (kỳ vọng SAU khi xử lý, của mã exp_sym)
`timescale 1ns/1ps
/* verilator lint_off BLKSEQ */
/* verilator lint_off WIDTH */
/* verilator lint_off PROCASSINIT */
/* verilator lint_off UNUSEDSIGNAL */
module tb_book;
    reg clk = 1'b0;
    always #5 clk = ~clk;

    reg         rst = 1'b1;
    reg         msg_valid = 1'b0;
    reg  [7:0]  msg_type = 8'd0, side = 8'd0;
    reg  [63:0] order_id = 64'd0, symbol = 64'd0;
    reg  [31:0] qty = 32'd0, price = 32'd0;
    reg  [1:0]  q_sym = 2'd0;
    reg  [14:0] dbg_addr = 15'd0;

    wire        busy, done;
    wire [3:0]  err;
    wire [1:0]  done_sym;
    wire [11:0] best_bid_px, best_ask_px;
    wire [31:0] best_bid_qty, best_ask_qty, dbg_qty;

    itch_book dut (
        .clk(clk), .rst(rst), .msg_valid(msg_valid), .msg_type(msg_type), .order_id(order_id), .side(side),
        .qty(qty), .symbol(symbol), .price(price), .busy(busy), .done(done), .err(err), .done_sym(done_sym), .q_sym(q_sym),
        .best_bid_px(best_bid_px), .best_bid_qty(best_bid_qty), .best_ask_px(best_ask_px),
        .best_ask_qty(best_ask_qty), .dbg_addr(dbg_addr), .dbg_qty(dbg_qty));

    reg [63:0] recs [0:1048575];
    reg [31:0] final_mem [0:24575];
    reg [63:0] w0;
    integer n, r, b, cyc, errors, a, t;
    integer sum_cyc [0:2];   // A, E, D
    integer max_cyc [0:2];
    integer cnt     [0:2];

    initial begin
        errors = 0;
        for (t = 0; t < 3; t = t + 1) begin sum_cyc[t] = 0; max_cyc[t] = 0; cnt[t] = 0; end
        $readmemh("book_msgs.mem", recs);
        $readmemh("book_final.mem", final_mem);
        n = recs[0];

        repeat (4) @(posedge clk);
        rst <= 1'b0;
        @(posedge clk);
        while (busy) @(posedge clk);  // đợi quét xoá bộ nhớ sau reset xong

        for (r = 0; r < n; r = r + 1) begin
            b  = 1 + r * 8;
            w0 = recs[b];
            @(posedge clk);
            msg_valid <= 1'b1;
            msg_type  <= w0[63:56];
            side      <= w0[55:48];
            order_id  <= recs[b+1];
            qty       <= recs[b+2][63:32];
            price     <= recs[b+2][31:0];
            symbol    <= recs[b+3];
            q_sym     <= w0[33:32];
            @(posedge clk);
            msg_valid <= 1'b0;
            cyc = 0;
            while (!done && cyc < 100000) begin @(posedge clk); cyc = cyc + 1; end

            if (!done) begin
                $display("FAIL rec %0d: khong thay done", r); errors = errors + 1;
            end else begin
                if (err !== w0[47:40]) begin
                    $display("FAIL rec %0d type=%c: err=%0d, mong doi %0d", r, w0[63:56], err, w0[47:40]);
                    errors = errors + 1;
                end
                if (best_bid_px !== recs[b+4][11:0] || best_bid_qty !== recs[b+5][31:0] ||
                    best_ask_px !== recs[b+6][11:0] || best_ask_qty !== recs[b+7][31:0]) begin
                    $display("FAIL rec %0d type=%c: bid %0d x %0d / ask %0d x %0d, mong doi bid %0d x %0d / ask %0d x %0d",
                             r, w0[63:56], best_bid_px, best_bid_qty, best_ask_px, best_ask_qty,
                             recs[b+4], recs[b+5], recs[b+6], recs[b+7]);
                    errors = errors + 1;
                end
            end
            if (w0[47:40] == 8'd4) $display("   tra order_id KHONG TON TAI mat %0d chu ky", cyc);
            // thống kê chu kỳ của các message không lỗi
            if (w0[47:40] == 8'd0) begin
                t = (w0[63:56] == "A") ? 0 : (w0[63:56] == "E") ? 1 : 2;
                sum_cyc[t] = sum_cyc[t] + cyc; cnt[t] = cnt[t] + 1;
                if (cyc > max_cyc[t]) max_cyc[t] = cyc;
            end
            if (errors > 10) begin $display("qua nhieu loi, dung"); $finish; end
        end

        // quét toàn bộ bảng mức giá
        for (a = 0; a < 24576; a = a + 1) begin
            dbg_addr = a;
            @(posedge clk);   // cổng debug đọc đồng bộ: dữ liệu về sau 1 chu kỳ
            #1;
            if (dbg_qty !== final_mem[a]) begin
                if (errors < 20) $display("FAIL bang gia cuoi: addr %0d (ma %0d, ben %0d, gia %0d) = %0d, mong doi %0d",
                                          a, a / 8192, (a / 4096) % 2, a % 4096, dbg_qty, final_mem[a]);
                errors = errors + 1;
            end
        end

        $display("so chu ky xu ly (nhan -> done), khong tinh message loi:");
        $display("   A: trung binh %0d, toi da %0d (%0d message)", sum_cyc[0] / cnt[0], max_cyc[0], cnt[0]);
        $display("   E: trung binh %0d, toi da %0d (%0d message)", sum_cyc[1] / cnt[1], max_cyc[1], cnt[1]);
        $display("   D: trung binh %0d, toi da %0d (%0d message)", sum_cyc[2] / cnt[2], max_cyc[2], cnt[2]);
        if (errors == 0) $display("PASS: %0d message + toan bo bang gia khop golden", n);
        else             $display("FAILED: %0d loi", errors);
        $finish;
    end
endmodule
