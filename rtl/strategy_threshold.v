// Chiến lược đơn giản, XÁC ĐỊNH, đủ để chứng minh đường tick-to-trade (không phải chiến lược thật):
// mỗi khi sổ lệnh của mã SYM thay đổi thành công:
//   - best ask <= BUY_BELOW   => MUA  QTY ở đúng giá best ask   (ăn ngay lệnh bán rẻ)
//   - best bid >= SELL_ABOVE  => BÁN  QTY ở đúng giá best bid
// Mua được ưu tiên nếu cả hai cùng đúng. Mỗi lần sổ đổi tối đa một lệnh. Logic phức tạp hơn (mô hình thống kê, tín hiệu
// nhiều mã...) thường ở lại CPU; trên FPGA chỉ giữ các điều kiện kiểu này vì chúng chạy trong 1 chu kỳ.
module strategy_threshold #(
    parameter [1:0]  SYM        = 2'd0,
    parameter [11:0] BUY_BELOW  = 12'd500,
    parameter [11:0] SELL_ABOVE = 12'd3700,
    parameter [31:0] QTY        = 32'd10
) (
    input  wire        clk,
    input  wire        rst,
    input  wire        tick,          // sổ lệnh vừa cập nhật thành công
    input  wire [1:0]  tick_sym,      // ... mã nào
    input  wire [11:0] bid_px,        // giá mua / bán tốt nhất của mã đó (0 = bên đó trống)
    input  wire [11:0] ask_px,
    output reg         order_valid,
    output reg         order_buy,
    output reg  [31:0] order_qty,
    output reg  [31:0] order_price,
    output reg  [1:0]  order_sym
);
    always @(posedge clk) begin
        order_valid <= 1'b0;
        if (!rst && tick && tick_sym == SYM) begin
            if (ask_px != 12'd0 && ask_px <= BUY_BELOW) begin
                order_valid <= 1'b1; order_buy <= 1'b1;
                order_qty   <= QTY;  order_price <= {20'd0, ask_px}; order_sym <= SYM;
            end else if (bid_px != 12'd0 && bid_px >= SELL_ABOVE) begin
                order_valid <= 1'b1; order_buy <= 1'b0;
                order_qty   <= QTY;  order_price <= {20'd0, bid_px}; order_sym <= SYM;
            end
        end
    end
endmodule
