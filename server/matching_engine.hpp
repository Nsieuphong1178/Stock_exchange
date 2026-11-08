// Matching Engine: giữ một OrderBook cho mỗi mã và định tuyến lệnh tới đúng sổ.
#pragma once
#include <map>

#include "order_book.hpp"

class MatchingEngine {
    std::map<std::string, OrderBook> books_;
public:
    explicit MatchingEngine(const std::vector<std::string>& symbols) {
        for (auto& s : symbols) books_.emplace(s, OrderBook(s));
    }
    OrderBook& book(const std::string& symbol) { return books_.at(symbol); }
    const OrderBook& book(const std::string& symbol) const { return books_.at(symbol); }
    std::vector<Trade> submit(const OrderPtr& o) { return book(o->symbol).match(o); }
    bool cancel(const OrderPtr& o) { return book(o->symbol).cancel(o); }
};
