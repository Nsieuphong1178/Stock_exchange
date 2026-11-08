// Risk Engine: kiểm tra điều kiện TRƯỚC khi lệnh vào matching engine, và thanh toán SAU khi khớp.
// - Lệnh mua: phong toả tiền (giá * khối lượng). Lệnh bán: phong toả cổ phiếu (không bán khống).
// - Khớp xong: chuyển tiền/cổ phiếu thật, nhả phần phong toả.
#pragma once
#include <map>
#include <optional>
#include <string>
#include <vector>

#include "order_book.hpp"
#include "types.hpp"

struct Account {
    int64_t cash = 0, reserved_cash = 0;
    std::map<std::string, int64_t> pos, reserved_pos;
    int64_t avail_cash() const { return cash - reserved_cash; }
    int64_t avail_pos(const std::string& s) const {
        auto p = pos.find(s);
        auto r = reserved_pos.find(s);
        return (p == pos.end() ? 0 : p->second) - (r == reserved_pos.end() ? 0 : r->second);
    }
};

struct RiskLimits {
    int64_t max_qty = 1'000'000;
    int64_t max_price = 1'000'000'000;
    int64_t initial_cash = 10'000'000;
    int64_t initial_shares = 1'000;  // mỗi mã, để mới vào là có thể thử bán ngay
};

class RiskEngine {
    std::map<std::string, Account> accounts_;
    std::vector<std::string> symbols_;
    RiskLimits lim_;
public:
    RiskEngine(std::vector<std::string> symbols, RiskLimits lim = {}) : symbols_(std::move(symbols)), lim_(lim) {}

    bool known_symbol(const std::string& s) const {
        for (auto& x : symbols_) if (x == s) return true;
        return false;
    }

    Account& account(const std::string& user) {
        auto [it, created] = accounts_.try_emplace(user);
        if (created) {
            it->second.cash = lim_.initial_cash;
            for (auto& s : symbols_) it->second.pos[s] = lim_.initial_shares;
        }
        return it->second;
    }

    // Trả về lý do từ chối, hoặc nullopt nếu OK (đã phong toả tài sản).
    std::optional<std::string> check_and_reserve(Order& o, const OrderBook& book) {
        if (!known_symbol(o.symbol)) return "unknown symbol";
        if (o.qty <= 0 || o.qty > lim_.max_qty) return "invalid qty";
        if (o.type == OrdType::Limit && (o.price <= 0 || o.price > lim_.max_price)) return "invalid price";
        Account& a = account(o.owner);
        if (o.side == Side::Buy) {
            int64_t need;
            if (o.type == OrdType::Limit) {
                need = o.price * o.qty;
            } else {
                auto [cost, got] = book.market_buy_cost(o.qty);
                if (got == 0) return "no liquidity";
                need = cost;
            }
            if (need > a.avail_cash()) return "insufficient cash";
            a.reserved_cash += need;
            o.reserved = need;
        } else {
            if (o.qty > a.avail_pos(o.symbol)) return "insufficient shares";
            a.reserved_pos[o.symbol] += o.qty;
        }
        return std::nullopt;
    }

    // Thanh toán một giao dịch cho cả hai bên.
    void settle(const Trade& t) {
        Account& b = account(t.buy->owner);
        Account& s = account(t.sell->owner);
        const int64_t value = t.price * t.qty;
        // người mua: trừ tiền thật, nhả phong toả theo giá lệnh (limit) hoặc giá khớp (market)
        const int64_t unit = t.buy->type == OrdType::Limit ? t.buy->price : t.price;
        b.cash -= value;
        b.reserved_cash -= unit * t.qty;
        t.buy->reserved -= unit * t.qty;
        b.pos[t.symbol] += t.qty;
        // người bán: nhận tiền, trừ cổ phiếu
        s.cash += value;
        s.pos[t.symbol] -= t.qty;
        s.reserved_pos[t.symbol] -= t.qty;
    }

    // Lệnh đã kết thúc (khớp hết / huỷ): nhả phần phong toả còn dư.
    void release(Order& o) {
        if (o.active() || o.released) return;
        o.released = true;
        Account& a = account(o.owner);
        if (o.side == Side::Buy) {
            a.reserved_cash -= o.reserved;
            o.reserved = 0;
        } else {
            a.reserved_pos[o.symbol] -= o.remaining();
        }
    }
};
