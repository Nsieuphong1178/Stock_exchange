// Bộ mã hoá lệnh OUCH: điền các trường vào một KHUÔN CỐ ĐỊNH rồi phát từng byte của gói 'U'
// (định dạng: server/ouch.hpp, golden: client/ouch.py).
//
//   Enter Order (36 byte): length[2]=34 | 'U' | 'O' | token[14] | side[1] | qty[4] | symbol[8] | price[4] | type[1]
//   Cancel      (18 byte): length[2]=16 | 'U' | 'X' | token[14]
//
// Đây là khối "dễ nhất" của đường gửi lệnh trong FPGA: không có vòng lặp hay rẽ nhánh phức tạp, mọi trường nằm ở
// offset cố định, chỉ là ghép bit. Phần khó là tầng TCP phía sau (số thứ tự, ACK, gửi lại) - chưa làm.
// Ở đây phát 1 byte/chu kỳ để dễ đọc; datapath 64 bit sẽ phát cả gói trong 5 chu kỳ.
module ouch_encoder (
    input  wire         clk,
    input  wire         rst,
    input  wire         start,       // 1 chu kỳ: nhận lệnh (bỏ qua nếu đang bận)
    input  wire         is_cancel,   // 0: Enter Order, 1: Cancel
    input  wire [111:0] token,       // 14 byte ASCII (đã đệm khoảng trắng), byte đầu ở bit cao
    input  wire         side_buy,    // 1 = 'B', 0 = 'S'
    input  wire [31:0]  qty,
    input  wire [63:0]  symbol,      // 8 ký tự ASCII
    input  wire [31:0]  price,
    input  wire         is_market,   // 1 = 'M', 0 = 'L'; trường price vẫn được phát nguyên như đã cho
    output reg          busy,
    output reg          out_valid,
    output reg  [7:0]   out_data,
    output reg          out_last
);
    localparam [5:0] LAST_ENTER = 6'd35, LAST_CANCEL = 6'd17;

    reg [287:0] pkt;       // gói đã ghép sẵn (Cancel dùng 144 bit đầu, phần còn lại không phát)
    reg [5:0]   idx;       // byte kế tiếp cần phát
    reg [5:0]   last_idx;

    always @(posedge clk) begin
        out_valid <= 1'b0;
        out_last  <= 1'b0;
        if (rst) begin
            busy <= 1'b0;
        end else if (start && !busy) begin
            busy <= 1'b1;
            idx  <= 6'd0;
            if (is_cancel) begin
                pkt      <= {16'd16, "U", "X", token, 144'd0};
                last_idx <= LAST_CANCEL;
            end else begin
                pkt      <= {16'd34, "U", "O", token, (side_buy ? "B" : "S"), qty, symbol, price, (is_market ? "M" : "L")};
                last_idx <= LAST_ENTER;
            end
        end else if (busy) begin
            out_valid <= 1'b1;
            out_data  <= pkt[287 - 8 * idx -: 8];
            out_last  <= (idx == last_idx);
            idx       <= idx + 6'd1;
            if (idx == last_idx) busy <= 1'b0;
        end
    end
endmodule
