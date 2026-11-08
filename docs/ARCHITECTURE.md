# Kiến trúc và bài học

Tài liệu này tóm tắt những gì dự án đã xây, đo được gì, khác hệ thống thật ở đâu, và học được gì. Số liệu lấy từ các bài
mô phỏng trong repo (`python run_all_tests.py`); mỗi con số đều truy ngược được tới một bài test.

## 1. Bức tranh tổng thể

```
 PHÍA SÀN (C++, server/)                                       PHÍA CÔNG TY GIAO DỊCH (Verilog, rtl/)
 ┌───────────────────────────────────────────┐
 │ Gateway ─ Risk ─ OMS ─ Matching/Order Book │ ──UDP multicast──►  khung Ethernet
 │   ▲   JSON/TCP    ▲ OUCH/TCP               │   (market data,           │ 8 byte/chu kỳ
 │   │               │                        │    ITCH, có seq)          ▼
 └───┼───────────────┼────────────────────────┘                  ┌─────────────────┐
     │               └──────────────────────────────────────────  │ parser64        │ Ethernet/VLAN/IPv4/UDP + MoldUDP64 + ITCH
  Client Python (shell, bot, dashboard, OuchClient)               └────────┬────────┘
                                                                           │ message A/E/D (≤ 1/chu kỳ)
                                                                  ┌────────▼────────┐
                                                                  │ FIFO + order    │ bảng băm lệnh + bảng mức giá + bitmap
                                                                  │ book (itch_book)│
                                                                  └────────┬────────┘
                                                                           │ giá tốt nhất của mã vừa đổi
                                                                  ┌────────▼────────┐
                                                                  │ chiến lược      │ ngưỡng, 1 chu kỳ
                                                                  └────────┬────────┘
                                                                  ┌────────▼────────┐
                                                                  │ pre-trade risk  │ 6 phép kiểm tra song song
                                                                  └────────┬────────┘
                                                                  ┌────────▼────────┐
                                                                  │ FIFO lệnh +     │ khuôn cố định, gói OUCH 'U'
                                                                  │ ouch_encoder    │
                                                                  └────────┬────────┘
                                                                           ▼ byte lệnh ra (tầng TCP/MAC chưa làm)
```

Hai nửa của thị trường: sàn (khớp lệnh, phát market data) và công ty giao dịch (nghe market data, quyết định, gửi lệnh). Phần C++
mô phỏng sàn và là nguồn dữ liệu thật cho phần Verilog; phần Verilog là phía công ty giao dịch, nơi FPGA thực sự được dùng trong HFT.

## 2. Mỗi khối làm gì, và kiểm chứng ra sao

| Khối | Vai trò | Kiểm chứng (golden độc lập) |
|---|---|---|
| `eth_udp_itch_parser` | 1 byte/chu kỳ: Ethernet/IPv4/UDP + ITCH, cờ gap theo `seq` | 22 sự kiện từ gói UDP thật của server C++ |
| `eth_udp_itch_parser64` | 8 byte/chu kỳ, VLAN, nhiều message/gói (MoldUDP64) | 20.147 sự kiện từng cái một; 1.000.000 message so băm |
| `itch_book` | dựng lại sổ lệnh từ A/E/D | 100.009 message, sau MỖI message so giá tốt nhất, cuối cùng quét toàn bảng |
| `pretrade_risk` | kill, qty, dải giá, giá trị lệnh, exposure, tốc độ | 24 tình huống kịch bản (đột biến ở biên bị bắt) |
| `strategy_threshold` | mua khi ask thấp / bán khi bid cao (chỉ để chứng minh đường đi) | qua `tick_to_trade` |
| `ouch_encoder` | điền khuôn gói OUCH | 4.000 gói, 126.000 byte khớp Python từng byte |
| `tick_to_trade` | ghép các khối trên | 288 lệnh khớp từng byte, số lần risk loại khớp tuyệt đối |

Quy trình kiểm chứng áp dụng cho mọi khối: (1) viết golden bằng Python/C++ độc lập với Verilog, (2) sinh vector ngẫu nhiên có chủ đích
gây khó (xung đột băm, lỗi giữa gói, rơi/trùng gói), (3) so từng sự kiện hoặc băm, (4) **cố ý làm hỏng thiết kế và xác nhận
testbench bắt được lỗi**. Bước 4 hai lần phát hiện lint của Verilator chặn đột biến *trước* khi tới testbench, nên phải viết lại đột
biến để thực sự thử testbench.

