// OMS (Order Management System): tạo lệnh, cấp ID, lưu và tra cứu vòng đời của mọi lệnh.
#pragma once
#include <algorithm>
#include <unordered_map>
#include <vector>

#include "types.hpp"

class OMS {
    uint64_t next_id_ = 1;
    std::unordered_map<uint64_t, OrderPtr> orders_;
public:
    OrderPtr create(std::string owner, std::string symbol, Side side, OrdType type, int64_t qty, int64_t price,
                    std::string cid) {
        auto o = std::make_shared<Order>();
        o->id = next_id_++;
        o->owner = std::move(owner);
        o->symbol = std::move(symbol);
        o->side = side;
        o->type = type;
        o->qty = qty;
        o->price = price;
        o->cid = std::move(cid);
        orders_[o->id] = o;
        return o;
    }
    OrderPtr find(uint64_t id) const {
        auto it = orders_.find(id);
        return it == orders_.end() ? nullptr : it->second;
    }
    std::vector<OrderPtr> orders_of(const std::string& owner) const {
        std::vector<OrderPtr> v;
        for (auto& [id, o] : orders_) if (o->owner == owner) v.push_back(o);
        std::sort(v.begin(), v.end(), [](auto& a, auto& b) { return a->id < b->id; });
        return v;
    }
};
