"""Đo độ trễ vòng đi về của đường JSON/TCP.   python client/latency.py [số_lần] [port]

Mỗi phép đo gửi MỘT yêu cầu rồi đợi phản hồi trước khi gửi tiếp (không có hàng đợi, nên đo độ trễ thuần,
không phải thông lượng). Ba tình huống, từ ít việc tới nhiều việc:
  ping        : chỉ qua gateway (nhận, parse JSON, trả lời)
  lệnh nằm chờ: + Risk + OMS + order book + execution report "accepted"
  lệnh khớp   : + khớp với lệnh chờ + thanh toán + execution report khớp

Hai cột: "client" đo bằng Python (gồm cả hệ điều hành, thread, JSON phía Python - thường chiếm phần lớn),
"server" là thời gian ExchangeCore xử lý (gồm đẩy kết quả vào socket) do chính server C++ đo bằng steady_clock.
"""
import sys
import time

sys.stdout.reconfigure(encoding="utf-8")
from exchange_client import ExchangeClient  # noqa: E402

SYMBOL = "CCC"


def pct(sorted_ns, p):
    return sorted_ns[int(p * (len(sorted_ns) - 1))] / 1000  # ns -> µs


def row(name, samples, server):
    s = sorted(samples)
    srv = f"{server['p50_ns'] / 1000:>7.1f} {server['p99_ns'] / 1000:>7.1f}" if server else f"{'-':>7} {'-':>7}"
    print(f"{name:<14}{pct(s, .5):>9.1f}{pct(s, .9):>9.1f}{pct(s, .99):>9.1f}{s[-1] / 1000:>9.1f}   {srv}")


def main():
    n = int(sys.argv[1]) if len(sys.argv) > 1 else 2000
    port = int(sys.argv[2]) if len(sys.argv) > 2 else 9000
    # ping_interval lớn: không để heartbeat nền chen vào lúc đo
    taker = ExchangeClient("lat_taker", port=port, ping_interval=3600)
    maker = ExchangeClient("lat_maker", port=port, ping_interval=3600)

    for _ in range(200):  # khởi động: tránh đo cả lần chạy đầu (cache lạnh, kết nối mới)
        taker.ping_rtt_ns()

    taker.stats(reset=True)
    ping = [taker.ping_rtt_ns() for _ in range(n)]

    rest = []
    for i in range(n):
        t0 = time.perf_counter_ns()
        taker.buy(SYMBOL, 1, 10 + i % 50)  # giá thấp, không có lệnh bán nào => nằm chờ
        taker.wait("exec", match=lambda m: m["text"] == "accepted")
        rest.append(time.perf_counter_ns() - t0)
    rest_srv = taker.stats(reset=True)

    fill = []
    n_fill = min(n, 900)  # mỗi lệnh khớp tiêu 1 cổ phiếu của maker (chỉ có 1000) và ~5000 tiền của taker
    for i in range(n_fill):
        maker.sell(SYMBOL, 1, 5000 + i % 50)
        maker.wait("exec", match=lambda m: m["text"] == "accepted")  # chuẩn bị xong, chưa tính giờ
        t0 = time.perf_counter_ns()
        taker.buy(SYMBOL, 1, 5000 + i % 50)
        taker.wait("exec", match=lambda m: m["last_qty"] > 0)
        fill.append(time.perf_counter_ns() - t0)

    print(f"{n} lần (lệnh khớp: {n_fill} lần), đơn vị µs\n")
    print(f"{'':<14}{'p50':>9}{'p90':>9}{'p99':>9}{'max':>9}   server p50  p99")
    row("ping", ping, None)  # ping trả lời trước điểm đo của server nên không có mẫu phía server
    row("lệnh nằm chờ", rest, rest_srv)
    row("lệnh khớp", fill, None)  # server đo gồm cả lệnh maker chuẩn bị nên không so sánh được


if __name__ == "__main__":
    main()