## 3. Độ trễ từng khối (chu kỳ mô phỏng, đơn vị 4 ns ở 250 MHz chỉ để hình dung)

| Đoạn | Chu kỳ | Nguồn số đo |
|---|---|---|
| Parser 1 byte: ra message sau byte cuối của nó | 1 (thanh ghi đầu ra) | `tb_parser` |
| FIFO vào + cấp phát sang book | 2 | cấu trúc |
| Book: thêm lệnh (`A`) | trung bình 7, tệ nhất 111 | `tb_book`, 100.000 message |
| Book: khớp (`E`) / huỷ (`D`) | trung bình 8, tệ nhất 108 / 97 | `tb_book` |
| Book: tra order id KHÔNG tồn tại | 40–45 (sau khi dọn tombstone; trước là 2050) | `tb_book` |
| Chiến lược | 1 | cấu trúc |
| Risk (3 tầng pipeline, xem mục 7) | 3 | `tb_risk` |
| FIFO lệnh + cấp phát cho bộ mã hoá | 2 | cấu trúc |
| Bộ mã hoá: byte đầu của gói ra | 2 (cả gói 36 byte mất 36 chu kỳ ở 1 byte/chu kỳ) | `tb_ouch` |
| **Tick-to-trade cả chuỗi** | **nhỏ nhất 13, trung bình 17, lớn nhất 48** (trước khi chia pipeline cho risk: 11 / 15 / 46) | `tb_t2t`, 288 lệnh |

Tham chiếu: đường JSON/TCP trên C++ ở giai đoạn 1 là khoảng 90 µs (p50) vòng đi về. Chênh lệch ~3 bậc độ lớn đến từ việc bỏ hệ điều hành,
bỏ JSON, và xử lý song song trong phần cứng. Nhưng **con số mô phỏng chưa gồm MAC/PHY, TCP/IP, tuần tự hoá phần còn lại của gói ra**.

## 4. Khác gì so với hệ thống thật (để không hiểu nhầm đây là chuẩn công nghiệp)

| Dự án này | Hệ thống thật |
|---|---|
| Bảng băm địa chỉ mở cho order id; thời gian tra không xác định | Bảng tra trực tiếp (sàn cấp id dày đặc), CAM, hoặc băm nhiều bậc có giới hạn chuỗi: độ trễ dự đoán được |
| Một message mỗi lần bằng FSM nhiều chu kỳ | Pipeline sâu, xử lý nhiều message song song, giải hazard cùng mức giá |
| Bảng nhớ đọc ĐỒNG BỘ, mỗi bảng 1 cổng đọc + 1 cổng ghi (đã viết lại; bản bất đồng bộ cũ tốn 23.941 LUT + 17.516 LUTRAM, nay 1.776 LUT, 0 LUTRAM) | Giống: BRAM thật cũng vậy. Khác: thật dùng pipeline nhiều message song song và giải hazard; ta xử lý một message mỗi lần |
| Giá cửa sổ cố định 1..4095 | Giá gốc + offset quanh giá thị trường, nhiều tick size |
| Parser mở vòng 8 byte nối tiếp trong một chu kỳ | Đường tổ hợp dài; thực tế tách pha, dùng mảng song song hoặc xác định trước vị trí trường |
| Không có MAC/PHY, TCP, đồng bộ đồng hồ PTP, timestamp phần cứng | Toàn bộ nằm trong FPGA hoặc card mạng kernel-bypass |
| Chiến lược ngưỡng đơn giản | Logic phức tạp ở CPU, FPGA chỉ giữ phần chạy 1 chu kỳ |
| Risk không nhận phản hồi khớp lệnh (exposure chỉ tăng) | Vòng phản hồi từ execution report, vị thế thực |
| Số liệu độ trễ là chu kỳ mô phỏng | Đo bằng timestamp phần cứng ở cổng vào/ra, p99/p99.9 trên lưu lượng thật |

## 5. Bài học (những thứ chỉ thấy khi tự làm)

