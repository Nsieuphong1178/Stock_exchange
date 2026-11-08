# Lộ trình phát triển

Mục tiêu cuối: có một **hệ thống mẫu tick-to-trade** chạy được trong mô phỏng (và tổng hợp được), kèm bộ kiểm chứng,
để vừa học vừa làm hồ sơ cho vị trí FPGA engineer trong ultra low latency trading.

**Giả định (sửa lại nếu khác):** ~10 giờ/tuần, bắt đầu 8/11/2026, tổng 16 tuần (hết 27/2/2027).
Nếu làm ít giờ hơn thì kéo dài mỗi giai đoạn theo tỉ lệ; thứ tự giữ nguyên.
Mỗi giai đoạn có **tiêu chí hoàn thành kiểm chứng được**: chưa đạt thì chưa sang giai đoạn sau.

## Đã xong (giai đoạn 0)

| Hạng mục | Bằng chứng |
|---|---|
| Sàn mini C++: Gateway, Risk, OMS, Matching, Order Book, Logger | `build/test_core.exe` qua |
| TCP/JSON + client Python (shell, bot, dashboard), xử lý client chậm | `python -m unittest discover tests` |
| Market data nhị phân kiểu ITCH qua UDP multicast, có `seq` | `test_udp_feed_rebuilds_same_book_as_tcp` |
| RTL: parse Ethernet/IP/UDP + decode ITCH, 1 byte/chu kỳ | `python rtl/run_sim.py` PASS |
| **Giai đoạn 1** (gap `seq`, snapshot, heartbeat, đo độ trễ, `run_all_tests.py`) | xem Nhật ký, 8/11/2026 |
| **Giai đoạn 2** (order book RTL, parser → FIFO → book) | xem Nhật ký |
| **Giai đoạn 3** (đặt lệnh nhị phân kiểu OUCH, phát lại, chống trùng, bộ mã hoá RTL) | xem Nhật ký |
| **Giai đoạn 4** (tick-to-trade: chiến lược, risk, mã hoá; đo độ trễ) | xem Nhật ký |
| **Giai đoạn 5** (datapath 64 bit, VLAN, nhiều message/gói, line rate, 1 triệu message) | xem Nhật ký |
| **Giai đoạn 6** (tổng hợp, Fmax, sửa đường găng, tài liệu) | `rtl/synth.py`, `docs/ARCHITECTURE.md`; làm được bằng công cụ mã nguồn mở, chưa có Vivado/Quartus |

## Tổng quan

```
Tuần  1  2 | 3  4  5 | 6  7 | 8  9 | 10 11 12 | 13 14 15 16
      [GĐ1 ] [ GĐ2   ] [GĐ3 ] [GĐ4 ] [  GĐ5   ] [   GĐ6    ]
      Nền    Order     Đặt   Tick-   Datapath   Tổng hợp
      tảng   book RTL lệnh   to-trade rộng      + hoàn thiện
```

## Giai đoạn 1 – Củng cố nền tảng và đo đạc (tuần 1–2: 8/11 – 21/11)

Mục tiêu: có số đo và bộ test đáng tin trước khi thêm thứ mới.

- Phát hiện mất gói `seq` ngay trong RTL (cờ `gap`), đo bằng cách cố ý bỏ gói trong vector.
- Khôi phục khi mất gói: client lấy snapshot qua TCP rồi áp lại feed từ `seq` kế tiếp (phía Python).
- Heartbeat và phát hiện kết nối chết cho kênh TCP; đo độ trễ vòng đi về (RTT) của sàn C++ bằng timestamp.
- Một lệnh chạy tất cả test (C++, Python, RTL), ví dụ `python run_all_tests.py`.

**Hoàn thành khi:** bỏ gói ngẫu nhiên thì RTL và Python đều báo đúng chỗ mất; có bảng độ trễ p50/p99 của đường JSON/TCP;
một lệnh chạy hết test và trả mã thoát 0.

## Giai đoạn 2 – Order book bằng RTL (tuần 3–5: 22/11 – 12/12)

Mục tiêu: dựng lại sổ lệnh từ message `A/E/D` trong phần cứng (phía công ty giao dịch, không phải engine khớp lệnh).

- Tuần 3: thiết kế trên giấy (mảng theo giá + bitmap hai tầng + danh sách liên kết trong "BRAM", bể lệnh và free list); viết mô hình tham chiếu Python có cùng cấu trúc.
- Tuần 4: RTL một phía (bán), một mã, ít mức giá (256); FSM đơn giản, chưa pipeline.
- Tuần 5: thêm phía mua, nhiều mã, xử lý `E` làm giảm qty và `D` xoá lệnh; xuất best bid/ask và độ sâu.

**Hoàn thành khi:** ghép sau bộ parse, sổ lệnh RTL **giống hệt** `feed_receiver.py` sau 100.000 message ngẫu nhiên
(kể cả lệnh huỷ và khớp một phần); in được số chu kỳ trung bình và tệ nhất cho mỗi loại message.

