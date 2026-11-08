"""Sinh vector cho rtl/tb_book.v: luồng message A/E/D ngẫu nhiên + golden.

Golden là client/feed_receiver.py (BookBuilder, dựng sổ theo từng lệnh bằng dict của Python) cộng một bảng mức giá
cộng dồn riêng để tính giá tốt nhất sau MỖI message. Cuối chạy, hai cách tính phải khớp nhau (tự kiểm tra bộ sinh).

Luồng được thiết kế để làm khó bảng băm của RTL:
  - ~30% order_id cố ý rơi vào cùng một ô băm (cụm xung đột) => chuỗi thăm dò dài
  - xoá và thêm liên tục => nhiều tombstone, phải dùng lại và đi xuyên qua chúng
Cuối luồng có các message LỖI cố ý (lệnh không tồn tại, giá ngoài cửa sổ, mã lạ, khớp quá số lượng...):
RTL phải báo đúng mã lỗi và KHÔNG làm đổi trạng thái sổ.

Ghi vào rtl/sim/: book_msgs.mem (đầu vào + kỳ vọng từng message), book_final.mem (toàn bộ bảng mức giá cuối cùng).
Với --frames còn ghi pipe_frames.mem + pipe_expect.mem: cùng chuỗi message nhưng bọc thành khung Ethernet/IP/UDP
(xen vài khung lỗi) để thử cả chuỗi parser -> FIFO -> book.
Với --t2t còn ghi t2t_expect.mem + t2t_bytes.mem: GOLDEN của cả chuỗi tick-to-trade (chiến lược + risk + mã hoá lệnh),
tính từ giá tốt nhất sau mỗi message mà chính bộ sinh này đã ghi trong book_msgs.mem.
"""
import os
import random
import struct
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "client"))
from feed_receiver import BookBuilder  # noqa: E402

SIM = os.path.join(ROOT, "rtl", "sim")
SYMS = ["AAA", "BBB", "CCC"]
ORDER_BITS = 11
MASK = (1 << ORDER_BITS) - 1
MAX_LIVE = 800                # < 2048 ô: tải tối đa ~40%
# mã lỗi, khớp itch_book.v
E_SYMBOL, E_PRICE, E_UNKNOWN_ORDER, E_OVER_EXEC, E_FIELD = 1, 2, 4, 5, 6


def sym_int(s):
    return int.from_bytes(s.ljust(8).encode(), "big") if s else 0


# Cấu hình chuỗi tick-to-trade: PHẢI khớp tham số truyền cho tick_to_trade trong rtl/tb_t2t.v
T2T = dict(sym=0, buy_below=500, sell_above=3700, qty=10,
           max_qty=1000, min_px=100, max_px=3900, max_notional=38000, max_pos=2000)
R_QTY, R_PRICE, R_NOTIONAL, R_EXPOSURE = 2, 3, 4, 5   # mã lý do của pretrade_risk.v


def golden_t2t(recs):
    """Mô hình tham chiếu: chiến lược ngưỡng + risk + mã hoá lệnh, áp lên giá tốt nhất sau mỗi message thành công."""
    import ouch
    c = T2T
    buy_exp = sell_exp = 0
    orders, rejects = [], {r: 0 for r in range(1, 7)}
    for i, rec in enumerate(recs):
        w0 = rec[0]
        if (w0 >> 40) & 0xFF != 0 or (w0 >> 32) & 0xFF != c["sym"]:
            continue                                    # message lỗi, hoặc không đụng tới mã của chiến lược
        bid_px, _, ask_px, _ = rec[4:8]
        if ask_px and ask_px <= c["buy_below"]:
            buy, price = True, ask_px
        elif bid_px and bid_px >= c["sell_above"]:
            buy, price = False, bid_px
        else:
            continue
        qty = c["qty"]
        exposure = (buy_exp if buy else sell_exp) + qty
        if qty == 0 or qty > c["max_qty"]:
            reason = R_QTY
        elif price < c["min_px"] or price > c["max_px"]:
            reason = R_PRICE
        elif price * qty > c["max_notional"]:
            reason = R_NOTIONAL
        elif exposure > c["max_pos"]:
            reason = R_EXPOSURE
        else:
            reason = 0
        if reason:
            rejects[reason] += 1
            continue
        if buy:
            buy_exp = exposure
        else:
            sell_exp = exposure
        token = f"FPGA{len(orders):08X}  "              # giống tick_to_trade.v: "FPGA" + 8 hex + 2 khoảng trắng
        pkt = ouch.unsequenced(ouch.enter_order(token, "B" if buy else "S", qty, SYMS[c["sym"]], price, "L"))
        orders.append((i, pkt))
    return orders, rejects


