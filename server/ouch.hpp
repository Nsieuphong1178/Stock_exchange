// Giao thức đặt lệnh nhị phân kiểu OUCH, đóng khung kiểu SoupBinTCP. Mọi trường độ dài cố định, big-endian.
//
// KHUNG (trên TCP):  length[2] | type[1] | payload     (length = 1 + độ dài payload)
//   client -> server:  'L' đăng nhập   'U' dữ liệu không đánh số (message OUCH)   'H' heartbeat   'Z' kết thúc
//   server -> client:  'A' chấp nhận đăng nhập   'J' từ chối   'S' dữ liệu CÓ ĐÁNH SỐ (message OUCH)   'H' heartbeat
//
//   'L' payload: user[16, đệm khoảng trắng] | next_seq[8]     next_seq = số thứ tự message 'S' đầu tiên client muốn
//                nhận (1 = từ đầu; sau khi rớt mạng gửi số kế tiếp chưa nhận được => server phát lại phần còn thiếu)
//   'A' payload: session_id[8] | next_seq[8]                  session_id đổi khi server khởi động lại
//   'J' payload: reason[1]                                    'S' = next_seq vượt quá những gì server đã gửi
//
// MESSAGE OUCH (client -> server, trong gói 'U'):
//   'O' Enter Order : 'O' token[14] side[1:'B'/'S'] qty[4] symbol[8] price[4] type[1:'L'/'M']   = 33 byte
//   'X' Cancel Order: 'X' token[14]                                                              = 15 byte
//   token là mã duy nhất do client đặt cho mỗi lệnh => gửi lại cùng token thì server bỏ qua (không trùng lệnh)
// MESSAGE OUCH (server -> client, trong gói 'S', mỗi cái mang số thứ tự ngầm định 1, 2, 3...):
//   'A' Accepted: 'A' token[14] order_id[8] side[1] qty[4] symbol[8] price[4]                    = 40 byte
//   'E' Executed: 'E' token[14] qty[4] price[4] match_no[8]                                      = 31 byte
//   'C' Canceled: 'C' token[14] reason[1]  ('U' client huỷ, 'I' phần market còn dư)              = 16 byte
//   'J' Rejected: 'J' token[14] reason[1]  ('R' risk, 'Y' mã lạ, 'F' trường sai, 'N' không thấy lệnh,
//                                           'A' lệnh không còn hoạt động, 'O' khác)              = 16 byte
#pragma once
#include <cstdint>
#include <string>

#include "itch.hpp"  // itch::be dùng chung để ghi số big-endian

namespace ouch {

constexpr size_t TOKEN = 14;
constexpr size_t ENTER_LEN = 33, CANCEL_LEN = 15;

inline uint64_t rd(const std::string& s, size_t off, size_t n) {  // đọc số big-endian
    uint64_t v = 0;
    for (size_t i = 0; i < n; ++i) v = (v << 8) | (unsigned char)s[off + i];
    return v;
}
inline std::string pad(const std::string& s, size_t n) {
    std::string r = s.substr(0, n);
    r.resize(n, ' ');
    return r;
}
inline std::string trim(const std::string& s) {
    size_t e = s.find_last_not_of(std::string(" \0", 2));
    return e == std::string::npos ? "" : s.substr(0, e + 1);
}

inline std::string packet(char type, const std::string& body = "") {
    std::string s;
    itch::be(s, 1 + body.size(), 2);
    s += type;
    return s + body;
}

inline std::string accepted(const std::string& token, uint64_t id, char side, int64_t qty, const std::string& symbol,
                            int64_t price) {
    std::string s = "A" + pad(token, TOKEN);
    itch::be(s, id, 8);
    s += side;
    itch::be(s, (uint64_t)qty, 4);
    s += pad(symbol, 8);
    itch::be(s, (uint64_t)price, 4);
    return s;
}
inline std::string executed(const std::string& token, int64_t qty, int64_t price, uint64_t match_no) {
    std::string s = "E" + pad(token, TOKEN);
    itch::be(s, (uint64_t)qty, 4);
    itch::be(s, (uint64_t)price, 4);
    itch::be(s, match_no, 8);
    return s;
}
inline std::string canceled(const std::string& token, char reason) { return "C" + pad(token, TOKEN) + reason; }
inline std::string rejected(const std::string& token, char reason) { return "J" + pad(token, TOKEN) + reason; }

}  // namespace ouch