## Giai đoạn 3 – Đặt lệnh bằng giao thức nhị phân (tuần 6–7: 13/12 – 26/12)

Mục tiêu: thay JSON bằng giao thức đặt lệnh kiểu OUCH, có phiên (session) đáng tin.

- Tuần 6: định nghĩa message OUCH rút gọn (Enter Order, Accepted, Executed, Cancel); gateway C++ hiểu giao thức này song song với JSON; khung phiên có số thứ tự và heartbeat (kiểu SoupBinTCP).
- Tuần 7: RTL bộ **mã hoá lệnh** (điền khuôn cố định) và test khớp với encoder Python.

**Hoàn thành khi:** client Python đặt lệnh bằng nhị phân, nhận execution report; cắt kết nối giữa chừng rồi nối lại thì
không mất và không trùng lệnh (nhờ số thứ tự); bộ mã hoá RTL cho ra đúng từng byte so với golden.

## Giai đoạn 4 – Tick-to-trade trong mô phỏng (tuần 8–9: 27/12 – 9/1)

Mục tiêu: chuỗi đầy đủ parser → order book → chiến lược → risk → mã hoá lệnh.

- Chiến lược đơn giản, xác định (ví dụ: mua khi best ask thấp hơn ngưỡng; hoặc market making hai phía quanh giá giữa).
- Risk trong RTL: giới hạn số lượng, giá, vị thế tối đa, tốc độ đặt lệnh; số dư trong "BRAM".
- Ghép thành một module top; đo **số chu kỳ từ byte đầu của gói market data tới byte đầu của lệnh ra**.

**Hoàn thành khi:** cho phát lại một chuỗi market data có điều kiện kích hoạt, top module phát đúng lệnh (đúng bytes) và chặn
đúng các lệnh vi phạm risk; báo cáo độ trễ tick-to-trade theo chu kỳ, quy ra ns ở tần số giả định.

## Giai đoạn 5 – Datapath rộng và thực tế hơn (tuần 10–12: 10/1 – 30/1)

Mục tiêu: gần với 10G Ethernet thật.

- Parser nhận **64 bit/chu kỳ** (trường vắt qua ranh giới từ, `keep`/`last` theo AXI-Stream); hỗ trợ VLAN tag.
- Hỗ trợ IP options hoặc loại khung có chủ đích; gom nhiều message trong một gói (kiểu MoldUDP64).
- Cho phép ép chu kỳ rảnh và `backpressure` ở các khối phía sau; kiểm tra không mất dữ liệu.
- Tìm và sửa điểm nghẽn thông lượng đã đo ở giai đoạn 4 (pipeline, giải hazard cùng mức giá).

**Hoàn thành khi:** cùng bộ golden (cập nhật cho nhiều message mỗi gói) PASS với datapath 64 bit; thông lượng đo được
không dưới tốc độ đường truyền giả định; test ngẫu nhiên dài (≥ 1 triệu message) không lệch.

## Giai đoạn 6 – Tổng hợp và hoàn thiện (tuần 13–16: 31/1 – 27/2)

Mục tiêu: chứng minh thiết kế tổng hợp được và đóng gói thành sản phẩm trình bày được.

- Cài **Vivado (WebPACK)** hoặc **Quartus Lite**; tổng hợp top module cho một linh kiện cụ thể; ghi LUT/FF/BRAM và **Fmax**; sửa đường găng (đây cũng là cách học thực tế nhất).
- Thêm ràng buộc thời gian (`xdc`/`sdc`) và báo cáo timing.
- Tuỳ chọn nếu có board: đưa MAC/PCS thật vào, hoặc thử loopback với IP của hãng.
- Tài liệu: sơ đồ kiến trúc, bảng độ trễ từng khối, những gì khác với hệ thống thật, bài học.
- Ôn tập phỏng vấn: tự giải thích được từng quyết định thiết kế (vì sao bitmap, vì sao không backpressure ở đường vào, hazard...).
- Dự phòng: dịp Tết (đầu tháng 2/2027) rơi vào giai đoạn này, nên dự trù chậm tuần nào thì tuần đó dồn vào mục tuỳ chọn.

**Hoàn thành khi:** có báo cáo tổng hợp với Fmax và tài nguyên; số chu kỳ tick-to-trade × chu kỳ đồng hồ thật ra ns cụ thể;
README dự án đủ để người khác dựng lại từ đầu.

## Tuỳ chọn (làm nếu còn thời gian, không chặn tiến độ)

- Engine khớp lệnh bằng RTL (phía sàn) với cùng golden C++, để so sánh hai phía của thị trường.
- TCP stack tối giản trong RTL cho đường đặt lệnh.
- Timestamp phần cứng và mô phỏng đồng bộ PTP.
- So sánh với kernel bypass (DPDK/Onload) trên Linux nếu có máy phù hợp.
- Giao thức FIX song song với JSON và OUCH để hiểu khác biệt.

