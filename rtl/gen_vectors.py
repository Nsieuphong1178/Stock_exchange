"""Sinh vector kiểm thử cho rtl/tb_parser.v từ DỮ LIỆU THẬT của server C++.

1. Chạy server, thực hiện một kịch bản giao dịch, bắt các gói UDP multicast (seq + message ITCH).
2. Bọc mỗi gói vào khung Ethernet/IPv4/UDP đầy đủ (checksum IP đúng, đệm tới 60 byte như MAC thật).
3. Chèn thêm các khung LỖI cố ý (sai ethertype, sai checksum, cụt...) để thử đường loại khung.
4. Ghi rtl/sim/frames.mem (đầu vào cho DUT) và rtl/sim/expected.mem (golden: kết quả decode mong đợi).

Bộ decode "golden" là client/feed_receiver.py (Python), độc lập với bản Verilog.
"""
import os
import random
import struct
import subprocess
import sys
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "client"))
from exchange_client import ExchangeClient  # noqa: E402
from feed_receiver import FeedReceiver, decode  # noqa: E402

SIM = os.path.join(ROOT, "rtl", "sim")
EXE = os.path.join(ROOT, "build", "exchange_server.exe" if os.name == "nt" else "exchange_server")
PORT = 9150
DROP = {3, 4, 8}   # chỉ số gói bị "làm rơi" khỏi luồng đưa vào DUT
DUPLICATE = 6      # chỉ số gói bị gửi hai lần

# phải khớp localparam R_* trong eth_udp_itch_parser.v
R_ETHERTYPE, R_IP_HDR, R_PROTO, R_IP_CSUM, R_DST_IP, R_DST_PORT, R_LEN, R_MSG_TYPE, R_TRUNC = range(1, 10)


class Capture(FeedReceiver):
    """Giữ nguyên gói UDP thô thay vì decode."""

    def __init__(self):
        self.packets = []
        super().__init__()

    def handle_packet(self, pkt):
        self.packets.append(pkt)


def capture_real_packets():
    proc = subprocess.Popen([EXE, str(PORT)], cwd=os.path.join(ROOT, "build"), stderr=subprocess.DEVNULL)
    try:
        for _ in range(50):
            try:
                ExchangeClient("probe", port=PORT).close()
                break
            except OSError:
                time.sleep(0.1)
        cap = Capture()
        time.sleep(0.3)
        a, b = ExchangeClient("gv_a", port=PORT), ExchangeClient("gv_b", port=PORT)
        for sym, px, q in (("CCC", 100, 10), ("CCC", 100, 5), ("CCC", 101, 7), ("BBB", 500, 3)):
            a.sell(sym, q, px)                      # -> A
        for px, q in ((99, 8), (98, 4)):
            b.buy("CCC", q, px)                     # -> A
        b.buy("CCC", 12, 100)                       # -> E, E
        a.sell("CCC", 3, 98)                        # -> E (khớp với 8@99)
        b.buy("BBB", 5)                             # lệnh market -> E
        a.cancel(a.orders()[1]["order_id"])         # -> D
        time.sleep(0.5)
        packets = list(cap.packets)
        cap.close()
        seqs = [struct.unpack(">Q", p[:8])[0] for p in packets]
        assert seqs == list(range(seqs[0], seqs[0] + len(seqs))), "bắt thiếu gói UDP trong lúc sinh vector"
        return packets
    finally:
        proc.kill()


def ip_checksum(header):
    s = sum(struct.unpack(">10H", header))
    while s >> 16:
        s = (s & 0xFFFF) + (s >> 16)
    return ~s & 0xFFFF


def build_frame(payload, *, ethertype=0x0800, ver_ihl=0x45, proto=17, dst_ip=(239, 1, 1, 1),
                dst_port=30001, udp_len_delta=0, bad_csum=False, vlan=False):
    udp = struct.pack(">HHHH", 40000, dst_port, 8 + len(payload) + udp_len_delta, 0)  # UDP checksum = 0 (cho phép)
    total = 20 + len(udp) + len(payload)

    def ip(csum):
        return struct.pack(">BBHHHBBH4s4s", ver_ihl, 0, total, 0, 0, 1, proto, csum,
                           bytes((10, 0, 0, 1)), bytes(dst_ip))
    csum = ip_checksum(ip(0))
    hdr = ip(csum ^ 0x1234 if bad_csum else csum)
    eth = bytes((0x01, 0x00, 0x5E, 0x01, 0x01, 0x01)) + bytes((0x02, 0, 0, 0, 0, 1))
    if vlan:   # thẻ 802.1Q: TPID 0x8100 + TCI (ưu tiên 3, VLAN 100), rồi EtherType thật
        eth += struct.pack(">HH", 0x8100, (3 << 13) | 100)
    eth += struct.pack(">H", ethertype)
    frame = eth + hdr + udp + payload
    return frame.ljust(60, b"\x00")  # Ethernet tối thiểu 60 byte (chưa tính FCS): message D cần đệm


