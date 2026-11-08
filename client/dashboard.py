"""Dashboard terminal: theo dõi market data realtime.   python client/dashboard.py [mã] [port]"""
import sys

sys.stdout.reconfigure(encoding="utf-8")
import time

from exchange_client import ExchangeClient


def main():
    symbol = sys.argv[1].upper() if len(sys.argv) > 1 else "AAA"
    port = int(sys.argv[2]) if len(sys.argv) > 2 else 9000
    c = ExchangeClient("dashboard", port=port)
    c.subscribe(symbol)
    book, trades = None, []
    last_draw = 0
    while True:
        try:
            m = c.inbox.get(timeout=1)
        except Exception:
            m = None
        if m and m["type"] == "md_book":
            book = m
        elif m and m["type"] == "md_trade":
            trades = (trades + [m])[-10:]
        if book and time.time() - last_draw > 0.1:
            last_draw = time.time()
            out = ["\x1b[2J\x1b[H", f"  {symbol}   last={book['last']}   bid={book['bid']}   ask={book['ask']}\n\n"]
            for px, q in reversed(book["asks"][:8]):
                out.append(f"\x1b[31m   ASK {px:>8} {q:>8} {'#' * min(q // 5, 40)}\x1b[0m\n")
            out.append("   ------------------------\n")
            for px, q in book["bids"][:8]:
                out.append(f"\x1b[32m   BID {px:>8} {q:>8} {'#' * min(q // 5, 40)}\x1b[0m\n")
            out.append("\n  Giao dịch gần nhất:\n")
            for t in reversed(trades):
                out.append(f"    {t['qty']:>6} @ {t['price']}  ({t['aggressor']})\n")
            sys.stdout.write("".join(out))
            sys.stdout.flush()


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        pass
