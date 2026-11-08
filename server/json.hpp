// JSON tối giản: chỉ đủ cho object phẳng {"key": "chuỗi" | số}.
// Một message = một dòng JSON kết thúc bằng '\n' (newline-delimited JSON).
// Sau này thay bằng FIX chỉ cần thay file này + Gateway.
#pragma once
#include <cstdint>
#include <cstdlib>
#include <map>
#include <string>

namespace json {

struct Msg {
    std::map<std::string, std::string> kv;
    bool has(const std::string& k) const { return kv.count(k) > 0; }
    std::string str(const std::string& k, const std::string& def = "") const {
        auto it = kv.find(k);
        return it == kv.end() ? def : it->second;
    }
    int64_t num(const std::string& k, int64_t def = 0) const {
        auto it = kv.find(k);
        if (it == kv.end() || it->second.empty()) return def;
        char* end = nullptr;
        long long v = std::strtoll(it->second.c_str(), &end, 10);
        return (end && *end == '\0') ? v : def;
    }
};

inline void skip_ws(const std::string& s, size_t& i) {
    while (i < s.size() && (s[i] == ' ' || s[i] == '\t' || s[i] == '\r' || s[i] == '\n')) ++i;
}

inline bool parse_string(const std::string& s, size_t& i, std::string& out) {
    if (i >= s.size() || s[i] != '"') return false;
    ++i;
    out.clear();
    while (i < s.size() && s[i] != '"') {
        if (s[i] == '\\' && i + 1 < s.size()) {
            ++i;
            switch (s[i]) {
                case 'n': out += '\n'; break;
                case 't': out += '\t'; break;
                default: out += s[i];
            }
        } else {
            out += s[i];
        }
        ++i;
    }
    if (i >= s.size()) return false;
    ++i;
    return true;
}

// Trả false nếu không phải object phẳng hợp lệ.
inline bool parse(const std::string& s, Msg& m) {
    m.kv.clear();
    size_t i = 0;
    skip_ws(s, i);
    if (i >= s.size() || s[i] != '{') return false;
    ++i;
    skip_ws(s, i);
    if (i < s.size() && s[i] == '}') return true;
    while (i < s.size()) {
        skip_ws(s, i);
        std::string key, val;
        if (!parse_string(s, i, key)) return false;
        skip_ws(s, i);
        if (i >= s.size() || s[i] != ':') return false;
        ++i;
        skip_ws(s, i);
        if (i >= s.size()) return false;
        if (s[i] == '"') {
            if (!parse_string(s, i, val)) return false;
        } else if (s[i] == '{' || s[i] == '[') {
            return false;  // không hỗ trợ lồng nhau ở chiều client -> server
        } else {
            size_t st = i;
            while (i < s.size() && s[i] != ',' && s[i] != '}') ++i;
            val = s.substr(st, i - st);
            while (!val.empty() && (val.back() == ' ' || val.back() == '\r')) val.pop_back();
        }
        m.kv[key] = val;
        skip_ws(s, i);
        if (i < s.size() && s[i] == ',') { ++i; continue; }
        if (i < s.size() && s[i] == '}') return true;
        return false;
    }
    return false;
}

inline std::string escape(const std::string& v) {
    std::string o;
    for (char c : v) {
        if (c == '"' || c == '\\') { o += '\\'; o += c; }
        else if (c == '\n') o += "\\n";
        else o += c;
    }
    return o;
}

class Writer {
    std::string s_ = "{";
    bool first_ = true;
    void key(const std::string& k) {
        if (!first_) s_ += ',';
        first_ = false;
        s_ += '"' + escape(k) + "\":";
    }
public:
    Writer& str(const std::string& k, const std::string& v) { key(k); s_ += '"' + escape(v) + '"'; return *this; }
    Writer& num(const std::string& k, int64_t v) { key(k); s_ += std::to_string(v); return *this; }
    Writer& raw(const std::string& k, const std::string& v) { key(k); s_ += v; return *this; }  // mảng/object dựng sẵn
    std::string done() const { return s_ + "}"; }
};

}  // namespace json
