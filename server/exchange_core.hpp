// ExchangeCore: nối các module lại thành một pipeline, KHÔNG biết gì về socket (dễ unit test).
//
//   request ──> Risk Engine ──> OMS ──> Matching Engine/Order Book ──┬─> Execution Report (tới từng chủ lệnh)
//                (phong toả)  (tạo ID)   (khớp lệnh)                 └─> Market Data (phát cho người theo dõi)
#pragma once
#include <functional>
#include <string>

#include "itch.hpp"
#include "json.hpp"
#include "logger.hpp"
#include "matching_engine.hpp"
#include "oms.hpp"
#include "risk_engine.hpp"

class ExchangeCore {
public:
    using ToUser = std::function<void(const std::string& user, const std::string& msg)>;
    using ToMarket = std::function<void(const std::string& symbol, const std::string& msg)>;
    using ToFeed = std::function<void(const std::string& itch_msg)>;  // message nhị phân kiểu ITCH

    ExchangeCore(std::vector<std::string> symbols, ToUser to_user, ToMarket to_market, ToFeed to_feed)
        : symbols_(symbols), engine_(symbols), risk_(symbols), to_user_(std::move(to_user)),
          to_market_(std::move(to_market)), to_feed_(std::move(to_feed)) {}

    const std::vector<std::string>& symbols() const { return symbols_; }

    void handle(const std::string& user, const json::Msg& m) {
        const std::string type = m.str("type");
        if (type == "new") new_order(user, m);
        else if (type == "cancel") cancel_order(user, m);
        else if (type == "book") send_book(user, m.str("symbol"));
        else if (type == "account") send_account(user);
        else if (type == "orders") send_orders(user);
        else error(user, "unknown type '" + type + "'");
    }

    // ---- Market Data ----
    std::string md_book(const std::string& symbol) const {
        const OrderBook& b = engine_.book(symbol);
        return json::Writer().str("type", "md_book").str("symbol", symbol).num("bid", b.best_bid())
            .num("ask", b.best_ask()).num("last", b.last()).raw("bids", levels_json(b.bid_levels(10)))
            .raw("asks", levels_json(b.ask_levels(10))).done();
    }
    // Snapshot mọi lệnh đang chờ, gắn với `feed_seq` = seq của gói feed cuối đã phát. Vì server đơn luồng nên
    // trạng thái này khớp CHÍNH XÁC với feed tới seq đó: client áp tiếp từ feed_seq + 1 là đủ.
    std::string snapshot_json(uint64_t feed_seq) const {
        std::string arr = "[";
        for (auto& s : symbols_)
            for (auto& o : engine_.book(s).resting()) {
                if (arr.size() > 1) arr += ',';
                arr += "[" + std::to_string(o->id) + ",\"" + (o->side == Side::Buy ? "B" : "S") + "\"," +
                       std::to_string(o->price) + "," + std::to_string(o->remaining()) + ",\"" + o->symbol + "\"]";
            }
        return json::Writer().str("type", "snapshot").num("seq", (int64_t)feed_seq).raw("orders", arr + "]").done();
    }
    bool known_symbol(const std::string& s) const { return risk_.known_symbol(s); }
    Account& account(const std::string& user) { return risk_.account(user); }
    MatchingEngine& engine() { return engine_; }

private:
    std::vector<std::string> symbols_;
    MatchingEngine engine_;
    RiskEngine risk_;
    OMS oms_;
    ToUser to_user_;
    ToMarket to_market_;
    ToFeed to_feed_;
    uint64_t match_no_ = 0;

    static std::string levels_json(const std::vector<Level>& v) {
        std::string s = "[";
        for (size_t i = 0; i < v.size(); ++i) {
            if (i) s += ',';
            s += "[" + std::to_string(v[i].price) + "," + std::to_string(v[i].qty) + "]";
        }
        return s + "]";
    }

    void error(const std::string& user, const std::string& text) {
        to_user_(user, json::Writer().str("type", "error").str("text", text).done());
    }

    // ---- Execution Report ----
    void exec(const Order& o, const std::string& text = "", int64_t last_px = 0, int64_t last_qty = 0,
              uint64_t match = 0) {
        to_user_(o.owner, json::Writer().str("type", "exec").num("order_id", (int64_t)o.id).str("cid", o.cid)
            .str("symbol", o.symbol).str("side", to_str(o.side)).str("ord_type", to_str(o.type))
            .str("status", to_str(o.status)).num("qty", o.qty).num("price", o.price).num("filled", o.filled)
            .num("last_px", last_px).num("last_qty", last_qty).num("match", (int64_t)match).str("text", text).done());
    }