## Rủi ro và cách giảm

| Rủi ro | Cách giảm |
|---|---|
| Không có Vivado/Quartus nên đến cuối mới biết thiết kế không tổng hợp được | Cài công cụ sớm (cuối giai đoạn 2), thử tổng hợp parser hiện có để biết Fmax/tài nguyên làm mốc |
| Order book RTL lệch golden mà khó tìm nguyên nhân | Test ngẫu nhiên theo từng message, so sánh sau mỗi message thay vì chỉ cuối chuỗi; giữ mô hình tham chiếu cùng cấu trúc |
| Mô phỏng tốt nhưng quá chậm khi chạy 1 triệu message | Verilator đã đủ nhanh; tránh log từng chu kỳ |
| Tốn thời gian vào toolchain Windows | Cân nhắc WSL2 hoặc Linux cho phần RTL nếu lỗi môi trường lặp lại |
| Làm lan man | Mỗi giai đoạn có tiêu chí hoàn thành; mục tuỳ chọn không được chen vào trước khi đạt |

## Cách theo dõi

Mỗi cuối tuần ghi 3 dòng vào cuối file này: **đã làm**, **đang vướng**, **tuần sau**. Khi một giai đoạn đạt tiêu chí, ghi
ngày và con số đo được (độ trễ, số chu kỳ, Fmax...). Số liệu đo là thứ giá trị nhất khi kể lại dự án.

## Nhật ký

### Giai đoạn 1 – hoàn thành 8/11/2026 (đạt cả ba tiêu chí)

- **Gap trong RTL:** `msg_gap` trong `eth_udp_itch_parser.v`. Vector kiểm thử cố ý rơi 3 gói và gửi trùng 1 gói
  => 3 lần gap, khớp golden; đột biến "bỏ qua gói trùng" bị testbench bắt.
- **Khôi phục:** server có lệnh `snapshot` (mọi lệnh đang chờ + `seq` feed cuối); `FeedReceiver(snapshot_fn=...)` tự thay sổ
  bằng snapshot và bỏ qua gói có `seq` ≤ snapshot. Test e2e: rơi gói giữa chừng, sổ cuối cùng giống sổ server.
- **Heartbeat:** server ngắt client im lặng quá `idle` giây (mặc định 10, tham số thứ 2 của `exchange_server`); client tự
  `ping` mỗi giây và tự coi sàn là chết nếu im lặng quá 3 chu kỳ + 1 giây (`client.alive`).
- **Một lệnh chạy hết test:** `python run_all_tests.py` (build C++, unit C++, test Python, mô phỏng RTL) => 4/4 PASS.
- **Độ trễ JSON/TCP** (`python client/latency.py`, 2000 lần, Windows, loopback, µs, vòng đi về một yêu cầu một lúc):

  | | client p50 | p99 | server xử lý p50 | p99 |
  |---|---|---|---|---|
  | ping (chỉ qua gateway) | 58 | 105 | - | - |
  | lệnh nằm chờ, có log | 89 | 201 | 60 | 145 |
  | lệnh nằm chờ, tắt log (`-DLOGGER_DISABLE`) | 63 | 122 | 34 | 65 |
  | lệnh khớp (có log / tắt log) | 156 / 137 | 309 / 216 | - | - |

  Đọc số: ~58 µs là "sàn" của Python + loopback + Windows (ping). **Logger đồng bộ (flush mỗi dòng) tốn ~26 µs, hơn
  nửa thời gian xử lý của server.** Phần còn lại ~34 µs gồm dựng JSON và `send()` cho mỗi execution report, và
  `md_book` được dựng cho mọi sự kiện kể cả khi không ai subscribe. Chưa tối ưu gì (giai đoạn này chỉ đo).
  So với hàng chục đến hàng trăm ns của FPGA, đây là chênh lệch ~3 bậc độ lớn.
- Lưu ý khi đo: số đo gồm cả thread/GIL của Python nên nhiễu; chỉ dùng để so sánh tương đối và làm mốc.

### Giai đoạn 2 – hoàn thành 8/11/2026 (đạt tiêu chí; có điều chỉnh thiết kế so với kế hoạch)

- **RTL:** `rtl/itch_book.v` (order book), `rtl/itch_pipeline.v` (parser → FIFO 8 phần tử → book). 3 mã, giá cửa sổ 1..4095,
  bảng lệnh 2048 ô, xử lý một message mỗi lần bằng FSM (INIT / IDLE / ADD / LOOKUP / APPLY / DONE).
