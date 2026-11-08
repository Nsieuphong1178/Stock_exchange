// Testbench tick-to-trade: khung Ethernet -> parser -> book -> chiến lược -> risk -> mã hoá OUCH.
//
// Kiểm tra so với golden (gen_book_vectors.py --t2t):
//   - mọi byte lệnh ra khớp từng byte (gồm token tăng dần), đúng thứ tự, đúng số lệnh
//   - số lệnh bị risk loại theo từng lý do
//   - không FIFO nào tràn
// Đo độ trễ tick-to-trade: số chu kỳ từ chu kỳ mang BYTE CUỐI của message market data (cuối message ITCH, không tính
// byte đệm cuối khung) tới chu kỳ mang BYTE ĐẦU của lệnh ở đầu ra.
//
// Cấu hình chiến lược/risk bên dưới PHẢI khớp T2T trong gen_book_vectors.py.
`timescale 1ns/1ps
/* verilator lint_off BLKSEQ */
/* verilator lint_off WIDTH */
/* verilator lint_off PROCASSINIT */
/* verilator lint_off UNUSEDSIGNAL */
module tb_t2t;
    reg clk = 1'b0;
    always #5 clk = ~clk;

    reg        rst = 1'b1;
    reg        in_valid = 1'b0, in_last = 1'b0;
    reg [7:0]  in_data = 8'd0;

    wire        out_valid, out_last, parsed_valid, book_done, order_started, rej_valid, overflow, pipe_idle;
    wire [7:0]  out_data;
    wire [3:0]  rej_reason;

    tick_to_trade #(.STRAT_SYM(2'd0), .BUY_BELOW(12'd500), .SELL_ABOVE(12'd3700), .ORDER_QTY(32'd10),
                    .MAX_QTY(32'd1000), .MIN_PX(32'd100), .MAX_PX(32'd3900), .MAX_NOTIONAL(64'd38000),
                    .MAX_POS(32'd2000)) dut (
        .clk(clk), .rst(rst), .kill(1'b0), .in_valid(in_valid), .in_data(in_data), .in_last(in_last),
        .out_valid(out_valid), .out_data(out_data), .out_last(out_last), .parsed_valid(parsed_valid),
        .book_done(book_done), .order_started(order_started), .rej_valid(rej_valid), .rej_reason(rej_reason),
        .overflow(overflow), .pipe_idle(pipe_idle));

    reg [9:0]  stream [0:16777215];
    reg [31:0] pexp   [0:3];            // pipe_expect.mem: {số từ luồng, số message hợp lệ, số khung lỗi, số lỗi book}
    reg [63:0] texp   [0:65535];        // t2t_expect.mem: {số lệnh, 6 bộ đếm lý do loại, chỉ số message sinh ra từng lệnh}
    reg [7:0]  bytes  [0:4194303];      // t2t_bytes.mem: byte mong đợi của mọi lệnh, nối tiếp
    integer    msg_cyc [0:262143];      // chu kỳ mang byte cuối của message thứ i
    integer n_words, n_orders, n_msgs, i, errors, cyc, ep, pos, cur, got_orders, k;
    integer rej_cnt [0:7];
    integer lat, lat_min, lat_max, lat_sum;
    integer hist [0:7];                 // phân bố: <=16, <=24, <=32, <=48, <=64, <=96, <=128, >128 chu kỳ
    reg [9:0] w;

    always @(posedge clk) begin
        cyc = cyc + 1;
        if (parsed_valid) begin msg_cyc[n_msgs] = cyc - 1; n_msgs = n_msgs + 1; end
        if (rej_valid) rej_cnt[rej_reason] = rej_cnt[rej_reason] + 1;
        if (out_valid) begin
            if (pos == 0) begin                       // byte đầu của một lệnh: đo độ trễ
                if (cur >= n_orders) begin
                    if (errors < 10) $display("FAIL: lenh thua thu %0d", cur);
                    errors = errors + 1;
                end else begin
                    lat = cyc - msg_cyc[texp[7 + cur]];
                    if (lat < lat_min) lat_min = lat;
                    if (lat > lat_max) lat_max = lat;
                    lat_sum = lat_sum + lat;
                    hist[(lat <= 16) ? 0 : (lat <= 24) ? 1 : (lat <= 32) ? 2 : (lat <= 48) ? 3 :
                         (lat <= 64) ? 4 : (lat <= 96) ? 5 : (lat <= 128) ? 6 : 7] =
                        hist[(lat <= 16) ? 0 : (lat <= 24) ? 1 : (lat <= 32) ? 2 : (lat <= 48) ? 3 :
                             (lat <= 64) ? 4 : (lat <= 96) ? 5 : (lat <= 128) ? 6 : 7] + 1;
                end
            end
            if (out_data !== bytes[ep]) begin
                if (errors < 10) $display("FAIL lenh %0d byte %0d: got %h, mong doi %h", cur, pos, out_data, bytes[ep]);
                errors = errors + 1;
            end
            ep = ep + 1; pos = pos + 1;
            if (out_last) begin
                if (pos != 36) begin
                    if (errors < 10) $display("FAIL lenh %0d: dai %0d byte", cur, pos);
                    errors = errors + 1;
                end
                pos = 0; cur = cur + 1; got_orders = got_orders + 1;
            end
        end
    end

    initial begin
        errors = 0; cyc = 0; ep = 0; pos = 0; cur = 0; got_orders = 0; n_msgs = 0;
        lat_min = 1000000; lat_max = 0; lat_sum = 0;
        for (k = 0; k < 8; k = k + 1) begin rej_cnt[k] = 0; hist[k] = 0; end
        $readmemh("pipe_expect.mem", pexp);
        $readmemh("pipe_frames.mem", stream);
        $readmemh("t2t_expect.mem", texp);
        $readmemh("t2t_bytes.mem", bytes);
        n_words  = pexp[0];
        n_orders = texp[0];

        repeat (4) @(posedge clk);
        rst <= 1'b0;
        repeat (32800) @(posedge clk);   // book quét xoá bộ nhớ sau reset

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
        while (!pipe_idle && i < 200000) begin @(posedge clk); i = i + 1; end  // đợi book xử lý hết (có thể lâu: xem ghi chú)
        repeat (200) @(posedge clk);     // đợi thêm để risk / bộ mã hoá xong và bắt lệnh thừa nếu có

        if (n_msgs != pexp[1])      begin $display("FAIL: parser decode %0d message, mong doi %0d", n_msgs, pexp[1]); errors = errors + 1; end
        if (got_orders != n_orders) begin $display("FAIL: %0d lenh ra, mong doi %0d", got_orders, n_orders); errors = errors + 1; end
        for (k = 1; k <= 6; k = k + 1)
            if (rej_cnt[k] != texp[k]) begin
                $display("FAIL: ly do loai %0d: %0d lan, mong doi %0d", k, rej_cnt[k], texp[k]); errors = errors + 1;
            end
        if (overflow) begin $display("FAIL: co FIFO tran"); errors = errors + 1; end

        $display("tick-to-trade (chu ky, tu byte cuoi message den byte dau lenh), %0d lenh:", got_orders);
        $display("   nho nhat %0d, trung binh %0d, lon nhat %0d", lat_min, lat_sum / got_orders, lat_max);
        $display("   phan bo: <=16:%0d  <=24:%0d  <=32:%0d  <=48:%0d  <=64:%0d  <=96:%0d  <=128:%0d  >128:%0d",
                 hist[0], hist[1], hist[2], hist[3], hist[4], hist[5], hist[6], hist[7]);
        if (errors == 0) $display("PASS: %0d khung -> %0d lenh khop tung byte voi golden; risk loai dung %0d/%0d/%0d/%0d (QTY/PRICE/NOTIONAL/EXPOSURE)",
                                  n_msgs, got_orders, rej_cnt[2], rej_cnt[3], rej_cnt[4], rej_cnt[5]);
        else             $display("FAILED: %0d loi", errors);
        $finish;
    end
endmodule
