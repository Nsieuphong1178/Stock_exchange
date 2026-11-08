# Mini Stock Exchange

Sàn chứng khoán đơn giản để học: server C++ (matching engine) + client Python, nói chuyện qua TCP, mỗi message là một dòng JSON.

```
Python client ──TCP/JSON──> Gateway ──> Risk Engine ──> OMS ──> Matching Engine / Order Book
                               ^                                        │
                               └── Execution Report + Market Data <─────┘        Logger ghi mọi bước
```

| Module | File | Nhiệm vụ |
|---|---|---|
| Gateway | `server/gateway.hpp` | TCP server (select, đơn luồng), parse JSON, định tuyến |
| Risk Engine | `server/risk_engine.hpp` | Kiểm tra tiền/cổ phiếu, phong toả, thanh toán |
| OMS | `server/oms.hpp` | Tạo ID, lưu vòng đời lệnh |
| Matching Engine | `server/matching_engine.hpp` | Một sổ lệnh cho mỗi mã |
| Order Book | `server/order_book.hpp` | Khớp lệnh theo giá rồi thời gian |
| Market Data / Execution Report | `server/exchange_core.hpp` | Đẩy trade + sổ lệnh / kết quả lệnh |
| Logger | `server/logger.hpp` | Console + `exchange.log` |

## Chạy (Windows, MSYS2 mingw64)
```
set PATH=C:\msys64\mingw64\bin;%PATH%
g++ -std=c++17 -O2 server/main.cpp -o build/exchange_server.exe -lws2_32
g++ -std=c++17 -O2 server/tests/test_core.cpp -o build/test_core.exe
build\test_core.exe                      # unit test C++
python -m unittest discover tests        # test end-to-end (cần build server trước)
build\exchange_server.exe                # server cổng 9000, mã AAA BBB CCC

python client/shell.py alice             # terminal giao dịch (mở thêm cửa sổ cho bob)
python client/dashboard.py AAA           # xem sổ lệnh + giao dịch realtime
python client/bot.py 5 1000              # 5 bot x 1000 lệnh = load test
```
(Có `CMakeLists.txt` nếu bạn dùng CMake.) Mỗi user mới có 10,000,000 tiền và 1000 cổ phiếu mỗi mã.

## Giao thức
Client → sàn: `login`, `new` (symbol, side BUY/SELL, ord_type LIMIT/MARKET, qty, price, cid), `cancel` (order_id),
`book`, `account`, `orders`, `subscribe`/`unsubscribe` (symbol).
Sàn → client: `exec` (execution report), `md_book`, `md_trade`, `account`, `orders`, `error`.

## Market data nhị phân (UDP multicast)
Song song với kênh JSON/TCP, server phát feed kiểu ITCH tới `239.1.1.1:30001` (chỉ trên loopback).
Mỗi gói = `seq[8]` + 1 message, big-endian, độ dài cố định (chi tiết trong `server/itch.hpp`):
`A` Add Order (26 byte), `E` Order Executed (21 byte), `D` Order Delete (9 byte).
`python client/feed_receiver.py` in các message; `FeedReceiver` dựng lại sổ lệnh và phát hiện mất gói bằng `seq`.
Test `test_udp_feed_rebuilds_same_book_as_tcp` kiểm tra sổ dựng từ UDP == sổ qua TCP.

## Độ tin cậy và đo đạc
- Mất gói feed: `FeedReceiver` phát hiện bằng `seq`; truyền `snapshot_fn=client.snapshot` thì tự khôi phục bằng snapshot TCP.
- Heartbeat: client tự `ping`; server ngắt client im lặng quá `idle` giây (`exchange_server <port> <idle>`).
- `python client/latency.py` đo độ trễ vòng đi về (ping / lệnh nằm chờ / lệnh khớp); kết quả mẫu trong `ROADMAP.md`.
  Build với `-DLOGGER_DISABLE` để loại chi phí ghi log khỏi phép đo.
- `python run_all_tests.py` build và chạy mọi test (C++, Python, RTL).