- **Kiểm chứng:**
  - `book`: 100.009 message ngẫu nhiên đưa thẳng vào book. Sau MỖI message so giá/qty mua và bán tốt nhất với golden;
    cuối cùng quét toàn bộ bảng 24.576 mức giá. 8 message lỗi cố ý (lệnh không tồn tại, giá ngoài cửa sổ, mã lạ, khớp
    quá số lượng...) phải báo đúng mã lỗi và không làm đổi sổ.
  - `pipeline`: cùng 100.009 message bọc thành khung Ethernet, xen 1.000 khung lỗi (sai checksum/cổng/IP đích/giao thức):
    khớp golden, khung lỗi bị loại hết, FIFO không tràn. Thu FIFO xuống 2 phần tử thì mất 6 message và cờ tràn bật đúng.
  - Đột biến đã thử và bị testbench bắt: xoá bằng ô rỗng thay vì tombstone (gãy chuỗi thăm dò), không xoá bit tầng trên của bitmap.
- **Số chu kỳ xử lý** (từ lúc book nhận message tới `done`, 100.000 message, 30% ID cố ý dồn vào 16 ô băm):

  | | trung bình | tệ nhất |
  |---|---|---|
  | A (thêm lệnh) | 8 | 112 |
  | E (khớp) | 9 | 109 |
  | D (huỷ) | 9 | 98 |

  Ở 250 MHz: trung bình ~32–36 ns, tệ nhất ~450 ns. **Đây là điểm yếu cần nhớ:** thời gian xử lý của bảng băm *không xác
  định* (phụ thuộc độ dài chuỗi thăm dò). HFT cần độ trễ dự đoán được; thiết kế thật thường dùng bảng tra trực tiếp
  (sàn cấp order id dày đặc), CAM, hoặc băm nhiều bậc có giới hạn chuỗi. Giá trị trung bình thấp vì bình thường ID ít xung đột.
- **Khác kế hoạch ban đầu (và lý do):**
  - Không có FIFO theo từng mức giá / danh sách liên kết: đó là việc của engine khớp lệnh *phía sàn*. Bộ dựng lại sổ
    phía công ty chỉ cần bảng lệnh + tổng qty mỗi mức giá, nên đơn giản hơn và vẫn đúng tiêu chí.
  - Không viết mô hình Python "cùng cấu trúc phần cứng" riêng: golden là `feed_receiver.BookBuilder` (dựng theo từng
    lệnh, rất khác cấu trúc RTL) nên độc lập hơn; bộ sinh vector còn tự đối chiếu hai cách tính sổ trước khi ghi file.
  - Độ sâu sổ lệnh đọc qua cổng debug (`dbg_addr`) thay vì cổng xuất riêng; giá tốt nhất đọc qua cổng truy vấn `q_sym`.
- **Chưa làm / giới hạn:** chưa pipeline (một message mỗi lần), giá cửa sổ cố định, tombstone không được dọn ngoài việc dùng
  lại khi thêm lệnh, chưa tổng hợp nên chưa biết Fmax và tài nguyên (bảng `lvl` 32K x 32 bit sẽ cần BRAM).

### Giai đoạn 3 – hoàn thành 8/11/2026 (đạt cả ba tiêu chí)

- **Giao thức** (`server/ouch.hpp`, `client/ouch.py`): khung kiểu SoupBinTCP `length[2] type[1] payload`; message OUCH rút gọn
  `O` Enter Order (33 byte), `X` Cancel (15 byte) từ client; `A` Accepted (40), `E` Executed (31), `C` Canceled (16),
  `J` Rejected (16) từ server. Gateway nhận diện JSON hay nhị phân theo byte đầu tiên nên hai giao thức chạy song song,
  dùng chung ExchangeCore; chuyển đổi nằm ở Gateway (execution report JSON -> message OUCH).
- **Không mất báo cáo:** mọi message server -> client có số thứ tự và được server lưu theo từng user (kể cả lúc user offline).
  Đăng nhập kèm `next_seq` thì server phát lại phần còn thiếu. Test: lệnh bị khớp khi client rớt mạng, nối lại nhận được
  `Executed` đúng số thứ tự 2.
- **Không trùng lệnh:** mỗi lệnh có token duy nhất, gửi lại cùng token thì server bỏ qua. Test: gửi lại R1 và R2 sau khi nối lại,
  mỗi token được chấp nhận đúng một lần, sổ lệnh không bị nhân đôi số lượng.
- **Heartbeat:** hai chiều (`H` mỗi giây); server ngắt client im lặng, client coi server chết sau 3 chu kỳ + 1 giây.
- **RTL:** `rtl/ouch_encoder.v` ghép gói từ các trường (khuôn cố định, 1 byte/chu kỳ: Enter 36 chu kỳ, Cancel 18 chu kỳ).
  4.000 gói ngẫu nhiên (token độ dài 1..14, giá trị biên 0 / 0xFFFFFFFF) khớp **từng byte** với `client/ouch.py`
  (tổng 126.000 byte); chạy được lệnh sát nhau. Đột biến đã thử và bị bắt: đổi chỗ trường price/symbol, sai độ dài Cancel.
  Phía server cũng có đột biến bị bắt: bỏ chống trùng token (lệnh nhân đôi), bỏ phát lại (mất báo cáo).