1. **Độ trễ trung bình đánh lừa; đuôi mới quyết định.** Bảng băm cho trung bình 7–8 chu kỳ nhưng tệ nhất hơn 100, và khi tra một khoá
   không tồn tại thì 2050 chu kỳ. Hệ thống HFT cần *giới hạn trên*, không cần trung bình đẹp.
2. **Tombstone là món nợ ẩn.** Xoá bằng tombstone rồi thêm/xoá liên tục làm bảng cạn ô rỗng; chỉ lộ ra khi đo trường hợp *không tìm thấy*.
3. **Backpressure không tồn tại ở đầu vào MAC.** Dòng dữ liệu không dừng được; khi phía sau chậm chỉ có FIFO đủ sâu + cờ tràn.
   Đo mức đầy cao nhất (`fifo_max_level`) để chọn độ sâu thay vì đoán.
4. **Giao thức độ dài cố định, big-endian là món quà cho phần cứng.** Cùng thông điệp, JSON cần dò ký tự và tách chuỗi; ITCH/OUCH cắt bit
   ở offset cố định. Đó là lý do toàn bộ đường nóng dùng nhị phân.
5. **Tách nghiệp vụ khỏi mạng giúp test.** `ExchangeCore` không biết socket nên unit test chạy không cần mạng; đây cũng là cách chia
   phần mềm/phần cứng: lõi xác định ở FPGA, phiên và cấu hình ở CPU.
6. **"Không mất, không trùng" cần CẢ HAI chiều.** Số thứ tự + phát lại cho báo cáo từ sàn; token duy nhất cho lệnh gửi lên. Thiếu một
   trong hai là có lỗi, và test bỏ từng cơ chế một đều bắt được.
7. **Công cụ có lỗi.** Phải vòng qua lỗi thư mục tạm của `make`/`yosys` trên Windows, lỗi link của g++ 16.1 với `-Os`; ghi lại trong
   `rtl/run_sim.py` để người sau không phải mò lại.
8. **Đột biến kiểm thử đáng giá hơn độ phủ.** Test "PASS" chỉ có ý nghĩa khi biết nó FAIL khi thiết kế sai.

## 6. Câu hỏi ôn phỏng vấn (tự trả lời được từ chính repo)

- Vì sao parser 64 bit giữ tối đa một message mỗi chu kỳ? (record ≥ 11 byte > 8)
- Vì sao `S_CLEAN` đúng? Bất biến nào của linear probing được giữ? (ô có ô kế tiếp rỗng có thể thành rỗng)
- Khi book chậm hơn tốc độ đến thì chuyện gì xảy ra, bạn phát hiện bằng cách nào, và hậu quả sau khi tràn?
- Risk nằm "trên đường găng" nghĩa là gì? Vì sao 6 phép kiểm tra tính song song chứ không tuần tự?
- Token và số thứ tự giải quyết hai vấn đề khác nhau như thế nào?
- Vì sao viết lại book cho BRAM lại không làm tăng số chu kỳ mỗi message? (địa chỉ đọc tổ hợp, phát lệnh đọc sớm)
- Vì sao BRAM đọc đồng bộ buộc phải đăng ký kết quả mã hoá ưu tiên trước khi làm địa chỉ? (đường găng: clk-to-out + mã hoá + địa chỉ)
- Vì sao chia pipeline cho risk lại làm tick-to-trade chậm thêm 2 chu kỳ mà vẫn có lợi? (Fmax 48 -> 112 MHz)
- `ltp` của Yosys nói đường găng của risk dài hơn sau khi sửa, nhưng nextpnr nói nhanh hơn. Tin cái nào, vì sao?

## 7. Tài nguyên, Fmax và sửa đường găng (giai đoạn 6)

Công cụ: Yosys (tổng hợp, đích Xilinx 7-series) và nextpnr-ecp5 (đặt-và-đi-dây trên LFE5U-85F). **Không phải Vivado/Quartus, không phải linh kiện
HFT thật.** ECP5 chậm hơn nhiều, nên Fmax chỉ nên đọc để SO SÁNH (trước/sau, khối này với khối kia). Chạy lại: `python rtl/synth.py [--par] [khối ...]`.

