"""Unit test cho bộ nhận feed nhị phân (không cần server, không cần mạng)."""
import os
import struct
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "client"))
from feed_receiver import FeedReceiver, decode  # noqa: E402


def add(oid, side, qty, sym, px):
    return struct.pack(">cQcI8sI", b"A", oid, side, qty, sym.ljust(8).encode(), px)


def exe(oid, qty, match):
    return struct.pack(">cQIQ", b"E", oid, qty, match)


def pkt(seq, msg):
    return struct.pack(">Q", seq) + msg


class FeedTest(unittest.TestCase):
    def setUp(self):
        self.r = FeedReceiver(listen=False)

    def test_decode_and_rebuild_book(self):
        r = self.r
        r.handle_packet(pkt(1, add(1, b"S", 10, "AAA", 100)))
        r.handle_packet(pkt(2, add(2, b"S", 5, "AAA", 100)))
        r.handle_packet(pkt(3, add(3, b"B", 7, "AAA", 99)))
        r.handle_packet(pkt(4, exe(1, 4, 1)))          # lệnh 1: 10 -> 6
        self.assertEqual(r.book.levels("AAA"), ([[99, 7]], [[100, 11]]))
        r.handle_packet(pkt(5, exe(1, 6, 2)))          # lệnh 1 hết => bị bỏ
        r.handle_packet(pkt(6, struct.pack(">cQ", b"D", 3)))
        self.assertEqual(r.book.levels("AAA"), ([], [[100, 5]]))
        self.assertTrue(r.valid and not r.gaps)

    def test_gap_detection(self):
        r = self.r
        r.handle_packet(pkt(1, add(1, b"S", 10, "AAA", 100)))
        r.handle_packet(pkt(4, add(2, b"S", 5, "AAA", 101)))  # mất seq 2 và 3
        self.assertEqual(r.gaps, [(2, 4)])
        self.assertFalse(r.valid)

    def test_gap_recovery_with_snapshot(self):
        # snapshot ở seq 3 (cũ hơn gói đang nhận, seq 4): sau khi thay sổ phải áp tiếp gói 4
        snap = {"seq": 3, "orders": [[1, "S", 100, 10, "AAA"], [2, "S", 100, 5, "AAA"], [3, "B", 99, 7, "AAA"]]}
        r = FeedReceiver(listen=False, snapshot_fn=lambda: snap)
        r.handle_packet(pkt(1, add(1, b"S", 10, "AAA", 100)))
        r.handle_packet(pkt(4, exe(1, 4, 1)))          # mất seq 2, 3
        self.assertEqual(r.gaps, [(2, 4)])
        self.assertEqual((r.resyncs, r.valid), (1, True))
        self.assertEqual(r.book.levels("AAA"), ([[99, 7]], [[100, 11]]))  # lệnh 1: 10 - 4 = 6, cộng lệnh 2 = 5
        r.handle_packet(pkt(5, exe(2, 5, 2)))          # tiếp tục bình thường, không gap mới
        self.assertEqual((len(r.gaps), r.book.levels("AAA")), (1, ([[99, 7]], [[100, 6]])))

    def test_packets_covered_by_snapshot_are_ignored(self):
        # snapshot ở seq 5 (mới hơn gói đang nhận): gói 4 đã nằm trong snapshot nên không được áp lần nữa
        snap = {"seq": 5, "orders": [[1, "S", 100, 6, "AAA"]]}
        r = FeedReceiver(listen=False, snapshot_fn=lambda: snap)
        r.handle_packet(pkt(1, add(1, b"S", 10, "AAA", 100)))
        r.handle_packet(pkt(4, exe(1, 4, 1)))          # gap -> snapshot (seq 5) => gói 4 bị bỏ qua
        self.assertEqual(r.book.levels("AAA"), ([], [[100, 6]]))
        r.handle_packet(pkt(5, exe(1, 99, 9)))         # cũng đã nằm trong snapshot
        r.handle_packet(pkt(6, exe(1, 6, 2)))          # gói đầu tiên sau snapshot
        self.assertEqual(r.book.levels("AAA"), ([], []))
        self.assertEqual((len(r.gaps), r.resyncs), (1, 1))

    def test_bad_message(self):
        with self.assertRaises(ValueError):
            decode(b"Zxxxx")


if __name__ == "__main__":
    unittest.main()