- **Giới hạn:** log phát lại không bao giờ được cắt (bộ nhớ tăng mãi), token không hết hạn, `session_id` đổi khi server
  khởi động lại nhưng khi đó trạng thái cũ mất hẳn (client chỉ biết qua `session_changed`). Đầu vào RTL là các trường đã
  tách sẵn: chưa có tầng TCP (số thứ tự, ACK, gửi lại) trong phần cứng; đó vẫn là khối khó nhất của đường gửi lệnh.

### Giai đoạn 4 – hoàn thành 8/11/2026 (đạt tiêu chí; tìm và sửa một khuyết điểm của order book)

- **Chuỗi** (`rtl/tick_to_trade.v`): khung Ethernet → parser → FIFO → order book → `strategy_threshold` → `pretrade_risk` →
  FIFO lệnh → `ouch_encoder` → byte của gói OUCH. Chiến lược mẫu: khi sổ của mã AAA đổi, nếu best ask ≤ 500 thì mua 10 ở
  giá đó, nếu best bid ≥ 3700 thì bán 10 ở giá đó (đủ để chứng minh đường đi; không phải chiến lược thật).
- **Risk** (`rtl/pretrade_risk.v`): 6 phép kiểm tra tính SONG SONG trong một chu kỳ (kill switch, qty, dải giá, giá trị
  lệnh, exposure theo bên, tốc độ lệnh theo cửa sổ). Có test kịch bản riêng `tb_risk.v` (24 tình huống, kết quả viết cứng) vì
  tốc độ lệnh phụ thuộc thời gian nên không so được với golden Python; đột biến `>` thành `>=` ở biên bị bắt.
- **Kiểm chứng toàn chuỗi** (`python rtl/run_sim.py t2t`): 100.009 message -> **288 lệnh phát ra khớp từng byte** với golden
  Python (gồm token tăng dần), và số lần risk loại theo từng lý do khớp tuyệt đối: PRICE 13.107, NOTIONAL 763,
  EXPOSURE 18.570 (QTY không có vì qty chiến lược cố định, đã phủ trong `tb_risk`). Không FIFO nào tràn.
- **Độ trễ tick-to-trade** (số chu kỳ từ chu kỳ mang byte cuối của message ITCH tới chu kỳ mang byte đầu của lệnh):

  | | chu kỳ | ở 250 MHz |
  |---|---|---|
  | nhỏ nhất | 12 | 48 ns |
  | trung bình | 16 | 64 ns |
  | lớn nhất | 47 | 188 ns |

  Phân bố 288 lệnh: ≤16 chu kỳ: 213, ≤24: 44, ≤32: 17, ≤48: 14. 12 chu kỳ là độ sâu cố định của đường ống (parser,
  FIFO vào/ra, book tối thiểu, chiến lược, risk, FIFO lệnh, bộ mã hoá); phần biến thiên đến từ book (độ dài chuỗi thăm dò
  của bảng băm). So với giai đoạn 1 (~90 µs cho đường JSON/TCP): chênh khoảng ba bậc độ lớn, nhưng **đây là chu kỳ mô phỏng**:
  chưa gồm MAC/PHY, TCP/IP, và 35 chu kỳ còn lại để phát nốt gói ở 1 byte/chu kỳ.
- **Khuyết điểm tìm được khi làm giai đoạn này:** testbench đầu tiên lệch đúng một lần loại, vì message cuối chưa xử lý
  xong khi testbench dừng. Nguyên nhân gốc: sau 100.000 lần thêm/xoá, bảng băm của order book *không còn ô rỗng nào*
  (toàn tombstone), nên tra một order_id **không tồn tại** phải quét cả bảng: **2050 chu kỳ** (~8 µs ở 250 MHz). Trong feed
  thật, message cho lệnh mình không theo dõi (mã khác, vào giữa phiên) là chuyện thường. Đã sửa: khi xoá một ô mà ô kế tiếp là
  rỗng thì ô đó thành rỗng và dọn ngược các tombstone liền trước (`S_CLEAN`). Kết quả: tra khoá không tồn tại còn **41–46
  chu kỳ**; vẫn khớp golden 100.000 message; đột biến "xoá thành rỗng bất chấp ô kế" bị bắt ngay ở message thứ 142. Thời gian
  tệ nhất của A/E/D (khoảng 100–112 chu kỳ) không đổi vì do cụm xung đột băm cố ý gây ra.
- **Giới hạn / việc còn lại:** book vẫn xử lý một message mỗi lần bằng FSM nhiều chu kỳ và là phần chiếm nhiều chu kỳ nhất
  trong đường tick-to-trade; thời gian của nó *không xác định* (phụ thuộc chuỗi thăm dò). Đó là mục tiêu của giai đoạn 5.
  Chưa có phản hồi khớp lệnh trở về risk (exposure chỉ tăng, không giảm); chưa có lọc theo mã trước bảng băm.

