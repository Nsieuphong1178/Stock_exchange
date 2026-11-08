"""Bot tạo thanh khoản + load test.   python client/bot.py [số_bot] [số_lệnh_mỗi_bot] [port]

Mỗi bot đặt lệnh limit ngẫu nhiên quanh giá tham chiếu (random walk) và thỉnh thoảng đặt lệnh market.
Cuối cùng in thông lượng (lệnh/giây) và kiểm tra tổng tiền + cổ phiếu của cả sàn không đổi.
"""
import random
import sys

sys.stdout.reconfigure(encoding="utf-8")
import threading
import time

from exchange_client import ExchangeClient

SYMBOLS = ["AAA", "BBB", "CCC"]
REF = {"AAA": 1000, "BBB": 500, "CCC": 2000}


def run_bot(name, n_orders, port, stats):
    c = ExchangeClient(name, port=port)
    rng = random.Random(name)
    sent = 0
    for _ in range(n_orders):
        sym = rng.choice(SYMBOLS)
        side = rng.choice(["BUY", "SELL"])
        if rng.random() < 0.1:
            c.order(sym, side, rng.randint(1, 5))  # market
        else:
            ref = REF[sym]
            px = max(1, ref + rng.randint(-ref // 50, ref // 50))
            c.order(sym, side, rng.randint(1, 20), px)
        sent += 1
    # đợi mọi phản hồi (ack/reject) của lệnh đã gửi => đo được độ trễ end-to-end
    acks = 0
    while acks < sent:
        m = c.inbox.get(timeout=30)
        if m["type"] == "exec" and m["text"] in ("accepted", "unknown symbol") or m.get("status") == "REJECTED":
            acks += 1
    stats[name] = c.account()
    c.close()


def main():
    n_bots = int(sys.argv[1]) if len(sys.argv) > 1 else 5
    n_orders = int(sys.argv[2]) if len(sys.argv) > 2 else 500
    port = int(sys.argv[3]) if len(sys.argv) > 3 else 9000
    stats = {}
    t0 = time.time()
    threads = [threading.Thread(target=run_bot, args=(f"bot{i}", n_orders, port, stats)) for i in range(n_bots)]
    [t.start() for t in threads]
    [t.join() for t in threads]
    dt = time.time() - t0
    total = n_bots * n_orders
    print(f"{total} lệnh từ {n_bots} bot trong {dt:.2f}s => {total / dt:,.0f} lệnh/giây (gồm cả round-trip)")
    print("tổng tiền các bot:", sum(s["cash"] for s in stats.values()), "(ban đầu", n_bots * 10_000_000, ")")


if __name__ == "__main__":
    main()
