// Kiểm tra rủi ro TRƯỚC khi gửi lệnh (pre-trade risk). Quy định pháp lý buộc phải có và nằm TRÊN đường găng, nên phải
// nhanh: mọi phép kiểm tra là so sánh độc lập, tính SONG SONG, không tuần tự như phần mềm.
//
// Thứ tự ưu tiên khi nhiều điều kiện cùng vi phạm (trả về lý do đầu tiên): KILL, QTY, PRICE, NOTIONAL, EXPOSURE, RATE.
//   KILL     : công tắc ngắt khẩn cấp đang bật
//   QTY      : số lượng bằng 0 hoặc vượt MAX_QTY
//   PRICE    : giá ngoài dải [MIN_PX, MAX_PX]
//   NOTIONAL : giá x số lượng vượt MAX_NOTIONAL
//   EXPOSURE : tổng qty đã phát ra theo bên (mua / bán) cộng lệnh này vượt MAX_POS
//              (không có phản hồi khớp lệnh trong mô hình này, nên mọi lệnh đã phát được tính là có thể khớp hết)
//   RATE     : đã phát RATE_MAX lệnh trong cửa sổ RATE_WINDOW chu kỳ hiện tại (cửa sổ cố định nối tiếp nhau)
// Lệnh qua được ra ở out_* sau 3 chu kỳ; lệnh bị loại báo ở rej_valid / rej_reason (cũng sau 3 chu kỳ).
//
// Ba tầng pipeline (sửa đường găng tìm thấy bằng nextpnr, xem docs/ARCHITECTURE.md; mỗi tầng thêm 1 chu kỳ độ trễ để đổi lấy Fmax):
//   Tầng 0: bốn tích riêng 16x16 (giá x qty chia 4), kiểm tra qty và dải giá: không phụ thuộc trạng thái.
//   Tầng 1: cộng các tích riêng thành giá trị lệnh 64 bit.
//   Tầng 2: những gì phụ thuộc trạng thái (exposure, tốc độ, kill) và chọn lý do; cập nhật trạng thái ở đây nên các lệnh
//           liên tiếp vẫn được xét ĐÚNG THỨ TỰ (lệnh sau thấy exposure sau khi lệnh trước đã được tính).
// Exposure lưu dưới dạng "còn bao nhiêu hạn mức" (room = MAX_POS - đã dùng): kiểm tra thành `qty > room`, một phép so sánh,
// thay vì cộng 33 bit rồi mới so sánh. Hai cách tương đương vì đã dùng luôn <= MAX_POS.
module pretrade_risk #(
    parameter [31:0] MAX_QTY      = 32'd1000,
    parameter [31:0] MIN_PX       = 32'd1,
    parameter [31:0] MAX_PX       = 32'd4095,
    parameter [63:0] MAX_NOTIONAL = 64'd1000000,
    parameter [31:0] MAX_POS      = 32'd100000,
    parameter [31:0] RATE_MAX     = 32'hFFFFFFFF,
    parameter [31:0] RATE_WINDOW  = 32'd1000
) (
    input  wire        clk,
    input  wire        rst,
    input  wire        kill,
    input  wire        in_valid,
    input  wire        in_buy,
    input  wire [31:0] in_qty,
    input  wire [31:0] in_price,
    input  wire [1:0]  in_sym,
    output reg         out_valid,
    output reg         out_buy,
    output reg  [31:0] out_qty,
    output reg  [31:0] out_price,
    output reg  [1:0]  out_sym,
    output reg         rej_valid,
    output reg  [3:0]  rej_reason
);
    localparam [3:0] R_NONE = 4'd0, R_KILL = 4'd1, R_QTY = 4'd2, R_PRICE = 4'd3, R_NOTIONAL = 4'd4,
                     R_EXPOSURE = 4'd5, R_RATE = 4'd6;

    // ---- tầng 0: bốn tích riêng 16x16 (mỗi tích vừa một khối nhân phần cứng) + các kiểm tra qty / dải giá ----
    reg         s0_valid, s0_buy, s0_bad_qty, s0_bad_price;
    reg  [31:0] s0_qty, s0_price;
    reg  [1:0]  s0_sym;
    reg  [31:0] p_ll, p_lh, p_hl, p_hh;

    always @(posedge clk) begin
        s0_valid     <= in_valid && !rst;
        s0_buy       <= in_buy;
        s0_qty       <= in_qty;
        s0_price     <= in_price;
        s0_sym       <= in_sym;
        p_ll         <= in_price[15:0]  * in_qty[15:0];
        p_lh         <= in_price[15:0]  * in_qty[31:16];
        p_hl         <= in_price[31:16] * in_qty[15:0];
        p_hh         <= in_price[31:16] * in_qty[31:16];
        s0_bad_qty   <= (in_qty == 32'd0) || (in_qty > MAX_QTY);
        s0_bad_price <= (in_price < MIN_PX) || (in_price > MAX_PX);
    end

    // ---- tầng 1: cộng các tích riêng thành giá trị lệnh 64 bit ----
    reg         s1_valid, s1_buy, s1_bad_qty, s1_bad_price;
    reg  [31:0] s1_qty, s1_price;
    reg  [1:0]  s1_sym;
    reg  [63:0] s1_notional;

    always @(posedge clk) begin
        s1_valid     <= s0_valid && !rst;
        s1_buy       <= s0_buy;
        s1_qty       <= s0_qty;
        s1_price     <= s0_price;
        s1_sym       <= s0_sym;
        s1_bad_qty   <= s0_bad_qty;
        s1_bad_price <= s0_bad_price;
        s1_notional  <= {p_hh, 32'd0} + {16'd0, p_lh, 16'd0} + {16'd0, p_hl, 16'd0} + {32'd0, p_ll};
    end

    // ---- tầng 2 ----
    reg [31:0] buy_room, sell_room;   // hạn mức còn lại mỗi bên
    reg [31:0] win_cnt, sent;         // vị trí trong cửa sổ, số lệnh đã phát trong cửa sổ

    wire        win_end      = (win_cnt == RATE_WINDOW - 32'd1);
    wire        bad_notional = (s1_notional > MAX_NOTIONAL);
    wire [31:0] room         = s1_buy ? buy_room : sell_room;
    wire        bad_exposure = (s1_qty > room);
    wire        bad_rate     = (sent >= RATE_MAX);
    wire [3:0]  reason = kill         ? R_KILL     :
                         s1_bad_qty   ? R_QTY      :
                         s1_bad_price ? R_PRICE    :
                         bad_notional ? R_NOTIONAL :
                         bad_exposure ? R_EXPOSURE :
                         bad_rate     ? R_RATE     : R_NONE;
    wire [31:0] room_after = room - s1_qty;   // tính song song với việc chọn lý do, chỉ dùng nếu lệnh qua

    always @(posedge clk) begin
        out_valid <= 1'b0;
        rej_valid <= 1'b0;
        if (rst) begin
            buy_room <= MAX_POS; sell_room <= MAX_POS; win_cnt <= 32'd0; sent <= 32'd0;
        end else begin
            if (win_end) begin win_cnt <= 32'd0; sent <= 32'd0; end
            else         win_cnt <= win_cnt + 32'd1;

            if (s1_valid) begin
                if (reason == R_NONE) begin
                    out_valid <= 1'b1;
                    out_buy   <= s1_buy;
                    out_qty   <= s1_qty;
                    out_price <= s1_price;
                    out_sym   <= s1_sym;
                    if (s1_buy) buy_room  <= room_after;
                    else        sell_room <= room_after;
                    sent <= win_end ? 32'd1 : sent + 32'd1;
                end else begin
                    rej_valid  <= 1'b1;
                    rej_reason <= reason;
                end
            end
        end
    end
endmodule
