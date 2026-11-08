"""Sinh vector cho datapath 64 bit.   python rtl/gen_vectors64.py [parser|pipeline|stress]

  parser   : 20.000 message, mỗi gói 1..4 message, có/không VLAN, gói heartbeat (count = 0, cần đệm), RƠI gói, GỬI TRÙNG gói,
             khung lỗi header, lỗi GIỮA gói (loại message lạ, count nhỏ hơn thực tế) và khung cụt.
             => p64_frames.mem + p64_expect.mem (so TỪNG sự kiện)
  pipeline : 100.009 message của bộ sinh sổ lệnh (gen_book_vectors) đóng gói, xen ~1% khung lỗi header, qua parser64 -> FIFO -> book.
             => p64_pipe_frames.mem + p64_pipe_expect.mem; bảng mức giá cuối là book_final.mem (cùng bộ sinh)
  linerate : như pipeline nhưng khung liên tục không nghỉ và order_id không cố ý xung đột: book có theo kịp tốc độ đường truyền?
  stress   : 1.000.000 message ngẫu nhiên (tới 8 message / gói, có lỗi) so bằng BĂM CUỘN của mọi sự kiện thay vì từng bản ghi
             (file mong đợi mà từng sự kiện sẽ rất lớn). => p64_stress_frames.mem + p64_stress_expect.mem

Từ luồng 74 bit {idle[73], last[72], keep[71:64], data[63:0]}; byte ĐẦU TIÊN của khung nằm ở data[7:0] (như AXI-Stream của MAC).
Golden của sự kiện: logic Python ở đây, độc lập với Verilog (message dựng bằng gen_book_vectors.encode, định dạng như server/itch.hpp).
"""
import os
import random
import struct
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "rtl"))
sys.path.insert(0, os.path.join(ROOT, "client"))
import gen_book_vectors as gb  # noqa: E402
from gen_vectors import build_frame  # noqa: E402

SIM = os.path.join(ROOT, "rtl", "sim")
IDLE = 1 << 73
R_ETHERTYPE, R_IP_HDR, R_PROTO, R_IP_CSUM, R_DST_IP, R_DST_PORT, R_LEN, R_MSG_TYPE, R_TRUNC = range(1, 10)
HDR_FAULTS = [  # lỗi ở header: cả khung bị loại, không message nào được phát
    (dict(ethertype=0x86DD), R_ETHERTYPE),
    (dict(ver_ihl=0x46), R_IP_HDR),
    (dict(proto=6), R_PROTO),
    (dict(bad_csum=True), R_IP_CSUM),
    (dict(dst_ip=(239, 1, 1, 9)), R_DST_IP),
    (dict(dst_port=30002), R_DST_PORT),
    (dict(udp_len_delta=1), R_LEN),
]
M64 = (1 << 64) - 1
FNV_PRIME = 0x100000001B3


def body(msg, match_no):
    return gb.encode(msg, 0, match_no)[8:]   # message ITCH không kèm seq


def payload(seq, bodies, count=None):
    """MoldUDP64 rút gọn: seq[8] | count[2] | { len[2] | message } x count."""
    c = len(bodies) if count is None else count
    return struct.pack(">QH", seq, c) + b"".join(struct.pack(">H", len(b)) + b for b in bodies)


