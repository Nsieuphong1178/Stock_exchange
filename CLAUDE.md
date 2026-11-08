# CLAUDE.md

## Về người dùng và mục đích dự án

Người dùng đang **tự học** để chuẩn bị cho công việc **FPGA engineer trong ultra low latency trading (HFT)**.
Dự án này là sàn chứng khoán mini phục vụ việc học, không phải sản phẩm. Họ đã có nền tảng thiết kế số
(Verilog/Vivado), nhưng đang tìm hiểu mới về:

- Cấu trúc thị trường chứng khoán: order book, matching engine, loại lệnh, price-time priority, risk check.
- Mạng: TCP/IP, socket, UDP/multicast, framing, độ trễ.
- Các giao thức giao dịch: FIX, ITCH/OUCH, SBE, binary protocol (hiện: lệnh qua JSON/TCP, market data qua binary kiểu ITCH/UDP multicast; đặt lệnh nhị phân kiểu OUCH có phiên đáng tin đã xong ở giai đoạn 3 trong ROADMAP.md).

## Cách trả lời và viết code

- **Trả lời bằng tiếng Việt**, giữ nguyên thuật ngữ tiếng Anh chuẩn (order book, matching engine, tick-to-trade, ...).
- **Giải thích "tại sao" trước "cái gì"**: mỗi quyết định thiết kế nên nói rõ nó giống/khác sàn thật ra sao.
- **Luôn liên hệ với FPGA/HFT** khi phù hợp: phần nào của pipeline thường được đưa xuống phần cứng
  (parse gói tin, decode ITCH, order book, risk check, tạo lệnh), phần nào ở lại phần mềm, và vì sao.
  Nói về độ trễ theo cấp độ (ns/µs) khi có ý nghĩa, không nói chung chung.
- Khi có thể đo được, hãy **đo thay vì phỏng đoán** (latency, throughput) và nêu rõ phương pháp đo.
- Khi tiện, chỉ ra điểm **không đại diện cho hệ thống thật** (ví dụ: dùng `std::map`, JSON, `select()` rất chậm
  so với hệ thống thật) để người học không hiểu nhầm là chuẩn công nghiệp.
- Không rút gọn quá mức phần **giải thích**: đây là tài liệu học, comment code bằng tiếng Việt giải thích ý nghĩa nghiệp vụ.
  (Điều này nói về giải thích, không phải về việc thêm tính năng; phần code vẫn theo các nguyên tắc bên dưới.)

## Nguyên tắc làm việc (giảm lỗi thường gặp khi LLM viết code)

Các nguyên tắc này nghiêng về cẩn thận hơn là nhanh. Với việc nhỏ và hiển nhiên thì tự cân nhắc.

### 1. Nghĩ trước khi code
**Không đoán. Không giấu chỗ chưa rõ. Nêu rõ các đánh đổi.**
- Nói rõ các giả định. Nếu không chắc thì hỏi.
- Nếu có nhiều cách hiểu, trình bày ra, đừng âm thầm chọn một.
- Nếu có cách đơn giản hơn thì nói. Phản biện khi cần.
- Nếu có gì chưa rõ thì dừng lại, nói chỗ nào chưa rõ, rồi hỏi.

### 2. Đơn giản trước
**Code tối thiểu đủ giải quyết vấn đề. Không làm thứ chưa ai yêu cầu.**
- Không thêm tính năng ngoài yêu cầu.
- Không tạo abstraction cho code chỉ dùng một lần.
- Không thêm "linh hoạt" hay "cấu hình" mà không ai đòi.
- Không xử lý lỗi cho tình huống không thể xảy ra.
- Nếu viết 200 dòng mà làm được trong 50 dòng thì viết lại.

Tự hỏi: "Một senior engineer có bảo cái này quá phức tạp không?" Nếu có thì đơn giản hoá.

### 3. Sửa đúng chỗ cần sửa
**Chỉ đụng vào những gì bắt buộc. Chỉ dọn rác do chính mình tạo ra.**
- Không "cải thiện" code, comment, định dạng ở xung quanh.
- Không refactor thứ chưa hỏng.
- Giữ đúng style hiện có, kể cả khi sẽ viết khác đi.
- Thấy code chết không liên quan thì nêu ra, đừng xoá.
- Nếu thay đổi của mình làm import/biến/hàm nào thành thừa thì xoá chúng; còn code chết có từ trước thì để nguyên trừ khi được yêu cầu.

Phép thử: mỗi dòng thay đổi phải truy ngược được về yêu cầu của người dùng.

### 4. Làm theo mục tiêu kiểm chứng được
**Đặt tiêu chí thành công. Lặp lại cho đến khi kiểm chứng được.**
- "Thêm validation" → "Viết test cho input sai, rồi làm cho test qua."
- "Sửa lỗi" → "Viết test tái hiện lỗi, rồi làm cho test qua."
- "Refactor X" → "Đảm bảo test qua cả trước và sau."

Với việc nhiều bước, nêu kế hoạch ngắn:
```
1. [Bước] → kiểm chứng: [cách kiểm tra]
2. [Bước] → kiểm chứng: [cách kiểm tra]
```

Các nguyên tắc này đang hiệu quả nếu: diff ít thay đổi thừa hơn, ít phải viết lại vì làm phức tạp, và các câu hỏi làm rõ đến trước khi code thay vì sau khi sai.

## Cấu trúc và quy ước

