// Mã hoá market data kiểu ITCH (rút gọn). Mọi trường có độ dài CỐ ĐỊNH, big-endian ("network order").
// Phần cứng parse bằng cách cắt thẳng bit theo offset, không cần dấu phân cách như '\n' của JSON.
//
//   'A' Add Order       (26 byte)  type[1] order_id[8] side[1] qty[4] symbol[8] price[4]
//   'E' Order Executed  (21 byte)  type[1] order_id[8] qty[4]  match_no[8]
//   'D' Order Delete    ( 9 byte)  type[1] order_id[8]
//
// Một gói UDP = seq[8] + đúng 1 message. Bên nhận chỉ cần các message này để dựng lại sổ lệnh:
//   A  -> thêm lệnh vào sổ        E -> giảm qty của lệnh đang chờ (về 0 thì bỏ)       D -> bỏ lệnh
#pragma once
#include <cstdint>
#include <string>

#include "types.hpp"

namespace itch {

inline void be(std::string& s, uint64_t v, int bytes) {
    for (int i = bytes - 1; i >= 0; --i) s += char((v >> (8 * i)) & 0xFF);
}

inline std::string add_order(uint64_t id, Side side, int64_t qty, const std::string& symbol, int64_t price) {
    std::string s = "A";
    be(s, id, 8);
    s += side == Side::Buy ? 'B' : 'S';
    be(s, (uint64_t)qty, 4);
    std::string sym = symbol.substr(0, 8);
    sym.resize(8, ' ');  // đệm khoảng trắng cho đủ 8 byte
    s += sym;
    be(s, (uint64_t)price, 4);
    return s;
}

inline std::string executed(uint64_t id, int64_t qty, uint64_t match_no) {
    std::string s = "E";
    be(s, id, 8);
    be(s, (uint64_t)qty, 4);
    be(s, match_no, 8);
    return s;
}

inline std::string del(uint64_t id) {
    std::string s = "D";
    be(s, id, 8);
    return s;
}

}  // namespace itch
