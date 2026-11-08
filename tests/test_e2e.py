"""Test end-to-end: bật server C++ thật, dùng client Python giao dịch qua TCP.  python -m unittest discover tests"""
import os
import socket
import struct
import subprocess
import sys
import threading
import time
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "client"))
from exchange_client import ExchangeClient  # noqa: E402
from feed_receiver import FeedReceiver  # noqa: E402
from ouch_client import OuchClient  # noqa: E402
import ouch  # noqa: E402

PORT = 9123
EXE = os.path.join(ROOT, "build", "exchange_server.exe" if os.name == "nt" else "exchange_server")


class Capture(FeedReceiver):
    """Giữ nguyên gói UDP thô thay vì decode."""

    def __init__(self):
        self.packets = []
        super().__init__()

    def handle_packet(self, pkt):
        self.packets.append(pkt)


class E2E(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        # tham số thứ 2 = idle timeout 3 giây (mặc định 10) để test ngắt client im lặng không phải đợi lâu
        cls.proc = subprocess.Popen([EXE, str(PORT), "3"], cwd=os.path.join(ROOT, "build"), stderr=subprocess.DEVNULL)
        for _ in range(50):
            try:
                ExchangeClient("probe", port=PORT).close()
                return
            except OSError:
                time.sleep(0.1)
        raise RuntimeError("server did not start")

    @classmethod
    def tearDownClass(cls):
        cls.proc.kill()

    def test_trade_between_two_clients(self):
        a, b = ExchangeClient("alice", port=PORT), ExchangeClient("bob", port=PORT)
        a.subscribe("AAA")
        a.wait("md_book")
        b.sell("BBB", 10, 100)
        self.assertEqual(b.wait("exec")["text"], "accepted")
        a.buy("BBB", 4, 100)
        a.wait("exec", match=lambda m: m["text"] == "accepted")
        fill = a.wait("exec", match=lambda m: m["last_qty"] > 0)
        self.assertEqual((fill["last_qty"], fill["last_px"]), (4, 100))
        self.assertEqual(a.account()["positions"]["BBB"], 1004)
        self.assertEqual(b.book("BBB")["asks"], [[100, 6]])

    def test_slow_consumer_does_not_block_exchange(self):
        # Client "chậm": đăng ký market data nhưng không bao giờ đọc => bộ đệm gửi của server tới nó đầy.
        slow = socket.create_connection(("127.0.0.1", PORT))
        slow.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 4096)
        slow.sendall(b'{"type":"login","user":"slow"}\n{"type":"subscribe","symbol":"AAA"}\n')
        time.sleep(0.2)
        flood = ExchangeClient("flood", port=PORT)
        flood.sock.settimeout(10)  # nếu server treo thì test lỗi chứ không treo theo
        for i in range(20000):  # mỗi lệnh sinh một md_book (~400 byte) gửi tới "slow"
            flood.buy("AAA", 1, 50 + i % 40)
        # Sàn vẫn phải trả lời client bình thường
        self.assertEqual(flood.account()["user"], "flood")
        # và client chậm bị ngắt (đọc cho tới khi hết dữ liệu thì gặp EOF/reset)
        slow.settimeout(5)
        try:
            while slow.recv(65536):
                pass
        except ConnectionError:
            pass
        slow.close()

    def test_udp_feed_rebuilds_same_book_as_tcp(self):
        # Sổ lệnh dựng lại CHỈ từ luồng UDP nhị phân phải giống hệt sổ lệnh server trả qua TCP.
        feed = FeedReceiver()
        time.sleep(0.3)  # đợi socket tham gia nhóm multicast
        a, b = ExchangeClient("feed_a", port=PORT), ExchangeClient("feed_b", port=PORT)
        for px, q in ((100, 10), (100, 5), (101, 7)):
            a.sell("CCC", q, px)
        for px, q in ((99, 8), (98, 4)):
            b.buy("CCC", q, px)
        b.buy("CCC", 12, 100)      # khớp hết lệnh bán 10@100 và 2 của lệnh 5@100
        a.sell("CCC", 3, 98)       # khớp với 8@99 (còn 5)... rồi nằm chờ nếu còn dư
        a.cancel(a.orders()[1]["order_id"])  # huỷ một lệnh đang chờ
        time.sleep(0.5)
        server = b.book("CCC")
        self.assertEqual(feed.book.levels("CCC"), (server["bids"], server["asks"]))
        self.assertTrue(feed.valid, feed.gaps)
        feed.close()

    def test_silent_client_dropped_but_heartbeat_keeps_alive(self):
        silent = socket.create_connection(("127.0.0.1", PORT))
        silent.sendall(b'{"type":"login","user":"silent"}\n')
        alive = ExchangeClient("alive", port=PORT, ping_interval=0.5)  # ping 0.5s < idle timeout 3s
        time.sleep(4.5)
        silent.settimeout(2)
        data = b""
        while True:  # đọc hết phần còn lại (login_ok...) tới khi server đóng => recv trả b""
            chunk = silent.recv(4096)
            if not chunk:
                break
            data += chunk
        self.assertIn(b"login_ok", data)
        self.assertTrue(alive.alive)
        self.assertEqual(alive.account()["user"], "alive")  # vẫn dùng được sau khi vượt idle timeout nhiều lần
        silent.close()
        alive.close()

    def test_client_detects_dead_server(self):
        srv = socket.socket()
        srv.bind(("127.0.0.1", 0))
        srv.listen(1)

        def fake_server():  # chấp nhận kết nối, trả login_ok rồi im lặng hoàn toàn
            conn, _ = srv.accept()
            conn.recv(4096)
            conn.sendall(b'{"type":"login_ok","user":"x","symbols":[]}\n')
            time.sleep(5)
            conn.close()

        threading.Thread(target=fake_server, daemon=True).start()
        c = ExchangeClient("x", port=srv.getsockname()[1], ping_interval=0.2)
        self.assertTrue(c.alive)
        time.sleep(2.5)  # > 3 * 0.2 + 1 giây không nghe gì từ "server"
        self.assertFalse(c.alive)
        c.close()
        srv.close()

    def test_feed_gap_recovered_by_tcp_snapshot(self):
        cap = Capture()
        time.sleep(0.3)
        a, b = ExchangeClient("snap_a", port=PORT), ExchangeClient("snap_b", port=PORT)
        a.sell("AAA", 10, 120)
        a.sell("AAA", 5, 121)
        b.buy("AAA", 4, 119)
        b.buy("AAA", 12, 121)      # khớp lệnh bán 10@120 và 2 của 5@121
        a.cancel(a.orders()[1]["order_id"])
        time.sleep(0.5)
        packets = list(cap.packets)
        cap.close()
        self.assertGreaterEqual(len(packets), 5)

        # phát lại cho một receiver khác nhưng cố ý "làm rơi" 2 gói giữa chừng
        r = FeedReceiver(listen=False, snapshot_fn=b.snapshot)
        for p in packets[:1] + packets[3:]:
            r.handle_packet(p)
        self.assertTrue(r.gaps)
        self.assertGreaterEqual(r.resyncs, 1)
        self.assertTrue(r.valid)
        server = b.book("AAA")
        self.assertEqual(r.book.levels("AAA"), (server["bids"], server["asks"]))
        snap = b.snapshot()
        self.assertEqual(snap["seq"], struct.unpack(">Q", packets[-1][:8])[0])  # snapshot gắn đúng seq cuối của feed
        a.close()
        b.close()

    # ---- giao thức nhị phân kiểu OUCH (dùng mã AAA; test nào cũng dọn lệnh còn nằm lại) ----

    def test_ouch_order_flow_alongside_json(self):
        o, j = OuchClient("ouch_a", port=PORT), ExchangeClient("ouch_j", port=PORT)
        j.sell("AAA", 10, 230)
        j.wait("exec", match=lambda m: m["text"] == "accepted")

        o.enter("T1", "B", 4, "AAA", 230)                      # khớp 4 với lệnh bán JSON
        seq_a, a = o.wait("A", "T1")
        seq_e, e = o.wait("E", "T1")
        self.assertEqual((a["side"], a["qty"], a["symbol"], a["price"]), ("B", 4, "AAA", 230))
        self.assertEqual((e["qty"], e["price"]), (4, 230))
        self.assertEqual((seq_a, seq_e), (1, 2))               # số thứ tự liên tục từ 1
        fill = j.wait("exec", match=lambda m: m["last_qty"] > 0)
        self.assertEqual(fill["match"], e["match_no"])         # hai bên thấy CÙNG số khớp lệnh

        o.enter("T2", "B", 10 ** 6, "AAA", 10 ** 6)            # vượt tiền
        self.assertEqual(o.wait("J", "T2")[1]["reason"], "R")
        o.enter("T3", "B", 5, "AAA", 100)                      # nằm chờ rồi huỷ
        o.wait("A", "T3")
        o.cancel("T3")
        self.assertEqual(o.wait("C", "T3")[1]["reason"], "U")
        o.cancel("NOPE")
        self.assertEqual(o.wait("J", "NOPE")[1]["reason"], "N")
        o.enter("T4", "B", 6, "AAA", 230)                      # mua nốt phần còn lại để dọn sổ
        o.wait("E", "T4")
        self.assertEqual([s for s, _ in o.history], list(range(1, len(o.history) + 1)))
        o.close()
        j.close()

    def test_ouch_reconnect_replays_reports_and_dedups_orders(self):
        o, j = OuchClient("ouch_r", port=PORT), ExchangeClient("ouch_rj", port=PORT)
        o.enter("R1", "S", 10, "AAA", 240)
        o.wait("A", "R1")
        o.disconnect()                                         # rớt mạng đột ngột

        j.buy("AAA", 4, 240)                                   # lệnh R1 bị khớp khi client đang offline
        j.wait("exec", match=lambda m: m["last_qty"] > 0)

        o.reconnect()                                          # xin phát lại từ next_seq
        seq, e = o.wait("E", "R1")
        self.assertEqual((seq, e["qty"]), (2, 4))              # báo cáo bị lỡ được phát lại, đúng số thứ tự
        self.assertFalse(o.session_changed)

        o.enter("R1", "S", 10, "AAA", 240)                     # gửi lại cùng token: không được tạo lệnh trùng
        o.enter("R2", "S", 7, "AAA", 241)
        o.disconnect()                                         # ngắt NGAY, không biết R2 đã tới sàn chưa
        o.reconnect()
        o.enter("R2", "S", 7, "AAA", 241)                      # gửi lại cho chắc
        time.sleep(0.5)

        a_tokens = [ev["token"] for _, ev in o.history if ev["type"] == "A"]
        self.assertEqual(sorted(a_tokens), ["R1", "R2"])       # mỗi token được chấp nhận đúng một lần
        asks = dict((px, q) for px, q in j.book("AAA")["asks"])
        self.assertEqual((asks.get(240), asks.get(241)), (6, 7))  # 10 - 4 còn lại; không bị nhân đôi
        self.assertEqual([s for s, _ in o.history], list(range(1, len(o.history) + 1)))
        o.cancel("R1")
        o.cancel("R2")
        o.wait("C", "R2")
        o.close()
        j.close()

    def test_ouch_heartbeat_keeps_alive_and_silent_client_dropped(self):
        silent = socket.create_connection(("127.0.0.1", PORT))
        silent.sendall(ouch.login("ouch_silent", 1))           # đăng nhập nhưng không gửi heartbeat
        alive = OuchClient("ouch_hb", port=PORT, heartbeat=0.5)
        time.sleep(4.5)                                        # > idle timeout 3 giây của server test
        silent.settimeout(2)
        data = b""
        while True:
            chunk = silent.recv(4096)
            if not chunk:
                break
            data += chunk
        self.assertIn(b"A", data[:3])                          # đã nhận 'A' (đăng nhập) rồi bị server ngắt
        self.assertTrue(alive.alive)
        alive.enter("H1", "B", 1, "AAA", 50)                   # vẫn dùng được
        self.assertEqual(alive.wait("A", "H1")[1]["price"], 50)
        alive.cancel("H1")
        alive.wait("C", "H1")
        silent.close()
        alive.close()

    def test_ouch_login_rejected_for_future_sequence(self):
        with self.assertRaises(ConnectionRefusedError):
            OuchClient("ouch_new_user", port=PORT, next_seq=99)

    def test_reject_and_bad_input(self):
        c = ExchangeClient("carol", port=PORT)
        c.buy("CCC", 10 ** 6, 10 ** 6)
        self.assertEqual(c.wait("exec")["text"], "insufficient cash")
        c.sock.sendall(b"not json\n")
        self.assertEqual(c.wait("error")["text"], "bad json")


if __name__ == "__main__":
    unittest.main()