class Stream:
    """Tích luỹ khung thành các từ 64 bit và sự kiện mong đợi; theo dõi seq mong đợi y như RTL (kể cả khi khung lỗi giữa chừng)."""

    def __init__(self, rnd, idle_p, gap_max, keep_events=True):
        self.rnd, self.idle_p, self.gap_max, self.keep = rnd, idle_p, gap_max, keep_events
        self.words, self.events, self.exp_seq, self.n_events, self.hash = [], [], None, 0, 0xCBF29CE484222325

    def add_frame(self, frame):
        for k in range(0, len(frame), 8):
            chunk = frame[k:k + 8]
            last = k + 8 >= len(frame)
            while self.rnd.random() < self.idle_p:
                self.words.append(IDLE)                  # chu kỳ rảnh GIỮA khung
            self.words.append(int.from_bytes(chunk.ljust(8, b"\0"), "little")
                              | (((1 << len(chunk)) - 1) << 64) | (int(last) << 72))
        self.words.extend([IDLE] * self.rnd.randint(0, self.gap_max))   # khoảng nghỉ giữa các khung

    def _event(self, rec, whole):
        self.n_events += 1
        if self.keep:
            self.events.append(rec)
        for w in (rec if whole else rec[:1]):            # băm: message hết 6 từ, drop chỉ từ đầu
            self.hash = ((self.hash ^ w) * FNV_PRIME) & M64

    def msg(self, seq, m, match_no):
        typ, side, oid, qty, px, symbol = m
        gap = int(self.exp_seq is not None and seq != self.exp_seq)
        self.exp_seq = seq + 1
        if typ == "A":
            q, p, mt, sym = qty, px, 0, int.from_bytes(symbol.ljust(8).encode(), "big")
        elif typ == "E":
            q, p, mt, sym = qty, 0, match_no, 0
        else:
            q = p = mt = sym = 0
        w0 = (1 << 56) | (ord(typ) << 48) | ((ord(side) if side else 0) << 40) | gap
        self._event([w0, seq, oid, mt, (q << 32) | p, sym], True)

    def drop(self, reason):
        self._event([(2 << 56) | (reason << 32), 0, 0, 0, 0, 0], False)


def build(msgs, rnd, *, packet_faults, hdr_fault_p, idle_p, gap_max, max_per_packet=4, keep_events=True):
    st = Stream(rnd, idle_p, gap_max, keep_events)
    pos, seq, mctr = 0, 1, 0
    n_hdr_faults = 0
    while pos < len(msgs):
        if rnd.random() < 0.02:   # heartbeat MoldUDP64: count = 0; ngắn nên bị đệm tới 60 byte
            st.add_frame(build_frame(payload(seq, []), vlan=rnd.random() < 0.25))
        n = min(rnd.randint(1, max_per_packet), len(msgs) - pos)
        group = msgs[pos:pos + n]
        bodies, mnos = [], []
        for m in group:
            mctr += 1
            mnos.append(mctr)
            bodies.append(body(m, mctr))
        vlan = rnd.random() < 0.25

        if rnd.random() < hdr_fault_p:   # khung lỗi header (xen trước gói thật), dựng từ chính payload này
            n_hdr_faults += 1
            if rnd.random() < 0.15:
                frame = build_frame(payload(seq, bodies), vlan=vlan)[:rnd.choice([5, 20, 30])]   # khung cụt
                st.add_frame(frame)
                st.drop(R_TRUNC)
            else:
                kw, reason = rnd.choice(HDR_FAULTS)
                st.add_frame(build_frame(payload(seq, bodies), vlan=vlan, **kw))
                st.drop(reason)

        kind = None
        if packet_faults:
            r = rnd.random()
            kind = ("drop" if r < 0.02 else "dup" if r < 0.04 else
                    "badtype" if r < 0.07 and n >= 2 else "smallcnt" if r < 0.10 and n >= 2 else None)
        if kind == "drop":                 # gói biến mất trên mạng: seq vẫn tiến => gói sau bị gap
            pass
        elif kind == "badtype":            # message thứ hai bị loại 'Z': message đầu vẫn được phát, rồi khung bị loại
            bad = list(bodies)
            bad[1] = b"Z" + bad[1][1:]
            st.add_frame(build_frame(payload(seq, bad), vlan=vlan))
            st.msg(seq, group[0], mnos[0])
            st.drop(R_MSG_TYPE)
        elif kind == "smallcnt":           # count khai báo nhỏ hơn số record thật: n-1 message được phát, rồi LEN
            st.add_frame(build_frame(payload(seq, bodies, count=n - 1), vlan=vlan))
            for k in range(n - 1):
                st.msg(seq + k, group[k], mnos[k])
            st.drop(R_LEN)
        else:
            for _ in range(2 if kind == "dup" else 1):   # dup: cùng gói gửi hai lần
                st.add_frame(build_frame(payload(seq, bodies), vlan=vlan))
                for k in range(n):
                    st.msg(seq + k, group[k], mnos[k])
        seq += n
        pos += n
    return st, n_hdr_faults