### Giai đoạn 5 – hoàn thành 8/11/2026 (đạt tiêu chí cho ID thực tế; còn giới hạn đã đo rõ với ca xấu)

- **Parser 64 bit** (`rtl/eth_udp_itch_parser64.v`): nhận 8 byte/chu kỳ (`in_keep` cho từ cuối), thẻ VLAN 802.1Q tuỳ chọn
  (mọi offset dịch +4), payload kiểu MoldUDP64 rút gọn `seq[8] | count[2] | { len[2] | message } x count`, `msg_gap` tính theo
  từng message. Cách làm: mở vòng ("unroll") bộ FSM từng byte của giai đoạn 1, chạy 8 lần nối tiếp trong một chu kỳ. Mỗi record
  dài ≥ 11 byte nên một từ chứa tối đa một message hoàn chỉnh: đầu ra vẫn ≤ 1 message/chu kỳ. Cái giá: đường tổ hợp dài gấp 8
  (Fmax sẽ thấp hơn bản 1 byte; thiết kế thật tách pha hoặc dùng mảng song song).
- **Lỗi giữa gói được xử lý đúng nghĩa:** các message đã hoàn chỉnh trước chỗ lỗi vẫn được phát, rồi cuối khung báo drop với lý do
  của lỗi đầu tiên (loại message lạ giữa gói, `count` nhỏ hơn số record thật, độ dài không khớp...).
- **Kiểm chứng:**
  - `parser64`: 20.147 sự kiện, từng sự kiện so golden: 19.393 message (635 có gap do cố ý rơi/gửi trùng gói), 754 khung bị loại.
    Gồm VLAN, gói heartbeat (count = 0, bị đệm), chu kỳ rảnh giữa khung, từ cuối thiếu byte. Đột biến đã thử và bị bắt:
    VLAN lệch 1 byte, bỏ qua gói trùng khi tính gap.
  - `stress64`: **1.000.000 message** (4,7 triệu từ 64 bit, tới 8 message/gói), 984.251 sự kiện, so bằng băm rolling 64 bit của mọi sự
    kiện theo đúng thứ tự (file từng sự kiện sẽ rất lớn) => khớp.
  - `pipeline64`: parser64 -> FIFO -> book, 100.009 message, bảng giá cuối khớp golden, FIFO không tràn.
- **Throughput (điểm nghẽn đo ở giai đoạn 4):** `linerate` = khung LIÊN TỤC không khoảng nghỉ (5,8 chu kỳ/message, tối đa 4 message/gói),
  ID lệnh tăng bình thường: book **theo kịp**, FIFO đầy nhất 9/64 (trước khi bỏ trạng thái DONE là 31/64). Cải thiện: bỏ trạng thái
  `S_DONE` riêng (message nào cũng nhanh hơn 1 chu kỳ; A trung bình 8 -> 7, E/D 9 -> 8) và test book vẫn khớp golden 100.000 message.
- **Giới hạn đã đo, chưa sửa:** nếu 30% order_id cố ý rơi vào cùng ô băm (`CLUSTER_P=0.3 python rtl/run_sim.py linerate`), book
  mất ~9 chu kỳ/message > 5,8 chu kỳ đến: FIFO tràn, cờ `fifo_overflow` bật đúng, sổ lệnh sau đó hỏng. Nguyên nhân gốc: bảng băm có
  thời gian tra KHÔNG xác định. Với order id tăng dần của ITCH thực tế thì ít gặp, nhưng HFT cần độ trễ dự đoán được; hướng sửa là
  bảng tra trực tiếp (sàn cấp id dày đặc), băm nhiều bậc có giới hạn chuỗi (d-left / cuckoo + stash), hoặc CAM.
- **Chưa làm so với kế hoạch gốc:** chưa pipeline book (nên chưa có hazard "cùng mức giá" để giải: book xử lý tuần tự); chưa hỗ trợ
  IP options hay QinQ (khung bị loại có chủ đích); `tick_to_trade` vẫn dùng parser 1 byte/chu kỳ (chưa chuyển sang parser64);
  backpressure kiểu AXI-Stream `ready` không áp dụng (MAC không dừng được dòng dữ liệu), thay bằng FIFO + cờ tràn đã kiểm.
- **Độ trễ tick-to-trade cập nhật** sau khi bỏ `S_DONE` (cùng `python rtl/run_sim.py t2t`): nhỏ nhất 11, trung bình 15, lớn nhất 46 chu kỳ
  (44 / 60 / 184 ns ở 250 MHz).

### Giai đoạn 6 – làm được phần lớn bằng công cụ mã nguồn mở (không có Vivado/Quartus trên máy này)