    void new_order(const std::string& user, const json::Msg& m) {
        const std::string s_side = m.str("side"), s_type = m.str("ord_type", "LIMIT");
        if ((s_side != "BUY" && s_side != "SELL") || (s_type != "LIMIT" && s_type != "MARKET"))
            return error(user, "bad side/ord_type");

        OrderPtr o = oms_.create(user, m.str("symbol"), s_side == "BUY" ? Side::Buy : Side::Sell,
                                 s_type == "LIMIT" ? OrdType::Limit : OrdType::Market, m.num("qty"),
                                 m.num("price"), m.str("cid"));
        LOG_INFO("NEW   #" + std::to_string(o->id) + " " + user + " " + to_str(o->side) + " " + o->symbol + " " +
                 std::to_string(o->qty) + "@" + (o->type == OrdType::Limit ? std::to_string(o->price) : "MKT"));

        // 1) Risk
        if (!known_symbol(o->symbol)) {  // chưa có sổ cho mã này nên không thể kiểm tra tiếp
            o->status = Status::Rejected;
            LOG_WARN("REJECT #" + std::to_string(o->id) + " unknown symbol");
            return exec(*o, "unknown symbol");
        }
        if (auto why = risk_.check_and_reserve(*o, engine_.book(o->symbol))) {
            o->status = Status::Rejected;
            LOG_WARN("REJECT #" + std::to_string(o->id) + " " + *why);
            return exec(*o, *why);
        }
        exec(*o, "accepted");  // ack: trạng thái NEW

        // 2) Matching
        auto trades = engine_.submit(o);

        // 3) Thanh toán + Execution Report + Market Data
        for (auto& t : trades) {
            risk_.settle(t);
            LOG_INFO("TRADE " + t.symbol + " " + std::to_string(t.qty) + "@" + std::to_string(t.price) + " buy#" +
                     std::to_string(t.buy->id) + " sell#" + std::to_string(t.sell->id));
            const uint64_t mno = ++match_no_;  // số khớp lệnh: cả hai bên và feed ITCH cùng thấy một số
            exec(*t.buy, "", t.price, t.qty, mno);
            exec(*t.sell, "", t.price, t.qty, mno);
            to_market_(t.symbol, json::Writer().str("type", "md_trade").str("symbol", t.symbol)
                .num("price", t.price).num("qty", t.qty).str("aggressor", to_str(t.aggressor)).done());
            // Feed nhị phân chỉ báo lệnh ĐANG CHỜ (passive) được khớp; lệnh chủ động chưa từng nằm trong sổ
            const Order& resting = t.aggressor == Side::Buy ? *t.sell : *t.buy;
            to_feed_(itch::executed(resting.id, t.qty, mno));
        }
        // Nhả phong toả sau khi đã thanh toán hết (release tự bỏ qua lệnh còn active / đã nhả)
        for (auto& t : trades) { risk_.release(*t.buy); risk_.release(*t.sell); }
        risk_.release(*o);
        if (o->status == Status::Cancelled) exec(*o, "unfilled remainder cancelled");  // MARKET còn dư
        if (o->active()) to_feed_(itch::add_order(o->id, o->side, o->remaining(), o->symbol, o->price));  // phần dư nằm chờ
        to_market_(o->symbol, md_book(o->symbol));
    }

    void cancel_order(const std::string& user, const json::Msg& m) {
        OrderPtr o = oms_.find((uint64_t)m.num("order_id"));
        if (!o || o->owner != user) return error(user, "order not found");
        if (!engine_.cancel(o)) return error(user, "order not active");
        risk_.release(*o);
        LOG_INFO("CANCEL #" + std::to_string(o->id) + " " + user);
        exec(*o, "cancelled");
        to_feed_(itch::del(o->id));
        to_market_(o->symbol, md_book(o->symbol));
    }

    void send_book(const std::string& user, const std::string& symbol) {
        if (!known_symbol(symbol)) return error(user, "unknown symbol");
        to_user_(user, md_book(symbol));
    }

    void send_account(const std::string& user) {
        Account& a = risk_.account(user);
        std::string pos = "{";
        for (auto& s : symbols_) {
            if (pos.size() > 1) pos += ',';
            pos += "\"" + s + "\":" + std::to_string(a.pos[s]);
        }
        pos += "}";
        to_user_(user, json::Writer().str("type", "account").str("user", user).num("cash", a.cash)
            .num("avail_cash", a.avail_cash()).raw("positions", pos).done());
    }

    void send_orders(const std::string& user) {
        std::string arr = "[";
        for (auto& o : oms_.orders_of(user)) {
            if (arr.size() > 1) arr += ',';
            arr += json::Writer().num("order_id", (int64_t)o->id).str("symbol", o->symbol).str("side", to_str(o->side))
                       .str("ord_type", to_str(o->type)).num("qty", o->qty).num("price", o->price)
                       .num("filled", o->filled).str("status", to_str(o->status)).done();
        }
        to_user_(user, json::Writer().str("type", "orders").raw("orders", arr + "]").done());
    }
};
