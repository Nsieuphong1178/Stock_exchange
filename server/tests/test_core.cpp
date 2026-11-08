// Unit test không cần framework: dùng CHECK đơn giản. Chạy: build/test_core
#include <cstdio>
#include <vector>

#include "../exchange_core.hpp"
#include "../ouch.hpp"

static int fails = 0;
#define CHECK(c) do { if (!(c)) { std::printf("FAIL %s:%d  %s\n", __FILE__, __LINE__, #c); ++fails; } } while (0)

struct Harness {
    std::vector<std::pair<std::string, json::Msg>> out;  // (user, message)
    std::vector<std::string> feed;                       // message nhị phân ITCH
    ExchangeCore core{{"AAA"}, [this](auto& u, auto& m) { json::Msg x; json::parse(m, x); out.push_back({u, x}); },
                      [](auto&, auto&) {}, [this](auto& m) { feed.push_back(m); }};
    void send(const std::string& user, const std::string& line) {
        json::Msg m;
        CHECK(json::parse(line, m));
        core.handle(user, m);
    }
    void order(const std::string& u, const char* side, int64_t qty, int64_t px) {
        send(u, std::string("{\"type\":\"new\",\"symbol\":\"AAA\",\"side\":\"") + side + "\",\"qty\":" +
                    std::to_string(qty) + ",\"price\":" + std::to_string(px) + "}");
    }
    void market(const std::string& u, const char* side, int64_t qty) {
        send(u, std::string("{\"type\":\"new\",\"symbol\":\"AAA\",\"side\":\"") + side +
                    "\",\"ord_type\":\"MARKET\",\"qty\":" + std::to_string(qty) + "}");
    }
    int64_t cash(const std::string& u) { return core.account(u).cash; }
    int64_t pos(const std::string& u) { return core.account(u).pos["AAA"]; }
    OrderBook& book() { return core.engine().book("AAA"); }
};

static void test_basic_match() {
    Harness h;
    h.order("bob", "SELL", 10, 100);
    CHECK(h.book().best_ask() == 100);
    h.order("alice", "BUY", 4, 100);
    CHECK(h.pos("alice") == 1004 && h.cash("alice") == 10'000'000 - 400);
    CHECK(h.pos("bob") == 996 && h.cash("bob") == 10'000'000 + 400);
    CHECK(h.book().ask_levels(1)[0].qty == 6);
}

static void test_price_improvement() {  // mua giá 105 nhưng khớp ở giá lệnh chờ 100, tiền dư được nhả
    Harness h;
    h.order("bob", "SELL", 5, 100);
    h.order("alice", "BUY", 5, 105);
    CHECK(h.cash("alice") == 10'000'000 - 500);
    CHECK(h.core.account("alice").reserved_cash == 0);
}

static void test_price_time_priority() {
    Harness h;
    h.order("first", "SELL", 5, 100);
    h.order("second", "SELL", 5, 100);
    h.order("cheap", "SELL", 5, 99);
    h.order("buyer", "BUY", 12, 100);  // 5@99 (cheap) -> 5@100 (first) -> 2@100 (second)
    CHECK(h.pos("cheap") == 995 && h.pos("first") == 995 && h.pos("second") == 998);
}

static void test_no_cross_rests() {
    Harness h;
    h.order("a", "BUY", 5, 99);
    h.order("b", "SELL", 5, 101);
    CHECK(h.book().best_bid() == 99 && h.book().best_ask() == 101 && h.book().last() == 0);
}

static void test_market_order() {
    Harness h;
    h.order("bob", "SELL", 3, 100);
    h.order("bob", "SELL", 3, 110);
    h.market("alice", "BUY", 10);  // chỉ có 6 -> khớp 6, 4 còn lại bị huỷ
    CHECK(h.pos("alice") == 1006 && h.cash("alice") == 10'000'000 - 300 - 330);
    CHECK(h.core.account("alice").reserved_cash == 0);
    CHECK(h.book().best_ask() == 0);
}

static void test_cancel_releases() {
    Harness h;
    h.order("alice", "BUY", 10, 100);
    CHECK(h.core.account("alice").reserved_cash == 1000);
    h.send("alice", R"({"type":"cancel","order_id":1})");
    CHECK(h.core.account("alice").reserved_cash == 0 && h.book().best_bid() == 0);
    h.send("bob", R"({"type":"cancel","order_id":1})");  // lệnh đã huỷ / không phải của bob
    CHECK(h.out.back().second.str("type") == "error");
}