**Công cụ:** cài thêm `mingw-w64-x86_64-yosys` và `mingw-w64-x86_64-nextpnr` vào MSYS2 (gỡ bằng `pacman -R`). `python rtl/synth.py`
tổng hợp cho Xilinx 7-series bằng Yosys (số LUT/FF/BRAM/DSP); `python rtl/synth.py --par` tổng hợp cho ECP5 rồi đặt-và-đi-dây bằng
nextpnr-ecp5 để lấy **Fmax sau định tuyến thật** trên LFE5U-85F (mỗi khối bọc trong một vỏ tự sinh để không cần hàng trăm chân I/O).
ECP5 chậm hơn nhiều so với Xilinx 7-series/UltraScale: chỉ đọc như số TƯƠNG ĐỐI (trước/sau khi sửa, khối này so khối kia).

**Tài nguyên** (Yosys, Xilinx 7-series, 1 lần tổng hợp):

| khối | LUT | FF | BRAM | LUTRAM | DSP48 |
|---|---|---|---|---|---|
| parser 1 byte | 632 | 564 | 0 | 0 | 0 |
| pretrade_risk (3 tầng) | 284 | 404 | 0 | 0 | 4 |
| strategy_threshold | 34 | 14 | 0 | 0 | 0 |
| ouch_encoder | 266 | 262 | 0 | 0 | 0 |
| FIFO 64 x 208 bit | 44 | 28 | 0 | 70 | 0 |
| itch_book (bản đọc bất đồng bộ cũ, nay là `itch_book_async.v`) | 23.941 | 294 | 9 | 17.516 | 0 |
| parser 64 bit | *Yosys không xong* | | | | |

**Fmax sau định tuyến** (nextpnr-ecp5, LFE5U-85F, đích 150 MHz) và sửa đường găng:

| khối | trước | sau | cách sửa | giá phải trả |
|---|---|---|---|---|
| pretrade_risk | 48,1 MHz | **112,3 MHz** | (1) tách 2 tầng, (2) lưu "hạn mức còn lại" để `qty > room` thay cho cộng 33 bit rồi so, (3) tính 4 tích riêng 16x16 rồi mới cộng | +2 chu kỳ độ trễ (3 tầng); tick-to-trade 11/15/46 -> 13/17/48 chu kỳ |
| parser 1 byte | 58,2 MHz | **77,7 MHz** | tính sẵn `udp_len+20` và `udp_len-16`; dời kiểm tra checksum/IP đích từ byte 33 sang 35, dùng giá trị đã chốt vào thanh ghi | lỗi checksum/IP đích của khung cụt ở đúng byte 34 giờ báo là TRUNC; thêm LUT |
| ouch_encoder | 140,3 MHz | (không đổi) | | |
| strategy_threshold | 192,5 MHz | (không đổi) | | |

Mỗi lần sửa đều chạy lại test đầy đủ (24 tình huống risk, `parser`, `pipeline`, `t2t`) và đột biến biên của risk (`>` thành `>=`) vẫn bị bắt.

**Phát hiện lớn:**
1. **[ĐÃ SỬA, xem mục "Viết lại itch_book" bên dưới]** `itch_book` bản đầu KHÔNG hợp BRAM: 23.941 LUT + 17.516 ô LUTRAM chỉ cho một mã, vì các bảng (`lvl` 32K x 32 bit, `bm_lo`, `ot_*`) được đọc
   bất đồng bộ và có nhiều cổng đọc. Thiết kế cho BRAM thật cần đọc đồng bộ (1–2 chu kỳ), tối đa 2 cổng, nên phải chia nhỏ truy cập,
   giữ best bid/ask trong thanh ghi và cập nhật khi ghi thay vì truy vấn tổ hợp liên tục. Đây là việc lớn nhất còn lại.
2. **Cách mô tả "mở vòng 8 byte bằng gán blocking" của `parser64` đúng chức năng nhưng khiến Yosys treo >45 phút** ở bước tối ưu mux.
   Mô tả hợp công cụ hơn: logic theo từng làn song song, xác định trước vị trí từng trường theo `rel`, hoặc tách pha.
3. Bộ nhân 32x32 là đường găng mặc định của risk; chia nhỏ thành tích riêng là cách chung để đổi chu kỳ lấy Fmax.

**Chưa làm (và vì sao):** tổng hợp/đặt-và-đi-dây trên Vivado hoặc Quartus cho linh kiện HFT thật, ràng buộc thời gian `xdc/sdc`, bring-up trên board
(cần công cụ và phần cứng không có trên máy này, và phần lớn là phải tải/cài thủ công); Fmax của `parser64` (Yosys treo > 45 phút) và `itch_book` (ECP5 không xong trong 25 phút), xem phát hiện 1–2.

**Việc nên làm tiếp (theo giá trị):**
1. ~~Viết lại `itch_book` cho BRAM~~ (đã xong, xem mục bên dưới).
2. Thay bảng băm bằng cấu trúc có giới hạn trên về thời gian tra (tra trực tiếp theo order id dày đặc, hoặc d-left/cuckoo + stash).
3. Viết lại `parser64` ở dạng công cụ tổng hợp được, giữ nguyên bộ test hiện có làm lưới an toàn.
4. Chuyển `tick_to_trade` sang `parser64`; thêm vòng phản hồi khớp lệnh vào risk.
5. Khi có Vivado/Quartus: lặp lại toàn bộ phần đo bằng công cụ chính thức và linh kiện đích.