def write_words(path, words):
    with open(path, "w") as f:
        f.write("".join(f"{w:019x}\n" for w in words))


def write_events(path, st, extra_header=()):
    with open(path, "w") as f:
        f.write("".join(f"{h:016x}\n" for h in (len(st.words), st.n_events, *extra_header)))
        f.write("".join(f"{w:016x}\n" for rec in st.events for w in rec))


def random_msgs(n, rnd):
    alnum = "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
    out = []
    for _ in range(n):
        t = rnd.choice("AAEED")
        oid = rnd.getrandbits(64)
        if t == "A":
            out.append(("A", rnd.choice("BS"), oid, rnd.getrandbits(32), rnd.getrandbits(32),
                        "".join(rnd.choice(alnum) for _ in range(rnd.randint(1, 8)))))
        elif t == "E":
            out.append(("E", "", oid, rnd.getrandbits(32), 0, ""))
        else:
            out.append(("D", "", oid, 0, 0, ""))
    return out


def main(mode):
    os.makedirs(SIM, exist_ok=True)
    if mode == "parser":
        _, msgs, _, _ = gb.main(20_000, seed=3, data_only=True)
        st, nf = build(msgs, random.Random(1), packet_faults=True, hdr_fault_p=0.05, idle_p=0.03, gap_max=3)
        write_words(os.path.join(SIM, "p64_frames.mem"), st.words)
        write_events(os.path.join(SIM, "p64_expect.mem"), st)
        print(f"parser64: {len(msgs)} message => {st.n_events} sự kiện ({nf} khung lỗi header xen vào), {len(st.words)} từ")
    elif mode == "linerate":
        # Tốc độ đường truyền LIÊN TỤC (không khoảng nghỉ giữa các khung) và order_id phân bố bình thường (không cụm xung đột)
        _, msgs, n_err, _ = gb.main(100_000, cluster_p=float(os.environ.get("CLUSTER_P", "0")))  # CLUSTER_P=0.3 để thử ca xấu
        st, nf = build(msgs, random.Random(2), packet_faults=False, hdr_fault_p=0.012, idle_p=0.0, gap_max=0,
                       keep_events=False)
        write_words(os.path.join(SIM, "p64_pipe_frames.mem"), st.words)
        with open(os.path.join(SIM, "p64_pipe_expect.mem"), "w") as f:
            f.write(f"{len(st.words):016x}\n{len(msgs):016x}\n{nf:016x}\n{n_err:016x}\n")
        print(f"linerate64: {len(msgs)} message, {nf} khung lỗi header, {len(st.words)} từ, KHÔNG có khoảng nghỉ")
    elif mode == "pipeline":
        _, msgs, n_err, _ = gb.main(100_000)   # ghi cả book_final.mem (bảng mức giá cuối) cho testbench
        st, nf = build(msgs, random.Random(2), packet_faults=False, hdr_fault_p=0.012, idle_p=0.0, gap_max=40,
                       keep_events=False)
        write_words(os.path.join(SIM, "p64_pipe_frames.mem"), st.words)
        with open(os.path.join(SIM, "p64_pipe_expect.mem"), "w") as f:
            f.write(f"{len(st.words):016x}\n{len(msgs):016x}\n{nf:016x}\n{n_err:016x}\n")
        print(f"pipeline64: {len(msgs)} message, {nf} khung lỗi header, {len(st.words)} từ")
    else:
        rnd = random.Random(4)
        msgs = random_msgs(1_000_000, rnd)
        st, nf = build(msgs, rnd, packet_faults=True, hdr_fault_p=0.01, idle_p=0.01, gap_max=2, max_per_packet=8,
                       keep_events=False)
        write_words(os.path.join(SIM, "p64_stress_frames.mem"), st.words)
        with open(os.path.join(SIM, "p64_stress_expect.mem"), "w") as f:
            f.write(f"{len(st.words):016x}\n{st.n_events:016x}\n{st.hash:016x}\n")
        print(f"stress64: {len(msgs)} message => {st.n_events} sự kiện, {len(st.words)} từ, băm {st.hash:016x}")


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "parser")
