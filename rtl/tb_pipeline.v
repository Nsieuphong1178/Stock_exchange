// Testbench ghép: khung Ethernet (pipe_frames.mem) -> parser -> FIFO -> book. So với golden:
//   - số message parser decode, số khung bị loại, số lỗi book báo, không tràn FIFO, không gap
//   - TOÀN BỘ bảng mức giá cuối cùng so với book_final.mem
// pipe_expect.mem: 4 từ 32 bit {số từ luồng, số message hợp lệ, số khung bị loại, số lỗi book (cố ý)}
// pipe_frames.mem: mỗi từ 10 bit: bit9 = chu kỳ rảnh, bit8 = byte cuối khung, bit7:0 = dữ liệu
`timescale 1ns/1ps
/* verilator lint_off BLKSEQ */
/* verilator lint_off WIDTH */
/* verilator lint_off PROCASSINIT */
/* verilator lint_off UNUSEDSIGNAL */
module tb_pipeline;
    reg clk = 1'b0;
    always #5 clk = ~clk;

    reg        rst = 1'b1;
    reg        in_valid = 1'b0, in_last = 1'b0;
    reg [7:0]  in_data = 8'd0;
    reg [1:0]  q_sym = 2'd0;
    reg [14:0] dbg_addr = 15'd0;

    wire        parsed_valid, parsed_gap, drop_valid, book_done, fifo_overflow, idle;
    wire [3:0]  drop_reason, book_err;
    wire [1:0]  book_done_sym;
    wire [11:0] best_bid_px, best_ask_px;
    wire [31:0] best_bid_qty, best_ask_qty, dbg_qty;

    itch_pipeline dut (
        .clk(clk), .rst(rst), .in_valid(in_valid), .in_data(in_data), .in_last(in_last),
        .parsed_valid(parsed_valid), .parsed_gap(parsed_gap), .drop_valid(drop_valid), .drop_reason(drop_reason),
        .book_done(book_done), .book_err(book_err), .book_done_sym(book_done_sym), .fifo_overflow(fifo_overflow), .q_sym(q_sym),
        .best_bid_px(best_bid_px), .best_bid_qty(best_bid_qty), .best_ask_px(best_ask_px),
        .best_ask_qty(best_ask_qty), .dbg_addr(dbg_addr), .dbg_qty(dbg_qty), .idle(idle));

    reg [9:0]  stream [0:16777215];
    reg [31:0] expv   [0:3];
    reg [31:0] final_mem [0:24575];
    integer n_words, i, a, errors;
    integer n_msg, n_drop, n_gap, n_done, n_book_err;
    reg [9:0] w;

    // đếm sự kiện (lấy mẫu trước cạnh lên, cùng quy ước với các testbench khác)
    always @(posedge clk) begin
        if (parsed_valid) n_msg  = n_msg + 1;
        if (parsed_gap && parsed_valid) n_gap = n_gap + 1;
        if (drop_valid)   n_drop = n_drop + 1;
        if (book_done) begin
            n_done = n_done + 1;
            if (book_err != 4'd0) n_book_err = n_book_err + 1;
        end
    end

    initial begin
        errors = 0; n_msg = 0; n_drop = 0; n_gap = 0; n_done = 0; n_book_err = 0;
        $readmemh("pipe_expect.mem", expv);
        $readmemh("pipe_frames.mem", stream);
        $readmemh("book_final.mem", final_mem);
        n_words = expv[0];

        repeat (4) @(posedge clk);
        rst <= 1'b0;
        repeat (32800) @(posedge clk);  // book quét xoá bộ nhớ sau reset (32768 chu kỳ)

        for (i = 0; i < n_words; i = i + 1) begin
            w = stream[i];
            @(posedge clk);
            in_valid <= ~w[9];
            in_data  <= w[7:0];
            in_last  <= w[8] & ~w[9];
        end
        @(posedge clk);
        in_valid <= 1'b0; in_last <= 1'b0;
        i = 0;
        while (!idle && i < 100000) begin @(posedge clk); i = i + 1; end  // đợi FIFO và book xử lý nốt
        repeat (10) @(posedge clk);

        if (n_msg != expv[1])      begin $display("FAIL: parser decode %0d message, mong doi %0d", n_msg, expv[1]); errors = errors + 1; end
        if (n_drop != expv[2])     begin $display("FAIL: %0d khung bi loai, mong doi %0d", n_drop, expv[2]); errors = errors + 1; end
        if (n_done != expv[1])     begin $display("FAIL: book xu ly %0d message, mong doi %0d", n_done, expv[1]); errors = errors + 1; end
        if (n_book_err != expv[3]) begin $display("FAIL: book bao %0d loi, mong doi %0d", n_book_err, expv[3]); errors = errors + 1; end
        if (n_gap != 0)            begin $display("FAIL: %0d gap, mong doi 0", n_gap); errors = errors + 1; end
        if (fifo_overflow)         begin $display("FAIL: FIFO tran"); errors = errors + 1; end

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

        if (errors == 0) $display("PASS: %0d khung -> %0d message -> so lenh khop golden (%0d khung loai, %0d loi co y, FIFO khong tran)",
                                  n_msg + n_drop, n_msg, n_drop, n_book_err);
        else             $display("FAILED: %0d loi", errors);
        $finish;
    end
endmodule
