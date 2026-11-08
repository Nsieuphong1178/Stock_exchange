"""Client giao thức nhị phân kiểu OUCH/SoupBinTCP, chịu được rớt mạng.

Hai cơ chế đảm bảo "không mất, không trùng" (xem server/ouch.hpp):
  - Báo cáo từ sàn có SỐ THỨ TỰ. Client nhớ số kế tiếp cần nhận (next_seq); nối lại thì đăng nhập với next_seq đó và
    sàn phát lại phần còn thiếu => không mất báo cáo nào.
  - Mỗi lệnh có TOKEN duy nhất. Gửi lại lệnh (không biết lệnh trước đã tới sàn chưa) bằng cùng token thì sàn bỏ qua
    nếu đã xử lý => không trùng lệnh.
"""
import queue
import socket
import struct
import threading
import time

import ouch


class OuchClient:
    def __init__(self, user, port=9000, host="127.0.0.1", next_seq=1, heartbeat=1.0):
        self.user, self.host, self.port, self.hb = user, host, port, heartbeat
        self.next_seq = next_seq        # số thứ tự của message 'S' kế tiếp cần nhận
        self.session_id = None
        self.session_changed = False    # True nếu sau khi nối lại, server đã khởi động lại (số thứ tự mất ý nghĩa)
        self.events = queue.Queue()     # (seq, dict) theo thứ tự nhận; dùng wait()
        self.history = []               # mọi (seq, dict) đã nhận, để kiểm tra
        self.alive = False
        self._threads = []
        self._connect()

    # ---- kết nối ----
    def _connect(self):
        self.sock = socket.create_connection((self.host, self.port))
        self.sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        self.sock.sendall(ouch.login(self.user, self.next_seq))
        buf = b""
        ptype, body, buf = self._read_packet(self.sock, buf)  # trả lời đăng nhập, đọc đồng bộ
        if ptype == b"J":
            self.sock.close()
            raise ConnectionRefusedError(f"login rejected: {body!r}")
        session_id, _ = struct.unpack(">QQ", body)
        self.session_changed = self.session_id is not None and session_id != self.session_id
        self.session_id = session_id
        self.alive = True
        self.last_rx = time.monotonic()
        sock = self.sock
        self._threads = [threading.Thread(target=self._reader, args=(sock, buf), daemon=True),
                         threading.Thread(target=self._heartbeat, args=(sock,), daemon=True)]
        for t in self._threads:
            t.start()

    def _reader(self, sock, buf):
        try:
            while True:
                ptype, body, buf = self._read_packet(sock, buf)
                self.last_rx = time.monotonic()
                if ptype == b"S":
                    seq = self.next_seq
                    self.next_seq += 1
                    ev = (seq, ouch.decode(body))
                    self.history.append(ev)
                    self.events.put(ev)
        except (OSError, ConnectionError):
            pass
        if sock is self.sock:
            self.alive = False

    def _read_packet(self, sock, buf):
        while True:
            if len(buf) >= 2:
                length = struct.unpack(">H", buf[:2])[0]
                if len(buf) >= 2 + length:
                    return buf[2:3], buf[3:2 + length], buf[2 + length:]
            chunk = sock.recv(4096)
            if not chunk:
                raise ConnectionError("server closed")
            buf += chunk

    def _heartbeat(self, sock):
        """Gửi 'H' định kỳ (sàn ngắt client im lặng) và coi sàn là chết nếu im lặng quá 3 chu kỳ + 1 giây."""
        while sock is self.sock and self.alive:
            time.sleep(self.hb)
            try:
                if time.monotonic() - self.last_rx > 3 * self.hb + 1:
                    self.alive = False
                    sock.close()
                    return
                sock.sendall(ouch.packet(b"H"))
            except OSError:
                return

    def disconnect(self):
        """Ngắt kết nối đột ngột (như rớt mạng): không gửi 'Z'. Chờ luồng đọc cũ kết thúc rồi mới trả về."""
        self.alive = False
        try:
            self.sock.shutdown(socket.SHUT_RDWR)
        except OSError:
            pass
        self.sock.close()
        for t in self._threads:
            t.join(timeout=2)

    def reconnect(self):
        """Nối lại và xin phát lại từ next_seq. Phải gọi sau disconnect()."""
        self._connect()

    def close(self):
        if self.alive:
            try:
                self.sock.sendall(ouch.packet(b"Z"))
            except OSError:
                pass
        self.disconnect()

    # ---- lệnh ----
    def _send(self, msg):
        self.sock.sendall(ouch.unsequenced(msg))

    def enter(self, token, side, qty, symbol, price=None):
        """Đặt lệnh. price=None => lệnh MARKET. Gọi lại với CÙNG token là an toàn (sàn bỏ qua nếu đã xử lý)."""
        if price is None:
            self._send(ouch.enter_order(token, side, qty, symbol, 0, "M"))
        else:
            self._send(ouch.enter_order(token, side, qty, symbol, price, "L"))

    def cancel(self, token):
        self._send(ouch.cancel_order(token))

    def wait(self, kind, token=None, timeout=5):
        """Chờ message loại `kind` ('A', 'E', 'C', 'J'), tuỳ chọn khớp token; trả về (seq, dict)."""
        deadline = time.monotonic() + timeout
        while True:
            seq, ev = self.events.get(timeout=max(0.01, deadline - time.monotonic()))
            if ev["type"] == kind and (token is None or ev["token"] == token):
                return seq, ev