static void test_risk_rejects() {
    Harness h;
    h.order("alice", "BUY", 1000000, 100);  // cần 100M, chỉ có 10M
    CHECK(h.out.back().second.str("status") == "REJECTED");
    h.order("alice", "SELL", 1001, 100);  // chỉ có 1000 cổ phiếu
    CHECK(h.out.back().second.str("text") == "insufficient shares");
    h.order("alice", "SELL", 1000, 100);
    h.order("alice", "SELL", 1, 100);  // 1000 đã bị phong toả
    CHECK(h.out.back().second.str("status") == "REJECTED");
    h.order("alice", "BUY", 1, 0);
    CHECK(h.out.back().second.str("text") == "invalid price");
    h.market("zed", "BUY", 1);  // sổ không có lệnh bán nào... (alice bán 1000@100 nên có)
}

static void test_conservation() {  // tổng tiền và tổng cổ phiếu của cả sàn không đổi sau nhiều lệnh
    Harness h;
    const char* users[] = {"u1", "u2", "u3"};
    for (int i = 0; i < 300; ++i) {
        h.order(users[i % 3], i % 2 ? "BUY" : "SELL", 1 + i % 7, 95 + (i * 7) % 11);
        if (i % 25 == 0) h.market(users[(i + 1) % 3], i % 2 ? "SELL" : "BUY", 5);
    }
    int64_t cash = 0, pos = 0;
    for (auto u : users) { cash += h.cash(u); pos += h.pos(u); }
    CHECK(cash == 3 * 10'000'000 && pos == 3 * 1000);
}

static void test_feed_messages() {
    Harness h;
    h.order("bob", "SELL", 10, 100);  // lệnh #1 nằm chờ  -> A
    h.order("alice", "BUY", 4, 100);  // khớp 4 với #1, alice hết lệnh -> E (không có A)
    h.send("bob", R"({"type":"cancel","order_id":1})");  // -> D
    CHECK(h.feed.size() == 3);
    CHECK(h.feed[0].size() == 26 && h.feed[0][0] == 'A');
    CHECK(h.feed[0] == std::string("A\0\0\0\0\0\0\0\x01" "S" "\0\0\0\x0a" "AAA     " "\0\0\0\x64", 26));  // big-endian
    CHECK(h.feed[1].size() == 21 && h.feed[1][0] == 'E');
    CHECK(h.feed[1] == std::string("E\0\0\0\0\0\0\0\x01" "\0\0\0\x04" "\0\0\0\0\0\0\0\x01", 21));
    CHECK(h.feed[2] == std::string("D\0\0\0\0\0\0\0\x01", 9));
}

static void test_ouch_encoding() {
    // Accepted: 'A' token[14] order_id[8] side qty[4] symbol[8] price[4] = 40 byte, big-endian
    const std::string a = ouch::accepted("T1", 5, 'B', 10, "AAA", 100);
    CHECK(a.size() == 40);
    CHECK(a == std::string("AT1            \0\0\0\0\0\0\0\x05" "B" "\0\0\0\x0a" "AAA     " "\0\0\0\x64", 40));
    // Executed 31 byte, Canceled/Rejected 16 byte
    CHECK(ouch::executed("T1", 4, 100, 7) ==
          std::string("ET1            \0\0\0\x04" "\0\0\0\x64" "\0\0\0\0\0\0\0\x07", 31));
    CHECK(ouch::canceled("T1", 'U') == "CT1            U");
    CHECK(ouch::rejected("T1", 'R') == "JT1            R");
    // khung: length[2] type payload, length = 1 + payload
    CHECK(ouch::packet('S', a).substr(0, 3) == std::string("\0\x29" "S", 3));
    CHECK(ouch::packet('H') == std::string("\0\x01" "H", 3));
    CHECK(ouch::trim(std::string("T1            ", 14)) == "T1" && ouch::trim("   ") == "");
    CHECK(ouch::rd(std::string("\x01\x02\x03\x04", 4), 0, 4) == 0x01020304);
}

int main() {
    Logger::get().open("test.log", false);
    test_ouch_encoding();
    test_feed_messages();
    test_basic_match();
    test_price_improvement();
    test_price_time_priority();
    test_no_cross_rests();
    test_market_order();
    test_cancel_releases();
    test_risk_rejects();
    test_conservation();
    std::printf(fails ? "%d FAILED\n" : "all tests passed\n", fails);
    return fails ? 1 : 0;
}
