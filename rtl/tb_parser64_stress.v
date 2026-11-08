// Thử sức parser64 với 1.000.000 message ngẫu nhiên (tới 8 message/gói, có VLAN, heartbeat, rơi/trùng gói, khung lỗi).
// File mong đợi từng sự kiện sẽ rất lớn, nên so bằng BĂM CUỘN: mỗi sự kiện đưa vào h = (h ^ w) * FNV_PRIME (64 bit) theo cùng
// thứ tự với gen_vectors64.py. Hai bên khớp băm và số sự kiện => (với xác suất cực cao) mọi sự kiện đều đúng và đúng thứ tự.
// p64_stress_expect.mem: {số từ luồng, số sự kiện, băm}
`timescale 1ns/1ps
/* verilator lint_off BLKSEQ */
/* verilator lint_off WIDTH */
/* verilator lint_off PROCASSINIT */
/* verilator lint_off UNUSEDSIGNAL */
module tb_parser64_stress;
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

    reg [73:0] stream [0:8388607];
    reg [63:0] expv   [0:3];
    reg [63:0] h;
    localparam [63:0] PRIME = 64'h100000001B3;
    integer n_words, i, n_events, n_msg, n_drop;
    reg [73:0] w;

    task mix(input [63:0] x);
        h = (h ^ x) * PRIME;
    endtask

    always @(posedge clk) begin
        if (msg_valid) begin
            mix({8'h01, msg_type, side, 8'h00, 31'h0, msg_gap});
            mix(seq); mix(order_id); mix(match_no); mix({qty, price}); mix(symbol);
            n_events = n_events + 1; n_msg = n_msg + 1;
        end
        if (drop_valid) begin
            mix({8'h02, 16'h0000, 4'h0, drop_reason, 32'h0});
            n_events = n_events + 1; n_drop = n_drop + 1;
        end
    end

    initial begin
        h = 64'hCBF29CE484222325; n_events = 0; n_msg = 0; n_drop = 0;
        $readmemh("p64_stress_frames.mem", stream);
        $readmemh("p64_stress_expect.mem", expv);
        n_words = expv[0];
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
        if (n_events == expv[1] && h === expv[2])
            $display("PASS: %0d tu 64 bit -> %0d su kien (%0d message, %0d khung loai), bam %h khop golden",
                     n_words, n_events, n_msg, n_drop, h);
        else
            $display("FAILED: %0d su kien (mong doi %0d), bam %h (mong doi %h)", n_events, expv[1], h, expv[2]);
        $finish;
    end
endmodule
