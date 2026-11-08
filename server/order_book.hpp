// Order Book: lưu lệnh chờ của MỘT mã. Giá tốt nhất ở đầu map; mỗi mức giá là hàng đợi FIFO.
// => ưu tiên giá, rồi ưu tiên thời gian (price-time priority).
#pragma once
#include <algorithm>
#include <deque>
#include <functional>
#include <map>
#include <utility>
#include <vector>

#include "types.hpp"

struct Level { int64_t price, qty; };

class OrderBook {
    using Queue = std::deque<OrderPtr>;
    std::string symbol_;
    std::map<int64_t, Queue, std::greater<int64_t>> bids_;  // giá cao nhất trước
    std::map<int64_t, Queue> asks_;                          // giá thấp nhất trước
    int64_t last_ = 0;

    static void refresh(Order& o) {
        o.status = o.filled == o.qty ? Status::Filled : o.filled > 0 ? Status::Partial : Status::New;
    }

    // Quét phía đối diện cho tới khi hết lệnh hoặc hết giá khớp được.
    template <class Opp>
    void sweep(Opp& opp, const OrderPtr& o, std::vector<Trade>& out) {
        const bool buy = o->side == Side::Buy;
        while (o->remaining() > 0 && !opp.empty()) {
            auto lvl = opp.begin();
            const int64_t px = lvl->first;
            if (o->type == OrdType::Limit && (buy ? o->price < px : o->price > px)) break;
            Queue& q = lvl->second;
            while (o->remaining() > 0 && !q.empty()) {
                OrderPtr r = q.front();  // lệnh chờ lâu nhất ở mức giá này
                const int64_t n = std::min(o->remaining(), r->remaining());
                o->filled += n;
                r->filled += n;
                refresh(*o);
                refresh(*r);
                out.push_back({symbol_, px, n, buy ? o : r, buy ? r : o, o->side});  // giá khớp = giá lệnh chờ
                last_ = px;
                if (r->remaining() == 0) q.pop_front();
            }
            if (q.empty()) opp.erase(lvl);
        }
    }

    template <class Book>
    static void erase_from(Book& book, const OrderPtr& o) {
        auto it = book.find(o->price);
        if (it == book.end()) return;
        auto& q = it->second;
        q.erase(std::remove(q.begin(), q.end(), o), q.end());
        if (q.empty()) book.erase(it);
    }

    template <class Book>
    static std::vector<Level> levels(const Book& b, size_t n) {
        std::vector<Level> v;
        for (auto& [px, q] : b) {
            if (v.size() >= n) break;
            int64_t tot = 0;
            for (auto& o : q) tot += o->remaining();
            v.push_back({px, tot});
        }
        return v;
    }

public:
    explicit OrderBook(std::string symbol) : symbol_(std::move(symbol)) {}

    // Khớp lệnh mới với sổ. Lệnh LIMIT còn dư sẽ nằm chờ; MARKET còn dư bị huỷ.
    std::vector<Trade> match(const OrderPtr& o) {
        std::vector<Trade> trades;
        if (o->side == Side::Buy) sweep(asks_, o, trades); else sweep(bids_, o, trades);
        if (o->remaining() > 0) {
            if (o->type == OrdType::Limit) {
                if (o->side == Side::Buy) bids_[o->price].push_back(o); else asks_[o->price].push_back(o);
            } else {
                o->status = Status::Cancelled;
            }
        }
        return trades;
    }

    bool cancel(const OrderPtr& o) {
        if (!o->active()) return false;
        if (o->side == Side::Buy) erase_from(bids_, o); else erase_from(asks_, o);
        o->status = Status::Cancelled;
        return true;
    }

    // Mọi lệnh đang chờ (mua rồi bán), để tạo snapshot cho client khôi phục sau khi mất gói feed
    std::vector<OrderPtr> resting() const {
        std::vector<OrderPtr> v;
        for (auto& [px, q] : bids_) v.insert(v.end(), q.begin(), q.end());
        for (auto& [px, q] : asks_) v.insert(v.end(), q.begin(), q.end());
        return v;
    }

    int64_t best_bid() const { return bids_.empty() ? 0 : bids_.begin()->first; }
    int64_t best_ask() const { return asks_.empty() ? 0 : asks_.begin()->first; }
    int64_t last() const { return last_; }
    std::vector<Level> bid_levels(size_t n) const { return levels(bids_, n); }
    std::vector<Level> ask_levels(size_t n) const { return levels(asks_, n); }

    // Ước tính chi phí mua `qty` ở giá thị trường: trả {tổng tiền, số lượng mua được}.
    std::pair<int64_t, int64_t> market_buy_cost(int64_t qty) const {
        int64_t cost = 0, got = 0;
        for (auto& [px, q] : asks_) {
            for (auto& o : q) {
                if (got >= qty) return {cost, got};
                int64_t n = std::min(qty - got, o->remaining());
                cost += n * px;
                got += n;
            }
        }
        return {cost, got};
    }
};