def expect_msg(payload, gap):
    seq = struct.unpack(">Q", payload[:8])[0]
    m = decode(payload[8:])
    sym = int.from_bytes(m.get("symbol", "").ljust(8).encode() if "symbol" in m else b"\0" * 8, "big")
    w0 = (1 << 56) | (ord(m["type"]) << 48) | (ord(m["side"]) << 40 if "side" in m else 0) | int(gap)
    return [w0, seq, m["order_id"], m.get("match_no", 0), (m.get("qty", 0) << 32) | m.get("price", 0), sym]


def expect_drop(reason):
    return [(2 << 56) | (reason << 32), 0, 0, 0, 0, 0]


def main():
    os.makedirs(SIM, exist_ok=True)
    packets = capture_real_packets()
    kinds = {p[8:9] for p in packets}
    assert {b"A", b"E", b"D"} <= kinds, f"kịch bản chưa sinh đủ A/E/D: {kinds}"

    A = next(p for p in packets if p[8:9] == b"A")
    bad_frames = [  # (khung, lý do mong đợi)
        (build_frame(A, ethertype=0x86DD), R_ETHERTYPE),
        (build_frame(A, ver_ihl=0x46), R_IP_HDR),
        (build_frame(A, proto=6), R_PROTO),
        (build_frame(A, bad_csum=True), R_IP_CSUM),
        (build_frame(A, dst_ip=(239, 1, 1, 2)), R_DST_IP),
        (build_frame(A, dst_port=30002), R_DST_PORT),
        (build_frame(A, udp_len_delta=1), R_LEN),
        (build_frame(A[:8] + b"Z" + A[9:]), R_MSG_TYPE),
        (build_frame(A)[:70], R_TRUNC),   # cụt giữa message
        (build_frame(A)[:20], R_TRUNC),   # cụt giữa IP header
    ]

    rnd = random.Random(1)
    items = []  # (khung, bản ghi mong đợi)
    bad_iter = iter(bad_frames)
    # Mô phỏng mạng không hoàn hảo: làm rơi 3 gói (2 liền nhau + 1 lẻ) và gửi trùng 1 gói.
    # Golden của cờ gap: seq != seq của message hợp lệ trước đó + 1 (gói trùng cũng bị đánh dấu).
    delivered = []
    for i, p in enumerate(packets):
        if i in DROP:
            continue
        delivered.append(p)
        if i == DUPLICATE:
            delivered.append(p)
    exp_seq = None
    for i, p in enumerate(delivered):
        seq = struct.unpack(">Q", p[:8])[0]
        gap = exp_seq is not None and seq != exp_seq
        exp_seq = seq + 1
        items.append((build_frame(p), expect_msg(p, gap)))
        if i % 2 == 1:
            nxt = next(bad_iter, None)
            if nxt:
                items.append((nxt[0], expect_drop(nxt[1])))
    for fr, reason in bad_iter:
        items.append((fr, expect_drop(reason)))

    words = []
    for frame, _ in items:
        for k, byte in enumerate(frame):
            if rnd.random() < 0.03:
                words.append(1 << 9)                 # chu kỳ rảnh giữa khung (valid = 0)
            words.append((1 << 8 if k == len(frame) - 1 else 0) | byte)
        words.extend([1 << 9] * rnd.randint(0, 3))   # khoảng nghỉ giữa các khung

    with open(os.path.join(SIM, "frames.mem"), "w") as f:
        f.write(f"{len(words):08x}\n" + "".join(f"{w:08x}\n" for w in words))
    with open(os.path.join(SIM, "expected.mem"), "w") as f:
        f.write(f"{len(items):016x}\n" + "".join(f"{w:016x}\n" for _, rec in items for w in rec))
    n_gaps = sum(rec[0] & 1 for _, rec in items)
    print(f"{len(packets)} gói thật ({len(DROP)} rơi, 1 trùng, {n_gaps} lần gap) + {len(bad_frames)} khung lỗi "
          f"=> {len(items)} khung, {len(words)} chu kỳ")


if __name__ == "__main__":
    main()