def write_t2t(recs):
    orders, rejects = golden_t2t(recs)
    with open(os.path.join(SIM, "t2t_expect.mem"), "w") as f:
        f.write(f"{len(orders):016x}\n" + "".join(f"{rejects[r]:016x}\n" for r in range(1, 7)) +
                "".join(f"{i:016x}\n" for i, _ in orders))
    with open(os.path.join(SIM, "t2t_bytes.mem"), "w") as f:
        f.write("".join(f"{b:02x}\n" for _, pkt in orders for b in pkt))
    print(f"  + tick-to-trade: {len(orders)} lệnh phát ra, loại: " +
          ", ".join(f"{name}={rejects[r]}" for r, name in ((2, "QTY"), (3, "PRICE"), (4, "NOTIONAL"), (5, "EXPOSURE"))))


def encode(msg, seq, match_no):
    """Gói UDP (seq + message ITCH) đúng định dạng server/itch.hpp."""
    typ, side, oid, qty, px, symbol = msg
    if typ == "A":
        body = struct.pack(">cQcI8sI", b"A", oid, side.encode(), qty, symbol.ljust(8).encode(), px)
    elif typ == "E":
        body = struct.pack(">cQIQ", b"E", oid, qty, match_no)
    else:
        body = struct.pack(">cQ", b"D", oid)
    return struct.pack(">Q", seq) + body