- `server/` – C++17, header-only trừ `main.cpp`. Pipeline: Gateway → Risk → OMS → Matching/Order Book → Execution Report + Market Data.
  `ExchangeCore` không biết gì về socket (để unit test); chỉ `gateway.hpp` đụng tới mạng.
- `client/` – Python, thư viện `exchange_client.py` + shell, dashboard, bot (load test).
- `tests/` – test end-to-end bằng Python; `server/tests/` – unit test C++ không dùng framework.
- `rtl/` – Verilog: `eth_udp_itch_parser.v` (parse Ethernet/IP/UDP + decode ITCH, 1 byte/chu kỳ), `eth_udp_itch_parser64.v`
  (64 bit/chu kỳ, VLAN, nhiều message/gói; `gen_vectors64.py`), `itch_book.v` (order book hợp BRAM: đọc đồng bộ, cổng debug `dbg_qty` trễ 1 chu kỳ; `itch_book_async.v` là bản cũ để so sánh; bảng băm lệnh +
  bảng mức giá + bitmap), `itch_pipeline.v` (parser → FIFO → book), `strategy_threshold.v` + `pretrade_risk.v` + `ouch_encoder.v` + `sfifo.v` ghép
  thành `tick_to_trade.v` (đường lệnh đầy đủ), các `tb_*.v`, `gen_vectors.py` / `gen_book_vectors.py` sinh
  vector, `run_sim.py [parser|parser64|book|ouch|risk|pipeline|pipeline64|linerate|stress64|t2t]` chạy mô phỏng bằng Verilator. Mọi kết quả so với golden Python
  (`client/feed_receiver.py`). Sau khi sửa RTL luôn chạy lại, và thử một đột biến để chắc testbench còn bắt được lỗi.
- Giá và số lượng là **số nguyên** (không dùng float cho tiền). Giữ quy ước này vì phần cứng cũng làm vậy.
- Đặt lệnh có hai đường song song trên cùng cổng: JSON mỗi dòng (`json.hpp`) và nhị phân kiểu OUCH/SoupBinTCP (`ouch.hpp`,
  `client/ouch.py`, `client/ouch_client.py`; golden cho `rtl/ouch_encoder.v`). Gateway nhận diện theo byte đầu và đổi qua lại,
  ExchangeCore chỉ biết JSON nội bộ. Market data nhị phân kiểu ITCH qua UDP multicast
  (`itch.hpp`, độ dài cố định, big-endian) là định dạng mà RTL parse; đổi định dạng thì phải đổi cả `itch.hpp`,
  `feed_receiver.py` và `eth_udp_itch_parser.v` cùng lúc.

## Build và chạy (Windows, g++ của MSYS2)

```
set PATH=C:\msys64\mingw64\bin;%PATH%
g++ -std=c++17 -Wall -Wextra -O2 server/main.cpp -o build/exchange_server.exe -lws2_32
g++ -std=c++17 -Wall -Wextra -O2 server/tests/test_core.cpp -o build/test_core.exe
build\test_core.exe
python -m unittest discover tests
python rtl/run_sim.py        # mô phỏng RTL (cần server đã build + Verilator của MSYS2)
python run_all_tests.py      # build + chạy TẤT CẢ ở trên; mã thoát 0 = đạt
python rtl/synth.py [--par]  # Yosys: tài nguyên; nextpnr-ecp5: Fmax sau định tuyến (cần pacman -S mingw-w64-x86_64-yosys mingw-w64-x86_64-nextpnr)
```

Luôn chạy unit test C++, test e2e (và `rtl/run_sim.py` nếu đụng tới `itch.hpp`, feed hoặc RTL) sau khi sửa.
Giữ bất biến: **tổng tiền và tổng cổ phiếu toàn sàn không đổi**.

## Lộ trình

Kế hoạch đầy đủ, theo tuần, kèm tiêu chí hoàn thành nằm ở **[ROADMAP.md](ROADMAP.md)** — đó là nguồn duy nhất,
đừng tự đề xuất một thứ tự khác. Khi người dùng hỏi "làm gì tiếp", đọc ROADMAP.md, xác định giai đoạn hiện tại
(dựa vào mục Nhật ký và các tiêu chí đã đạt) rồi đề xuất bước kế tiếp của giai đoạn đó. Tóm tắt:

1. Củng cố nền tảng và đo đạc (gap `seq` trong RTL, khôi phục snapshot, heartbeat, đo độ trễ).
2. Order book bằng RTL, kiểm bằng golden Python.
3. Đặt lệnh bằng giao thức nhị phân kiểu OUCH có phiên đáng tin.
4. Tick-to-trade trong mô phỏng: parser → book → chiến lược → risk → mã hoá lệnh.
5. Datapath rộng 64 bit, nhiều message mỗi gói, backpressure.
6. Tổng hợp (Vivado/Quartus), báo cáo Fmax, tài liệu.

Các ý như lệnh IOC/FOK, chặn self-trade, giá trần/sàn, FIX song song là **tuỳ chọn**, chỉ làm khi người dùng muốn.

## Lưu ý

- Người dùng sẽ commit khi họ yêu cầu; không tự `git commit`/`push`. Thư mục home của họ cũng là một git repo
  lộn xộn, nên cẩn thận với `git add -A` và nên chỉ thao tác trong `Mini_Stock_Exchange`.
- Server chỉ nghe ở `127.0.0.1`; không mở ra mạng ngoài.
