"""Terminal giao dịch tương tác.   python client/shell.py <tên> [port]

  buy AAA 10 100        mua 10 AAA giá 100 (limit)
  sell AAA 5 105        bán 5 AAA giá 105
  buy AAA 10            không có giá => lệnh MARKET
  cancel 3              huỷ lệnh có order_id = 3
  book AAA | acct | orders | quit
"""
import sys

sys.stdout.reconfigure(encoding="utf-8")

from exchange_client import ExchangeClient


def show(msg):
    t = msg["type"]
    if t == "exec":
        if msg["last_qty"]:
            print(f"\n  [FILL ] #{msg['order_id']} {msg['side']} {msg['symbol']} {msg['last_qty']}@{msg['last_px']}"
                  f"  ({msg['filled']}/{msg['qty']} {msg['status']})")
        else:
            print(f"\n  [{msg['status']:<5}] #{msg['order_id']} {msg['side']} {msg['symbol']} {msg['qty']}"
                  f"@{msg['price'] or 'MKT'}  {msg['text']}")
    elif t == "error":
        print(f"\n  [ERROR] {msg['text']}")
    elif t == "md_book":
        print(f"\n  {msg['symbol']}  last={msg['last']}")
        for px, q in reversed(msg["asks"]):
            print(f"      ASK {px:>8} x {q}")
        for px, q in msg["bids"]:
            print(f"      BID {px:>8} x {q}")
    elif t == "account":
        print(f"\n  cash={msg['cash']} (khả dụng {msg['avail_cash']})  cổ phiếu={msg['positions']}")
    elif t == "orders":
        for o in msg["orders"]:
            print(f"  #{o['order_id']} {o['side']} {o['symbol']} {o['filled']}/{o['qty']}@{o['price']} {o['status']}")


def main():
    user = sys.argv[1] if len(sys.argv) > 1 else "alice"
    port = int(sys.argv[2]) if len(sys.argv) > 2 else 9000
    c = ExchangeClient(user, port=port)
    c.on_message = show
    print(__doc__ + f"\nĐã đăng nhập: {user}. Mã: {', '.join(c.symbols)}")
    while True:
        try:
            parts = input(f"{user}> ").split()
        except (EOFError, KeyboardInterrupt):
            break
        if not parts:
            continue
        cmd, args = parts[0].lower(), parts[1:]
        try:
            if cmd in ("buy", "sell"):
                c.order(args[0].upper(), cmd.upper(), int(args[1]), int(args[2]) if len(args) > 2 else None)
            elif cmd == "cancel":
                c.cancel(int(args[0]))
            elif cmd == "book":
                c.send(type="book", symbol=args[0].upper())
            elif cmd in ("acct", "account"):
                c.send(type="account")
            elif cmd == "orders":
                c.send(type="orders")
            elif cmd in ("quit", "exit"):
                break
            else:
                print("lệnh không hợp lệ")
        except (IndexError, ValueError):
            print("sai cú pháp, xem hướng dẫn phía trên")
    c.close()


if __name__ == "__main__":
    main()
