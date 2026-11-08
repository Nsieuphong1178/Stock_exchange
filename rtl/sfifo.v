// FIFO đồng bộ nhỏ, đọc "first-word-fall-through": rd_data luôn là phần tử đầu hàng (hợp lệ khi !empty).
// Đầy thì bỏ phần tử mới và bật cờ `overflow` (dính cho tới reset): phía trên phải coi là sự cố.
module sfifo #(
    parameter W  = 8,
    parameter AW = 3          // 2^AW phần tử
) (
    input  wire         clk,
    input  wire         rst,
    input  wire         wr_en,
    input  wire [W-1:0] wr_data,
    input  wire         rd_en,
    output wire [W-1:0] rd_data,
    output wire         empty,
    output reg          overflow,
    output reg  [AW:0]  max_level   // mức đầy cao nhất từng đạt (để chọn độ sâu FIFO dựa trên số đo, không đoán)
);
    reg [W-1:0]  mem [0:(1<<AW)-1];
    reg [AW:0]   wr, rd;                      // thừa 1 bit để phân biệt đầy / rỗng
    wire         full = (wr[AW-1:0] == rd[AW-1:0]) && (wr[AW] != rd[AW]);

    wire [AW:0]  level = wr - rd;

    assign empty   = (wr == rd);
    assign rd_data = mem[rd[AW-1:0]];

    always @(posedge clk) begin
        if (rst) begin
            wr <= 0; rd <= 0; overflow <= 1'b0; max_level <= 0;
        end else begin
            if (level > max_level) max_level <= level;
            if (wr_en) begin
                if (full) overflow <= 1'b1;
                else begin
                    mem[wr[AW-1:0]] <= wr_data;
                    wr <= wr + 1'b1;
                end
            end
            if (rd_en && !empty) rd <= rd + 1'b1;
        end
    end
endmodule