## Đặt lệnh nhị phân kiểu OUCH
Cùng cổng với JSON (server tự nhận diện theo byte đầu). Khung `length[2] type[1] payload`, message độ dài cố định, định
dạng đầy đủ ở đầu `server/ouch.hpp`. `client/ouch_client.py` (`OuchClient`): `enter(token, 'B', qty, 'AAA', price)`,
`cancel(token)`, `wait('A'|'E'|'C'|'J')`. Báo cáo của sàn có số thứ tự và được lưu: `disconnect()` rồi `reconnect()` sẽ
nhận lại phần bị lỡ; gửi lại lệnh cùng token không tạo lệnh trùng. `rtl/ouch_encoder.v` mã hoá gói này trong phần cứng.

## RTL: parse Ethernet/IP/UDP + decode ITCH (`rtl/`)
`rtl/eth_udp_itch_parser.v` nhận luồng byte (1 byte/chu kỳ), kiểm tra Ethernet/IPv4/UDP (gồm checksum IP) và decode
message `A`/`E`/`D`; khung sai bị loại kèm mã lý do. `python rtl/run_sim.py` chạy server thật để bắt gói UDP, bọc thành
khung Ethernet kèm vài khung lỗi cố ý, mô phỏng bằng Verilator và so với golden (bộ decode Python). Chi tiết giả định
và các lỗi toolchain Windows nằm trong đầu file `run_sim.py`.

### Order book RTL
`rtl/itch_book.v` (bản hợp BRAM: đọc đồng bộ; bản bất đồng bộ cũ ở `itch_book_async.v`) dựng lại sổ lệnh từ message `A/E/D`: bảng băm (linear probing, tombstone) cho `order_id` → lệnh, bảng
tổng qty theo `{mã, bên, giá}` và bitmap hai tầng để tìm giá tốt nhất không cần duyệt. `rtl/itch_pipeline.v` ghép
parser → FIFO → book. `python rtl/run_sim.py [parser|book|pipeline]` so với golden Python trên 100.000 message ngẫu nhiên.

### Tick-to-trade (mô phỏng)
`rtl/tick_to_trade.v`: khung Ethernet vào, gói OUCH ra. Chuỗi `parser → FIFO → order book → strategy_threshold →
pretrade_risk → FIFO lệnh → ouch_encoder`. `python rtl/run_sim.py t2t` kiểm 100.009 message so với golden Python (từng byte
lệnh ra, số lần risk loại theo lý do) và in phân bố độ trễ tick-to-trade (nhỏ nhất 12, trung bình 16, lớn nhất 47 chu kỳ).
`python rtl/run_sim.py risk` chạy các tình huống riêng của khối risk.

### Datapath 64 bit
`rtl/eth_udp_itch_parser64.v`: 8 byte/chu kỳ, VLAN, nhiều message/gói. Bài kiểm: `python rtl/run_sim.py parser64` (từng sự kiện),
`stress64` (1 triệu message, so băm), `pipeline64` (ghép với book), `linerate` (khung liên tục không nghỉ: book có theo kịp?).

### Tổng hợp và Fmax
`python rtl/synth.py` (Yosys, số LUT/FF/BRAM cho Xilinx 7-series) và `python rtl/synth.py --par` (nextpnr-ecp5, Fmax sau định tuyến). Cần
`pacman -S mingw-w64-x86_64-yosys mingw-w64-x86_64-nextpnr`. Kết quả, cách sửa đường găng và các phát hiện: `docs/ARCHITECTURE.md` mục 7.
Tài liệu kiến trúc, bảng độ trễ và bài học: `docs/ARCHITECTURE.md`.

## Để học tiếp
- Khớp lệnh: giá khớp luôn là giá lệnh đang chờ; lệnh limit mua giá cao hơn vẫn được hưởng giá tốt (xem `test_price_improvement`).
- Bất biến: tổng tiền và cổ phiếu của cả sàn không đổi (`test_conservation`).
- Bài tập mở rộng: lệnh IOC/FOK, chặn tự khớp (self-trade), UDP multicast cho market data, thay JSON bằng FIX,
  phiên ATO/ATC, bước giá + giá trần/sàn, web dashboard.
