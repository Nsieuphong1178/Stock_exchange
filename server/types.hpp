// Kiểu dữ liệu cốt lõi dùng chung cho mọi module.
#pragma once
#include <cstdint>
#include <memory>
#include <string>

enum class Side { Buy, Sell };
enum class OrdType { Limit, Market };
enum class Status { New, Partial, Filled, Cancelled, Rejected };

inline const char* to_str(Side s) { return s == Side::Buy ? "BUY" : "SELL"; }
inline const char* to_str(OrdType t) { return t == OrdType::Limit ? "LIMIT" : "MARKET"; }
inline const char* to_str(Status s) {
    switch (s) {
        case Status::New: return "NEW";
        case Status::Partial: return "PARTIAL";
        case Status::Filled: return "FILLED";
        case Status::Cancelled: return "CANCELLED";
        case Status::Rejected: return "REJECTED";
    }
    return "?";
}

// Giá là số nguyên (đơn vị nhỏ nhất, vd đồng) -> tránh sai số số thực.
struct Order {
    uint64_t id = 0;  // tăng dần => cũng là thứ tự thời gian
    std::string owner, symbol, cid;  // cid: mã lệnh do client tự đặt
    Side side = Side::Buy;
    OrdType type = OrdType::Limit;
    int64_t qty = 0, price = 0, filled = 0;
    Status status = Status::New;
    int64_t reserved = 0;  // tiền đã phong toả (lệnh mua), do Risk Engine quản lý
    bool released = false;  // đã nhả phong toả còn dư chưa (chỉ nhả đúng 1 lần)

    int64_t remaining() const { return qty - filled; }
    bool active() const { return status == Status::New || status == Status::Partial; }
};
using OrderPtr = std::shared_ptr<Order>;

struct Trade {
    std::string symbol;
    int64_t price, qty;
    OrderPtr buy, sell;
    Side aggressor;  // bên chủ động (lệnh mới đến)
};
