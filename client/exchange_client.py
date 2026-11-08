"""Trading Client: thư viện nói chuyện với sàn qua TCP + JSON (mỗi message một dòng)."""
import json
import queue
import socket
import threading
import time


class ExchangeClient:
    def __init__(self, user, host="127.0.0.1", port=9000, ping_interval=1.0):
        self.user = user
        self.sock = socket.create_connection((host, port))
        self.sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        self.inbox = queue.Queue()      # mọi message từ sàn
        self.on_message = None          # callback tuỳ chọn (chạy trong thread đọc)
        self.last_rx = time.monotonic()  # lần cuối nhận được gì từ sàn
        self._cid = 0
        self._closed = threading.Event()
        self._pong = threading.Event()
        threading.Thread(target=self._reader, daemon=True).start()
        threading.Thread(target=self._heartbeat, args=(ping_interval,), daemon=True).start()
        self.send(type="login", user=user)
        self.symbols = self.wait("login_ok")["symbols"]

    def _reader(self):
        try:
            for line in self.sock.makefile("r", encoding="utf-8"):
                self.last_rx = time.monotonic()
                msg = json.loads(line)
                if msg["type"] == "pong":   # chỉ để biết sàn còn sống
                    self._pong.set()
                    continue
                self.inbox.put(msg)
                if self.on_message:
                    self.on_message(msg)
        except (OSError, ValueError):
            pass
        self._close_event()

    def _close_event(self):
        if not self._closed.is_set():
            self._closed.set()
            self.inbox.put({"type": "closed"})

    def _heartbeat(self, interval):
        """Gửi ping định kỳ (sàn ngắt client im lặng) và coi sàn là chết nếu im lặng quá 3 chu kỳ."""
        while not self._closed.wait(interval):
            if time.monotonic() - self.last_rx > 3 * interval + 1:
                self._close_event()
                return
            try:
                self.send(type="ping")
            except OSError:
                self._close_event()
                return

    @property
    def alive(self):
        return not self._closed.is_set()

    def send(self, **msg):
        self.sock.sendall((json.dumps(msg) + "\n").encode())

    def wait(self, type_, timeout=5, match=None):
        """Chờ message có type mong muốn (bỏ qua các message khác)."""
        while True:
            msg = self.inbox.get(timeout=timeout)
            if msg["type"] == type_ and (match is None or match(msg)):
                return msg
            if msg["type"] == "closed":
                raise ConnectionError("server closed")

    # ---- lệnh ----
    def order(self, symbol, side, qty, price=None):
        """price=None => lệnh MARKET."""
        self._cid += 1
        msg = dict(type="new", symbol=symbol, side=side, qty=qty, cid=str(self._cid))
        if price is None:
            msg["ord_type"] = "MARKET"
        else:
            msg["ord_type"] = "LIMIT"
            msg["price"] = price
        self.send(**msg)
        return str(self._cid)

    def buy(self, symbol, qty, price=None):
        return self.order(symbol, "BUY", qty, price)

    def sell(self, symbol, qty, price=None):
        return self.order(symbol, "SELL", qty, price)

    def cancel(self, order_id):
        self.send(type="cancel", order_id=order_id)

    # ---- truy vấn (đồng bộ) ----
    def book(self, symbol):
        self.send(type="book", symbol=symbol)
        return self.wait("md_book", match=lambda m: m["symbol"] == symbol)

    def account(self):
        self.send(type="account")
        return self.wait("account")

    def orders(self):
        self.send(type="orders")
        return self.wait("orders")["orders"]

    def ping_rtt_ns(self, timeout=5):
        """Thời gian vòng đi về ping -> pong (ns): chỉ đi qua gateway, không qua risk/khớp lệnh."""
        self._pong.clear()
        t0 = time.perf_counter_ns()
        self.send(type="ping")
        if not self._pong.wait(timeout):
            raise TimeoutError("no pong")
        return time.perf_counter_ns() - t0

    def stats(self, reset=False):
        """Thống kê thời gian xử lý phía server (ns) cho các request kể từ lần reset trước."""
        self.send(type="stats", reset=int(reset))
        return self.wait("stats")

    def snapshot(self):
        """Mọi lệnh đang chờ + seq của gói feed UDP cuối cùng mà trạng thái này tương ứng."""
        self.send(type="snapshot")
        return self.wait("snapshot")

    def subscribe(self, symbol):
        self.send(type="subscribe", symbol=symbol)

    def close(self):
        self._closed.set()  # dừng thread heartbeat
        self.sock.close()
