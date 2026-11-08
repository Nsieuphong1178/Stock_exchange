"""Nhận market data nhị phân (UDP multicast), dựng lại sổ lệnh và phát hiện mất gói.

Định dạng message xem server/itch.hpp. Một gói UDP = seq[8] + 1 message ITCH, big-endian.
Chạy thử:  python client/feed_receiver.py
"""
import socket
import struct
import threading

GROUP, PORT = "239.1.1.1", 30001

# '>' = big-endian, không đệm (padding). Kích thước phải khớp itch.hpp: 26 / 21 / 9 byte.
FMT_A = struct.Struct(">cQcI8sI")
FMT_E = struct.Struct(">cQIQ")
FMT_D = struct.Struct(">cQ")


def decode(msg):
    t = msg[:1]
    if t == b"A" and len(msg) == FMT_A.size:
        _, oid, side, qty, sym, px = FMT_A.unpack(msg)
        return {"type": "A", "order_id": oid, "side": side.decode(), "qty": qty,
                "symbol": sym.decode().strip(), "price": px}
    if t == b"E" and len(msg) == FMT_E.size:
        _, oid, qty, match_no = FMT_E.unpack(msg)
        return {"type": "E", "order_id": oid, "qty": qty, "match_no": match_no}
    if t == b"D" and len(msg) == FMT_D.size:
        return {"type": "D", "order_id": FMT_D.unpack(msg)[1]}
    raise ValueError(f"bad message {msg!r}")


class BookBuilder:
    """Dựng sổ lệnh chỉ từ các message A/E/D (giống cách một feed handler trên FPGA làm)."""

    def __init__(self):
        self.orders = {}  # order_id -> [symbol, side, price, qty còn lại]

    def apply(self, m):
        if m["type"] == "A":
            self.orders[m["order_id"]] = [m["symbol"], m["side"], m["price"], m["qty"]]
        elif m["type"] == "E":
            o = self.orders[m["order_id"]]
            o[3] -= m["qty"]
            if o[3] == 0:
                del self.orders[m["order_id"]]
        elif m["type"] == "D":
            self.orders.pop(m["order_id"], None)

    def reset(self, orders):
        """Thay toàn bộ sổ bằng snapshot: danh sách [order_id, 'B'/'S', giá, qty còn lại, mã]."""
        self.orders = {oid: [sym, side, px, qty] for oid, side, px, qty, sym in orders}

    def levels(self, symbol, depth=10):
        """Trả về (bids, asks) dạng [[giá, tổng qty], ...] cùng quy ước với lệnh `book` qua TCP."""
        agg = {"B": {}, "S": {}}
        for sym, side, px, qty in self.orders.values():
            if sym == symbol:
                agg[side][px] = agg[side].get(px, 0) + qty
        bids = sorted(agg["B"].items(), reverse=True)[:depth]
        asks = sorted(agg["S"].items())[:depth]
        return [list(x) for x in bids], [list(x) for x in asks]


class FeedReceiver:
    def __init__(self, group=GROUP, port=PORT, iface="127.0.0.1", listen=True, snapshot_fn=None):
        """snapshot_fn: hàm trả về snapshot {'seq', 'orders'} (vd ExchangeClient.snapshot). Có thì khi phát hiện
        mất gói sẽ tự khôi phục: thay sổ bằng snapshot rồi bỏ qua mọi gói có seq <= snapshot['seq']."""
        self.book = BookBuilder()
        self.snapshot_fn = snapshot_fn
        self.expected = None   # seq mong đợi của gói kế tiếp
        self.last_seq = 0
        self.floor = 0         # gói có seq <= floor đã nằm trong snapshot gần nhất => bỏ qua
        self.gaps = []         # [(seq mong đợi, seq nhận được)]
        self.resyncs = 0       # số lần khôi phục bằng snapshot
        self.valid = True      # False sau khi mất gói mà chưa khôi phục: sổ lệnh dựng lại không còn tin được
        self.lock = threading.Lock()
        if listen:
            self.sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            self.sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            self.sock.bind(("", port))
            mreq = socket.inet_aton(group) + socket.inet_aton(iface)  # (nhóm, giao diện mạng nhận)
            self.sock.setsockopt(socket.IPPROTO_IP, socket.IP_ADD_MEMBERSHIP, mreq)
            threading.Thread(target=self._loop, daemon=True).start()

    def _loop(self):
        while True:
            try:
                pkt, _ = self.sock.recvfrom(2048)
            except OSError:
                return
            self.handle_packet(pkt)

    def handle_packet(self, pkt):
        seq = struct.unpack(">Q", pkt[:8])[0]
        with self.lock:
            if seq <= self.floor:
                return  # đã có trong snapshot
            if self.expected is not None and seq != self.expected:
                self.gaps.append((self.expected, seq))  # seq > expected: mất gói; seq < expected: gói đến trễ/trùng
                if self.snapshot_fn:
                    snap = self.snapshot_fn()
                    self.book.reset(snap["orders"])
                    self.floor = snap["seq"]
                    self.expected = snap["seq"] + 1
                    self.resyncs += 1
                    self.valid = True
                    if seq <= self.floor:
                        return
                else:
                    self.valid = False
            self.expected = seq + 1
            self.last_seq = seq
            self.book.apply(decode(pkt[8:]))

    def close(self):
        self.sock.close()


if __name__ == "__main__":
    import sys
    sys.stdout.reconfigure(encoding="utf-8")
    r = FeedReceiver()
    r.book.apply = (lambda orig: lambda m: (print(m), orig(m)))(r.book.apply)
    print(f"Đang nghe {GROUP}:{PORT} ... (Ctrl+C để dừng)")
    try:
        threading.Event().wait()
    except KeyboardInterrupt:
        print("gaps:", r.gaps)
