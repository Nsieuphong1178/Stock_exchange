"""Mã hoá / giải mã giao thức đặt lệnh nhị phân kiểu OUCH (định dạng đầy đủ: xem server/ouch.hpp).

Đây cũng là GOLDEN cho bộ mã hoá RTL (rtl/ouch_encoder.v): RTL phải cho ra đúng từng byte như các hàm ở đây.
"""
import struct

TOKEN = 14


def pad(text, n):
    return text.encode("ascii")[:n].ljust(n, b" ")


def packet(ptype, body=b""):
    """Khung: length[2, big-endian] | type[1] | body, length = 1 + len(body)."""
    return struct.pack(">H", 1 + len(body)) + ptype + body


def login(user, next_seq):
    return packet(b"L", pad(user, 16) + struct.pack(">Q", next_seq))


def enter_order(token, side, qty, symbol, price, ord_type="L"):
    """Message OUCH 'O' (33 byte). side: 'B'/'S'; ord_type: 'L' limit / 'M' market (price bị bỏ qua)."""
    return b"O" + pad(token, TOKEN) + side.encode() + struct.pack(">I", qty) + pad(symbol, 8) + \
        struct.pack(">I", price) + ord_type.encode()


def cancel_order(token):
    """Message OUCH 'X' (15 byte)."""
    return b"X" + pad(token, TOKEN)


def unsequenced(msg):
    """Bọc message OUCH vào gói 'U' để gửi lên server."""
    return packet(b"U", msg)


def decode(body):
    """Giải mã message OUCH server -> client thành dict."""
    kind = chr(body[0])
    token = body[1:1 + TOKEN].decode("ascii").rstrip()
    rest = body[1 + TOKEN:]
    if kind == "A":
        order_id, side, qty, symbol, price = struct.unpack(">QcI8sI", rest)
        return {"type": "A", "token": token, "order_id": order_id, "side": side.decode(), "qty": qty,
                "symbol": symbol.decode().rstrip(), "price": price}
    if kind == "E":
        qty, price, match_no = struct.unpack(">IIQ", rest)
        return {"type": "E", "token": token, "qty": qty, "price": price, "match_no": match_no}
    if kind in ("C", "J"):
        return {"type": kind, "token": token, "reason": chr(rest[0])}
    raise ValueError(f"unknown message {body!r}")
