"""Sinh vector cho rtl/tb_ouch.v: lệnh ngẫu nhiên + byte mong đợi do GOLDEN (client/ouch.py) mã hoá.

Ghi vào rtl/sim/:
  ouch_vec.mem   : từ 0 = số bản ghi; mỗi bản ghi 5 từ 64 bit
                   w0 {kind 'O'/'X', side 'B'/'S', market 0/1, ...}  w1 token[0:8]  w2 token[8:14]  w3 symbol  w4 {qty, price}
  ouch_bytes.mem : mọi byte của mọi gói (mỗi dòng 1 byte hex), nối tiếp theo thứ tự bản ghi
"""
import os
import random
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "client"))
import ouch  # noqa: E402

SIM = os.path.join(ROOT, "rtl", "sim")
ALNUM = "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_"


def main(n_orders=3000, n_cancels=1000, seed=11):
    rnd = random.Random(seed)
    recs, data = [], bytearray()

    def edge(bits):  # thỉnh thoảng lấy giá trị biên của trường 32 bit
        return rnd.choice([0, 1, 0xFFFFFFFF, 0x80000000, 0x01020304]) if rnd.random() < 0.15 else rnd.getrandbits(bits)

    for i in range(n_orders + n_cancels):
        cancel = i % 4 == 3 and i // 4 < n_cancels
        token = "".join(rnd.choice(ALNUM) for _ in range(rnd.randint(1, 14)))  # độ dài thay đổi => phần đệm khoảng trắng đổi
        sym = rnd.choice(["AAA", "BBB", "CCC", "X", "ABCDEFGH", "ZZ9"])
        side = rnd.choice("BS")
        market = rnd.random() < 0.2
        qty, price = edge(32), (0 if market else edge(32))
        if cancel:
            msg = ouch.cancel_order(token)
        else:
            msg = ouch.enter_order(token, side, qty, sym, price, "M" if market else "L")
        data += ouch.unsequenced(msg)
        t = ouch.pad(token, ouch.TOKEN)
        recs.append([(ord("X" if cancel else "O") << 56) | (ord(side) << 48) | (int(market) << 40),
                     int.from_bytes(t[:8], "big"), int.from_bytes(t[8:], "big"),
                     int.from_bytes(ouch.pad(sym, 8), "big"), (qty << 32) | price])

    os.makedirs(SIM, exist_ok=True)
    with open(os.path.join(SIM, "ouch_vec.mem"), "w") as f:
        f.write(f"{len(recs):016x}\n" + "".join(f"{w:016x}\n" for rec in recs for w in rec))
    with open(os.path.join(SIM, "ouch_bytes.mem"), "w") as f:
        f.write("".join(f"{b:02x}\n" for b in data))
    print(f"{len(recs)} gói ({n_orders} Enter Order + {sum(r[0] >> 56 == ord('X') for r in recs)} Cancel), {len(data)} byte")


if __name__ == "__main__":
    main()