### Viết lại `itch_book` cho BRAM (việc số 1 của giai đoạn 6) – hoàn thành 8/11/2026

Phát hiện ở giai đoạn 6: bản cũ đọc các bảng BẤT ĐỒNG BỘ nhiều cổng nên Yosys trải ra 23.941 LUT + 17.516 ô LUTRAM chỉ cho một order book.
**Đã viết lại** (`rtl/itch_book.v`; bản cũ giữ ở `rtl/itch_book_async.v` để so sánh):
- Mọi bảng lớn (`oid` khoá, `oval` giá trị, `lvl` mức giá, `bm_lo` bitmap) có đúng 1 cổng đọc ĐỒNG BỘ + 1 cổng ghi. Địa chỉ đọc là hàm tổ hợp của trạng thái, nên mỗi
  quyết định phát ngay lệnh đọc kế tiếp; dò bảng băm vẫn 1 ô/chu kỳ nhờ đọc trước ô kế tiếp.
- Bitmap tầng trên (8 x 64) và giá tốt nhất nằm trong thanh ghi; giá tốt nhất được cập nhật khi ghi, chỉ dò lại qua bitmap khi mức giá tốt nhất cạn.
- Cổng debug dùng chung cổng đọc của `lvl` lúc rảnh: `dbg_qty` hợp lệ SAU 1 chu kỳ (testbench đã đổi theo). Giao diện còn lại không đổi.

| | bản cũ (bất đồng bộ) | bản mới (BRAM) |
|---|---|---|
| LUT (Yosys, 7-series) | 23.941 | **1.776** |
| LUTRAM | 17.516 | **0** |
| BRAM | 9 | 40 RAMB36E1 |
| FF | 294 | 1.134 |
| Fmax sau định tuyến (ECP5) | không xong trong 25 phút | **44,2 MHz** (2.984 LUT4, 80 DP16KD) |

**Kiểm chứng:** vẫn khớp golden: `book` (100.009 message + toàn bộ bảng mức giá cuối), `pipeline`, `pipeline64`, `linerate` (FIFO đầy nhất vẫn 9/64 nên thông lượng giữ nguyên), `t2t`
(288 lệnh khớp từng byte; độ trễ tick-to-trade 14 / 17 / 48 chu kỳ, trước đó 13 / 17 / 48). Số chu kỳ mỗi message gần như không đổi (A trung bình 8, E/D 8; tệ nhất 112 / 108 / 97)
vì cái giá của đọc đồng bộ được bù bằng việc phát lệnh đọc sớm. Đột biến đã thử trên bản cuối và bị bắt: đảo so sánh "giá tốt hơn", không dò lại giá tốt nhất khi cạn, dò sai bit giá bán tốt nhất,
coi mức giá là cạn khi `lvl >= exec`, xoá thành rỗng bất chấp ô kế (dọn tombstone).

**Vòng sửa đường găng Fmax của book** (nextpnr in đường găng, sửa, đo lại): 33,3 -> 37,2 -> 41,8 -> 44,2 MHz.
1. Dữ liệu `bm_mem` -> bộ mã hoá ưu tiên 64 bit -> địa chỉ `lvl_mem` trong CÙNG chu kỳ: đăng ký kết quả trước khi làm địa chỉ (thêm 2 trạng thái ở đường hiếm "mức giá tốt nhất cạn", +5 chu kỳ).
2. Bộ mã hoá ưu tiên viết bằng vòng lặp (chuỗi ~12 mức LUT): viết lại phân cấp 8 nhóm x 8 bit.
3. `lvl_rd +/- exec` -> so với 0 -> điều khiển: thay bằng `lvl_rd == exec_r` (chỉ E/D) nên bộ cộng chỉ còn dẫn tới dữ liệu ghi. Khác biệt duy nhất: bỏ qua tràn 32 bit khi cộng qty vào một mức giá.
Đường găng còn lại: `oid_mem` -> so sánh `order_id` 64 bit -> điều khiển (phép "có trúng không" của bảng băm). Sửa tiếp phải đổi cấu trúc dò (so sánh trễ một chu kỳ làm chậm dò, hoặc so thẻ băm ngắn trước).
Lưu ý: BRAM của ECP5 có clk-to-out ~5,8 ns (BRAM 7-series ~2 ns) nên con số tuyệt đối thấp hơn nhiều so với Xilinx; dùng để SO SÁNH trước/sau.

**Còn lại:** bảng băm vẫn có thời gian tra không xác định (tệ nhất ~110 chu kỳ trong ca xấu) và chưa pipeline qua nhiều message; `parser64` vẫn chưa tổng hợp được bằng Yosys.