def write_frames(msgs, n_book_errors):
    from gen_vectors import build_frame  # cùng thư mục rtl/
    rnd = random.Random(5)
    words, n_drop = [], 0
    bad_kinds = [dict(bad_csum=True), dict(dst_port=30002), dict(dst_ip=(239, 1, 1, 9)), dict(proto=6)]

    def put(frame):
        for k, byte in enumerate(frame):
            if rnd.random() < 0.01:
                words.append(1 << 9)                     # chu kỳ rảnh giữa khung
            words.append((1 << 8 if k == len(frame) - 1 else 0) | byte)
        words.extend([1 << 9] * rnd.randint(0, 3))       # khoảng nghỉ giữa các khung

    for i, m in enumerate(msgs):
        if i % 100 == 99:                                # cứ 100 message chèn một khung lỗi: phải bị loại, không ảnh hưởng sổ
            put(build_frame(encode(m, i + 1, i + 1), **bad_kinds[(i // 100) % len(bad_kinds)]))
            n_drop += 1
        put(build_frame(encode(m, i + 1, i + 1)))
    with open(os.path.join(SIM, "pipe_frames.mem"), "w") as f:
        f.write("".join(f"{w:03x}\n" for w in words))
    with open(os.path.join(SIM, "pipe_expect.mem"), "w") as f:
        f.write(f"{len(words):08x}\n{len(msgs):08x}\n{n_drop:08x}\n{n_book_errors:08x}\n")
    print(f"  + {len(msgs)} khung hợp lệ, {n_drop} khung lỗi, {len(words)} chu kỳ")


def main(n=100_000, seed=7, frames=False, t2t=False, data_only=False, cluster_p=0.30):
    rnd = random.Random(seed)
    book = BookBuilder()
    lv = {(s, side): {} for s in range(3) for side in "BS"}  # (mã, bên) -> {giá: tổng qty}
    live = {}        # order_id -> [mã, bên, giá, qty còn lại]
    live_ids = []    # để chọn ngẫu nhiên O(1)
    mid = [rnd.randint(500, 3500) for _ in SYMS]
    uniq = 0
    clusters = [rnd.randint(0, MASK) for _ in range(16)]
    recs = []        # mỗi phần tử: danh sách 8 từ 64 bit
    msgs = []        # (loại, bên, order_id, qty, giá, mã) theo đúng thứ tự, để bọc thành khung
    counts = {"A": 0, "E": 0, "D": 0}
    peak = 0

    def best(s):
        b, a = lv[(s, "B")], lv[(s, "S")]
        bp = max(b) if b else 0
        ap = min(a) if a else 0
        return bp, b.get(bp, 0), ap, a.get(ap, 0)

    def emit(typ, side, oid, qty, px, symbol, exp_sym, exp_err):
        w0 = (ord(typ) << 56) | ((ord(side) if side else 0) << 48) | (exp_err << 40) | (exp_sym << 32)
        recs.append([w0, oid, (qty << 32) | px, sym_int(symbol), *best(exp_sym)])
        msgs.append((typ, side, oid, qty, px, symbol))

    def fold(x):  # giống hàm hash trong itch_book.v: xor các đoạn ORDER_BITS bit của 64 bit
        h = 0
        while x:
            h ^= x & MASK
            x >>= ORDER_BITS
        return h

    def new_id():
        nonlocal uniq
        uniq += 1
        upper = uniq << (2 * ORDER_BITS)             # phần cao, khác nhau cho mỗi ID => ID luôn phân biệt
        if rnd.random() < cluster_p:  # cụm xung đột: chọn lo để cả ID băm ra đúng ô `target`
            m = rnd.randint(0, MASK)
            target = rnd.choice(clusters)
            low = (m << ORDER_BITS) | (target ^ m ^ fold(upper))
        else:
            low = rnd.getrandbits(2 * ORDER_BITS)
        oid = upper | low
        return oid

    def level_add(s, side, px, q):
        d = lv[(s, side)]
        d[px] = d.get(px, 0) + q

    def level_sub(s, side, px, q):
        d = lv[(s, side)]
        d[px] -= q
        if d[px] == 0:
            del d[px]

    for _ in range(n):
        r = rnd.random()
        if len(live_ids) < 50 or (r < 0.45 and len(live_ids) < MAX_LIVE):
            s = rnd.randrange(3)
            side = rnd.choice("BS")
            mid[s] = min(3800, max(300, mid[s] + rnd.randint(-2, 2)))
            if rnd.random() < 0.10:
                px = rnd.randint(1, 4095)               # xa giá
            else:
                d = rnd.randint(1, 30)
                px = mid[s] - d if side == "B" else mid[s] + d
            qty = rnd.randint(1, 500)
            oid = new_id()
            live[oid] = [s, side, px, qty]
            live_ids.append(oid)
            level_add(s, side, px, qty)
            book.apply({"type": "A", "order_id": oid, "side": side, "qty": qty, "symbol": SYMS[s], "price": px})
            emit("A", side, oid, qty, px, SYMS[s], s, 0)
            counts["A"] += 1
        else:
            i = rnd.randrange(len(live_ids))
            oid = live_ids[i]
            s, side, px, rem = live[oid]
            if r < 0.75 and rem > 1:                    # khớp một phần
                q = rnd.randint(1, rem - 1)
                live[oid][3] -= q
                level_sub(s, side, px, q)
                book.apply({"type": "E", "order_id": oid, "qty": q})
                emit("E", "", oid, q, 0, "", s, 0)
                counts["E"] += 1
                continue
            if r < 0.87:                                # khớp hết => lệnh biến mất
                level_sub(s, side, px, rem)
                book.apply({"type": "E", "order_id": oid, "qty": rem})
                emit("E", "", oid, rem, 0, "", s, 0)
                counts["E"] += 1
            else:                                       # huỷ
                level_sub(s, side, px, rem)
                book.apply({"type": "D", "order_id": oid})
                emit("D", "", oid, 0, 0, "", s, 0)
                counts["D"] += 1
            live_ids[i] = live_ids[-1]
            live_ids.pop()
            del live[oid]
        peak = max(peak, len(live_ids))

    # ---- tự kiểm tra bộ sinh: hai cách tính sổ phải khớp nhau ----
    for s in range(3):
        bids, asks = book.levels(SYMS[s], depth=10 ** 9)
        assert bids == [[p, q] for p, q in sorted(lv[(s, "B")].items(), reverse=True)], "golden lệch (bids)"
        assert asks == [[p, q] for p, q in sorted(lv[(s, "S")].items())], "golden lệch (asks)"

    # ---- message lỗi cố ý: kỳ vọng mã lỗi và trạng thái không đổi ----
    some = live_ids[0]
    es, eside, epx, erem = live[some]
    errors = [
        ("E", "", (999 << 44) | 1, 5, 0, "", E_UNKNOWN_ORDER),          # khớp lệnh không tồn tại
        ("D", "", (998 << 44) | 7, 0, 0, "", E_UNKNOWN_ORDER),          # huỷ lệnh không tồn tại
        ("A", "B", (997 << 44) | 3, 10, 4096, "AAA", E_PRICE),          # giá ngoài cửa sổ
        ("A", "S", (996 << 44) | 3, 10, 0, "BBB", E_PRICE),             # giá 0
        ("A", "B", (995 << 44) | 3, 10, 100, "ZZZ", E_SYMBOL),          # mã lạ
        ("A", "X", (994 << 44) | 3, 10, 100, "AAA", E_FIELD),           # bên không hợp lệ
        ("A", "B", (993 << 44) | 3, 0, 100, "AAA", E_FIELD),            # qty = 0
        ("E", "", some, erem + 1, 0, "", E_OVER_EXEC),                  # khớp nhiều hơn phần còn lại
    ]
    for typ, side, oid, qty, px, sym, code in errors:
        exp_sym = es if typ == "E" and code == E_OVER_EXEC else (SYMS.index(sym) if sym in SYMS else 0)
        emit(typ, side, oid, qty, px, sym, exp_sym, code)
    # lệnh `some` vẫn còn nguyên => kiểm tra bằng một message hợp lệ cuối cùng khớp đúng phần còn lại
    level_sub(es, eside, epx, erem)
    book.apply({"type": "E", "order_id": some, "qty": erem})
    emit("E", "", some, erem, 0, "", es, 0)

    if data_only:   # cho gen_vectors64.py: chỉ cần chuỗi message + golden, không ghi file
        return recs, msgs, len(errors), lv
    os.makedirs(SIM, exist_ok=True)
    with open(os.path.join(SIM, "book_msgs.mem"), "w") as f:
        f.write(f"{len(recs):016x}\n" + "".join(f"{w:016x}\n" for rec in recs for w in rec))
    with open(os.path.join(SIM, "book_final.mem"), "w") as f:
        for s in range(3):
            for side in "SB":                           # bit bên: 0 = bán, 1 = mua (khớp {mã, bên, giá} của RTL)
                d = lv[(s, side)]
                f.write("".join(f"{d.get(p, 0):08x}\n" for p in range(4096)))
    if frames:
        write_frames(msgs, len(errors))
    if t2t:
        write_t2t(recs)
    print(f"{len(recs)} message ({counts['A']} A, {counts['E']} E, {counts['D']} D, {len(errors)} lỗi cố ý), "
          f"tối đa {peak} lệnh sống cùng lúc")
    return recs, msgs, len(errors), lv


if __name__ == "__main__":
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    main(int(args[0]) if args else 100_000, frames="--frames" in sys.argv, t2t="--t2t" in sys.argv)