| khối | LUT | FF | BRAM | LUTRAM | DSP48 | Fmax sau định tuyến (ECP5) |
|---|---|---|---|---|---|---|
| parser 1 byte | 632 | 564 | 0 | 0 | 0 | 77,7 MHz (trước khi sửa: 58,2) |
| pretrade_risk | 284 | 404 | 0 | 0 | 4 | 112,3 MHz (trước khi sửa: 48,1) |
| strategy_threshold | 34 | 14 | 0 | 0 | 0 | 192,5 MHz |
| ouch_encoder | 266 | 262 | 0 | 0 | 0 | 140,3 MHz |
| FIFO 64 x 208 bit | 44 | 28 | 0 | 70 | 0 | (chưa đo) |
| itch_book (bản đọc đồng bộ, hợp BRAM) | 1.776 | 1.134 | 40 RAMB36 | 0 | 0 | 44,2 MHz (sau 3 lần sửa đường găng: 33,3 -> 37,2 -> 41,8 -> 44,2) |
| itch_book_async (bản cũ, đọc bất đồng bộ) | 23.941 | 294 | 9 | 17.516 | 0 | không xong trong 25 phút |
| parser 64 bit | Yosys không xong sau 45 phút | | | | | (chưa đo) |

**Cách tìm và sửa đường găng** (vòng lặp này mới là kỹ năng cần có):
1. `nextpnr` in đường găng: nó chỉ ra tín hiệu nguồn, các ô đi qua, và tỉ lệ logic/dây (vd 7,5 ns logic + 5,8 ns dây).
2. `pretrade_risk` ban đầu 48 MHz: đường qua bộ cộng 33 bit `exp_next` (chuỗi carry) rồi so sánh rồi chọn lý do rồi vào chân CE của thanh ghi ra.
   Sửa: lưu "hạn mức còn lại" (`qty > room`, một phép so sánh), tách thành tầng, rồi xử lý tiếp bộ nhân 32x32 bằng 4 tích riêng 16x16.
   48,1 -> 75,2 -> 112,3 MHz; mỗi bước thêm một chu kỳ độ trễ. **Đó là đánh đổi cốt lõi: pipeline sâu hơn cho Fmax cao hơn nhưng tick-to-trade tính
   bằng chu kỳ dài hơn.** Phép tính đúng là so tổng thời gian: 17 chu kỳ ở 112 MHz (~152 ns) so với 15 chu kỳ ở 48 MHz (~313 ns).
3. `parser` 1 byte: đường từ `in_data` qua tra loại message qua `udp_len + 16` qua so sánh. Sửa: tính sẵn `udp_len + 20` và `udp_len - 16` khi `udp_len` được biết, dời kiểm
   tra checksum/IP đích từ byte 33 sang byte 35 để dùng giá trị đã nằm trong thanh ghi. 58,2 -> 77,7 MHz.
4. Sau mỗi lần sửa chạy lại toàn bộ test và một đột biến biên; hai lần đầu lint của Verilator chặn đột biến trước khi tới testbench nên phải viết lại đột biến.

**Ba phát hiện ảnh hưởng thiết kế:**
1. **Bản `itch_book` đầu tiên KHÔNG hợp BRAM, đã viết lại.** Các bảng đọc bất đồng bộ từ nhiều cổng nên Yosys trải ra 17.516 ô RAM phân tán và 23.941 LUT chỉ cho MỘT
   order book (một Artix-7 100T chỉ có ~63.000 LUT). Bản mới đọc đồng bộ, mỗi bảng 1 cổng đọc + 1 cổng ghi, giữ best bid/ask trong thanh ghi và cập nhật khi ghi:
   1.776 LUT, 0 LUTRAM, 40 RAMB36. Quy tắc đáng nhớ: *địa chỉ đọc là hàm tổ hợp của trạng thái hiện tại*, nhờ đó một quyết định phát ngay lệnh đọc kế tiếp và số chu kỳ
   mỗi message gần như không đổi (cái giá đọc đồng bộ được bù). Cũng nhờ vậy test cũ vẫn khớp golden mà không cần đổi nội dung.
2. `parser64` đúng chức năng và vượt 1.000.000 message, nhưng cách mô tả (8 byte nối tiếp bằng gán blocking trong một khối) khiến Yosys treo ở bước tối ưu cây mux. Đúng chức
   năng không đủ: mô tả phải hợp công cụ tổng hợp.
3. Số liệu tổng hợp không thay thế được số liệu đặt-và-đi-dây: cột "mức logic" (`ltp`) tăng khi Fmax thật tăng.

