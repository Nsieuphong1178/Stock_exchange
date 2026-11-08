// Gateway: TCP server. Nhận dòng JSON từ client -> chuyển cho ExchangeCore; đẩy Execution Report
// và Market Data ngược lại cho client. Đơn luồng + select() => không cần khoá, thứ tự lệnh rõ ràng.
#pragma once
#include <algorithm>
#include <chrono>
#include <cstdio>
#include <map>
#include <set>
#include <string>

#ifdef _WIN32
#include <winsock2.h>
#include <ws2tcpip.h>
using sock_t = SOCKET;
static const sock_t BAD_SOCK = INVALID_SOCKET;
inline void close_sock(sock_t s) { closesocket(s); }
#else
#include <arpa/inet.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <sys/select.h>
#include <sys/socket.h>
#include <unistd.h>
using sock_t = int;
static const sock_t BAD_SOCK = -1;
inline void close_sock(sock_t s) { close(s); }
#endif

#include "exchange_core.hpp"
#include "ouch.hpp"

class Gateway {
    enum class Proto { Unknown, Json, Binary };  // nhận diện theo byte đầu tiên: '{' = JSON, còn lại = gói nhị phân (ouch.hpp)
    struct Session {
        Proto proto = Proto::Unknown;
        bool logged_in = false;      // chỉ dùng cho phiên nhị phân
        std::string user, buf;
        std::string out;             // dữ liệu chờ gửi (client đọc chậm thì tích lại ở đây)
        std::chrono::steady_clock::time_point last_rx = std::chrono::steady_clock::now();  // lần cuối nhận được gì từ client
        std::chrono::steady_clock::time_point last_tx = std::chrono::steady_clock::now();  // lần cuối gửi gì cho client
        std::set<std::string> subs;  // mã đang theo dõi market data
    };
    // ---- trạng thái cho người dùng giao thức nhị phân: sống lâu hơn kết nối TCP ----
    std::set<std::string> binary_users_;
    std::map<std::string, std::vector<std::string>> out_log_;  // user -> các message OUCH đã phát (số thứ tự = chỉ số + 1)
    std::map<std::string, std::map<std::string, uint64_t>> tokens_;  // user -> token -> order_id (0 nếu chưa/không có)
    std::string cur_token_;  // token của yêu cầu đang xử lý (để gắn vào lỗi do core báo)
    const uint64_t session_id_ = (uint64_t)std::chrono::system_clock::now().time_since_epoch().count();  // đổi khi server khởi động lại
    static constexpr size_t MAX_OUT = 1 << 20;  // client để tồn quá 1 MB chưa đọc => ngắt
    int idle_timeout_s_ = 10;  // im lặng quá lâu => coi là chết (client phải gửi ping định kỳ)
    std::vector<int64_t> proc_ns_;  // thời gian ExchangeCore xử lý mỗi request (gồm cả việc đẩy kết quả vào socket)
    std::map<sock_t, Session> sessions_;
    std::map<std::string, sock_t> by_user_;
    std::set<sock_t> doomed_;  // client sẽ bị ngắt (dọn ở đầu/cuối vòng lặp, không dọn giữa lúc đang duyệt)
    ExchangeCore core_;

    // Market data nhị phân qua UDP multicast. Mỗi gói: seq[8, big-endian] + 1 message ITCH (xem itch.hpp).
    // UDP không đảm bảo giao đủ hay đúng thứ tự => seq cho bên nhận phát hiện mất gói (gap).
    static constexpr const char* FEED_GROUP = "239.1.1.1";
    static constexpr uint16_t FEED_PORT = 30001;
    sock_t feed_sock_ = BAD_SOCK;
    sockaddr_in feed_addr_{};
    uint64_t feed_seq_ = 1;

    void open_feed() {
        feed_sock_ = ::socket(AF_INET, SOCK_DGRAM, 0);
        feed_addr_.sin_family = AF_INET;
        feed_addr_.sin_port = htons(FEED_PORT);
        inet_pton(AF_INET, FEED_GROUP, &feed_addr_.sin_addr);
        in_addr iface{};
        iface.s_addr = htonl(INADDR_LOOPBACK);  // phát ra loopback: chỉ nhận được trên máy này
        setsockopt(feed_sock_, IPPROTO_IP, IP_MULTICAST_IF, (const char*)&iface, sizeof iface);
        LOG_INFO(std::string("Feed multicast ") + FEED_GROUP + ":" + std::to_string(FEED_PORT));
    }

    void to_feed(const std::string& msg) {
        if (feed_sock_ == BAD_SOCK) return;
        std::string pkt;
        itch::be(pkt, feed_seq_++, 8);
        pkt += msg;
        ::sendto(feed_sock_, pkt.data(), (int)pkt.size(), 0, (const sockaddr*)&feed_addr_, sizeof feed_addr_);
    }

    static void set_nonblocking(sock_t s) {
#ifdef _WIN32
        u_long on = 1;
        ioctlsocket(s, FIONBIO, &on);
#else
        fcntl(s, F_SETFL, fcntl(s, F_GETFL, 0) | O_NONBLOCK);
#endif
    }

    static bool would_block() {
#ifdef _WIN32
        return WSAGetLastError() == WSAEWOULDBLOCK;
#else
        return errno == EAGAIN || errno == EWOULDBLOCK;
#endif
    }

    // Gửi được bao nhiêu thì gửi, phần còn lại giữ trong ses.out chờ socket sẵn sàng ghi.
    void flush(sock_t fd, Session& ses) {
        while (!ses.out.empty()) {
            int n = ::send(fd, ses.out.data(), (int)ses.out.size(), 0);
            if (n > 0) { ses.out.erase(0, (size_t)n); continue; }
            if (!would_block()) doomed_.insert(fd);
            return;
        }
    }

    void send_raw(sock_t s, const std::string& bytes) {
        auto it = sessions_.find(s);
        if (it == sessions_.end() || doomed_.count(s)) return;
        Session& ses = it->second;
        ses.out += bytes;
        ses.last_tx = std::chrono::steady_clock::now();
        if (ses.out.size() > MAX_OUT) {
            LOG_WARN("slow consumer " + (ses.user.empty() ? "(anon)" : ses.user) + ": output backlog > 1MB, disconnecting");
            doomed_.insert(s);
            return;
        }
        flush(s, ses);
    }

    void send_line(sock_t s, const std::string& msg) { send_raw(s, msg + "\n"); }

    void drop_doomed() {
        for (sock_t fd : std::set<sock_t>(doomed_)) drop(fd);
        doomed_.clear();
    }

    void to_user(const std::string& user, const std::string& msg) {
        if (binary_users_.count(user)) return emit_ouch(user, to_ouch(user, msg));
        auto it = by_user_.find(user);
        if (it != by_user_.end()) send_line(it->second, msg);  // user offline: bỏ qua (đã có log)
    }

    // ---- giao thức nhị phân ----

    // Chuyển execution report / lỗi JSON của core thành message OUCH ("" nếu không có gì để báo).
    std::string to_ouch(const std::string& user, const std::string& jmsg) {
        json::Msg m;
        if (!json::parse(jmsg, m)) return "";
        const std::string t = m.str("type");
        if (t == "error") {  // lỗi của yêu cầu đang xử lý (core chỉ báo lỗi kiểu này cho cancel)
            const std::string text = m.str("text");
            return ouch::rejected(cur_token_, text == "order not active" ? 'A' : text == "order not found" ? 'N' : 'O');
        }
        if (t != "exec") return "";
        const std::string token = m.str("cid"), status = m.str("status"), text = m.str("text");
        if (status == "NEW" && text == "accepted") {
            tokens_[user][token] = (uint64_t)m.num("order_id");  // để huỷ lệnh theo token về sau
            return ouch::accepted(token, (uint64_t)m.num("order_id"), m.str("side") == "BUY" ? 'B' : 'S', m.num("qty"),
                                  m.str("symbol"), m.num("price"));
        }
        if (m.num("last_qty") > 0) return ouch::executed(token, m.num("last_qty"), m.num("last_px"), (uint64_t)m.num("match"));
        if (status == "CANCELLED") return ouch::canceled(token, text == "cancelled" ? 'U' : 'I');
        if (status == "REJECTED") {
            char r = 'O';
            if (text == "unknown symbol") r = 'Y';
            else if (text.rfind("insufficient", 0) == 0 || text == "no liquidity") r = 'R';
            else if (text.rfind("invalid", 0) == 0) r = 'F';
            return ouch::rejected(token, r);
        }
        return "";
    }

    // Ghi message vào log của user (để phát lại sau khi rớt mạng) rồi gửi nếu user đang online.
    void emit_ouch(const std::string& user, const std::string& body) {
        if (body.empty()) return;
        auto& log = out_log_[user];
        log.push_back(body);
        auto it = by_user_.find(user);
        if (it == by_user_.end()) return;
        Session& ses = sessions_[it->second];
        if (ses.proto != Proto::Binary || !ses.logged_in) return;  // sẽ được phát lại khi đăng nhập
        send_raw(it->second, ouch::packet('S', body));
    }

    void on_binary_login(sock_t fd, const std::string& body) {
        Session& ses = sessions_[fd];
        const std::string user = body.size() == 24 ? ouch::trim(body.substr(0, 16)) : "";
        if (user.empty()) {
            send_raw(fd, ouch::packet('J', "F"));
            doomed_.insert(fd);
            return;
        }
        uint64_t req = ouch::rd(body, 16, 8);
        if (req == 0) req = 1;
        auto& log = out_log_[user];
        if (req > log.size() + 1) {  // đòi số thứ tự mà server chưa từng phát
            send_raw(fd, ouch::packet('J', "S"));
            doomed_.insert(fd);
            return;
        }
        ses.user = user;
        ses.logged_in = true;
        binary_users_.insert(user);
        by_user_[user] = fd;  // đăng nhập lại => kết nối mới thay kết nối cũ
        std::string a;
        itch::be(a, session_id_, 8);
        itch::be(a, req, 8);
        send_raw(fd, ouch::packet('A', a));
        for (uint64_t s = req; s <= log.size(); ++s) send_raw(fd, ouch::packet('S', log[s - 1]));  // phát lại phần client chưa nhận
        LOG_INFO("LOGIN(binary) " + user + " from seq " + std::to_string(req) + ", replayed " +
                 std::to_string(log.size() + 1 - req));
    }

    void on_ouch(Session& ses, const std::string& m) {
        const std::string& user = ses.user;
        if (m.size() == ouch::ENTER_LEN && m[0] == 'O') {
            const std::string token = ouch::trim(m.substr(1, ouch::TOKEN));
            if (token.empty()) return emit_ouch(user, ouch::rejected("", 'F'));
            auto& toks = tokens_[user];
            if (toks.count(token)) return;  // token đã dùng: lệnh đã được xử lý, kết quả nằm trong log => không tạo lệnh trùng
            toks[token] = 0;
            const char sd = m[15], ot = m[32];
            if ((sd != 'B' && sd != 'S') || (ot != 'L' && ot != 'M')) return emit_ouch(user, ouch::rejected(token, 'F'));
            json::Msg x;
            x.kv = {{"type", "new"}, {"symbol", ouch::trim(m.substr(20, 8))}, {"side", sd == 'B' ? "BUY" : "SELL"},
                    {"ord_type", ot == 'M' ? "MARKET" : "LIMIT"}, {"qty", std::to_string(ouch::rd(m, 16, 4))},
                    {"price", std::to_string(ouch::rd(m, 28, 4))}, {"cid", token}};
            cur_token_ = token;
            run_core(user, x);
            cur_token_.clear();
        } else if (m.size() == ouch::CANCEL_LEN && m[0] == 'X') {
            const std::string token = ouch::trim(m.substr(1, ouch::TOKEN));
            auto& toks = tokens_[user];
            auto it = toks.find(token);
            if (it == toks.end() || it->second == 0) return emit_ouch(user, ouch::rejected(token, 'N'));
            json::Msg x;
            x.kv = {{"type", "cancel"}, {"order_id", std::to_string(it->second)}};
            cur_token_ = token;
            run_core(user, x);
            cur_token_.clear();
        } else {
            emit_ouch(user, ouch::rejected("", 'F'));
        }
    }

    void on_packet(sock_t fd, const std::string& pkt) {
        Session& ses = sessions_[fd];
        const char type = pkt[0];
        const std::string body = pkt.substr(1);
        if (type == 'H') return;
        if (type == 'Z') { doomed_.insert(fd); return; }
        if (type == 'L') return on_binary_login(fd, body);
        if (!ses.logged_in) { doomed_.insert(fd); return; }  // phải đăng nhập trước
        if (type == 'U') on_ouch(ses, body);
    }

    void read_binary(sock_t fd) {
        for (;;) {
            auto it = sessions_.find(fd);
            if (it == sessions_.end() || doomed_.count(fd)) return;
            std::string& buf = it->second.buf;
            if (buf.size() < 2) return;
            const size_t len = ouch::rd(buf, 0, 2);
            if (len == 0 || len > 4096) {
                LOG_WARN("bad packet length " + std::to_string(len) + ", disconnecting");
                doomed_.insert(fd);
                return;
            }
            if (buf.size() < 2 + len) return;  // chưa đủ gói: đợi thêm byte
            const std::string pkt = buf.substr(2, len);
            buf.erase(0, 2 + len);
            on_packet(fd, pkt);
        }
    }

    // Chạy một yêu cầu qua ExchangeCore và ghi lại thời gian xử lý
    void run_core(const std::string& user, const json::Msg& m) {
        const auto t0 = std::chrono::steady_clock::now();
        core_.handle(user, m);
        if (proc_ns_.size() < 1'000'000)
            proc_ns_.push_back(std::chrono::duration_cast<std::chrono::nanoseconds>(
                                   std::chrono::steady_clock::now() - t0).count());
    }

    void to_market(const std::string& symbol, const std::string& msg) {
        for (auto& [fd, ses] : sessions_)
            if (ses.subs.count(symbol)) send_line(fd, msg);
    }

    void on_line(sock_t fd, const std::string& line) {
        Session& ses = sessions_[fd];
        json::Msg m;
        if (!json::parse(line, m)) return send_line(fd, R"({"type":"error","text":"bad json"})");
        const std::string type = m.str("type");

        if (type == "login") {
            std::string user = m.str("user");
            if (user.empty() || user.size() > 32) return send_line(fd, R"({"type":"error","text":"bad user"})");
            ses.user = user;
            by_user_[user] = fd;  // đăng nhập lại => session mới thay session cũ
            LOG_INFO("LOGIN " + user);
            std::string syms = "[";
            for (auto& s : core_.symbols()) syms += (syms.size() > 1 ? ",\"" : "\"") + s + "\"";
            return send_line(fd, json::Writer().str("type", "login_ok").str("user", user).raw("symbols", syms + "]").done());
        }
        if (ses.user.empty()) return send_line(fd, R"({"type":"error","text":"login first"})");
        if (type == "ping") return send_line(fd, R"({"type":"pong"})");
        if (type == "stats") {  // thống kê thời gian xử lý phía server (ns); "reset":1 để xoá và đo lại
            std::vector<int64_t> s = proc_ns_;
            std::sort(s.begin(), s.end());
            auto pct = [&](double p) -> int64_t { return s.empty() ? 0 : s[(size_t)(p * (double)(s.size() - 1))]; };
            send_line(fd, json::Writer().str("type", "stats").num("count", (int64_t)s.size()).num("p50_ns", pct(0.5))
                              .num("p99_ns", pct(0.99)).num("max_ns", s.empty() ? 0 : s.back()).done());
            if (m.num("reset")) proc_ns_.clear();
            return;
        }
        if (type == "snapshot") return send_line(fd, core_.snapshot_json(feed_seq_ - 1));

        if (type == "subscribe" || type == "unsubscribe") {
            std::string sym = m.str("symbol");
            if (!core_.known_symbol(sym)) return send_line(fd, R"({"type":"error","text":"unknown symbol"})");
            if (type == "subscribe") { ses.subs.insert(sym); send_line(fd, core_.md_book(sym)); }
            else ses.subs.erase(sym);
            return;
        }
        run_core(ses.user, m);
    }

    void drop(sock_t fd) {
        auto it = sessions_.find(fd);
        if (it == sessions_.end()) return;
        auto u = by_user_.find(it->second.user);
        if (u != by_user_.end() && u->second == fd) by_user_.erase(u);
        LOG_INFO("DISCONNECT " + (it->second.user.empty() ? "(anon)" : it->second.user));
        sessions_.erase(it);
        close_sock(fd);
    }

public:
    explicit Gateway(std::vector<std::string> symbols)
        : core_(std::move(symbols), [this](auto& u, auto& m) { to_user(u, m); },
                [this](auto& s, auto& m) { to_market(s, m); }, [this](auto& m) { to_feed(m); }) {}

    ExchangeCore& core() { return core_; }
    void set_idle_timeout(int seconds) { idle_timeout_s_ = seconds; }

    int run(int port) {
#ifdef _WIN32
        WSADATA wsa;
        if (WSAStartup(MAKEWORD(2, 2), &wsa) != 0) return 1;
#endif
        sock_t ls = ::socket(AF_INET, SOCK_STREAM, 0);
        int yes = 1;
        setsockopt(ls, SOL_SOCKET, SO_REUSEADDR, (const char*)&yes, sizeof yes);
        sockaddr_in addr{};
        addr.sin_family = AF_INET;
        addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);  // chỉ nhận kết nối từ máy này
        addr.sin_port = htons((uint16_t)port);
        if (::bind(ls, (sockaddr*)&addr, sizeof addr) != 0 || ::listen(ls, 64) != 0) {
            LOG_ERR("cannot listen on port " + std::to_string(port));
            return 1;
        }
        LOG_INFO("Gateway listening on 127.0.0.1:" + std::to_string(port));
        open_feed();

        for (;;) {
            const auto now = std::chrono::steady_clock::now();
            for (auto& [fd, ses] : sessions_)  // heartbeat: để client biết server còn sống khi không có gì khác để gửi
                if (ses.proto == Proto::Binary && ses.logged_in && now - ses.last_tx >= std::chrono::seconds(1))
                    send_raw(fd, ouch::packet('H'));
            for (auto& [fd, ses] : sessions_)
                if (now - ses.last_rx > std::chrono::seconds(idle_timeout_s_)) {
                    LOG_WARN("idle timeout " + (ses.user.empty() ? "(anon)" : ses.user) + ": no data for " +
                             std::to_string(idle_timeout_s_) + "s, disconnecting");
                    doomed_.insert(fd);
                }
            drop_doomed();
            fd_set rd, wr;
            FD_ZERO(&rd);
            FD_ZERO(&wr);
            FD_SET(ls, &rd);
            sock_t maxfd = ls;
            for (auto& [fd, ses] : sessions_) {
                FD_SET(fd, &rd);
                if (!ses.out.empty()) FD_SET(fd, &wr);  // còn dữ liệu chờ gửi => hỏi khi nào ghi được
                if (fd > maxfd) maxfd = fd;
            }
            timeval tv{1, 0};
            if (::select((int)maxfd + 1, &rd, &wr, nullptr, &tv) <= 0) continue;

            for (auto& [fd, ses] : sessions_) if (FD_ISSET(fd, &wr)) flush(fd, ses);

            if (FD_ISSET(ls, &rd)) {
                sock_t c = ::accept(ls, nullptr, nullptr);
                if (c != BAD_SOCK) {
                    set_nonblocking(c);
                    int one = 1;
                    setsockopt(c, IPPROTO_TCP, 1 /*TCP_NODELAY*/, (const char*)&one, sizeof one);
                    sessions_[c] = Session{};
                }
            }
            std::vector<sock_t> ready;
            for (auto& [fd, _] : sessions_) if (FD_ISSET(fd, &rd)) ready.push_back(fd);
            for (sock_t fd : ready) {
                char tmp[4096];
                int n = ::recv(fd, tmp, sizeof tmp, 0);
                if (n <= 0) { drop(fd); continue; }
                sessions_[fd].last_rx = std::chrono::steady_clock::now();
                Session& s0 = sessions_[fd];
                s0.buf.append(tmp, (size_t)n);
                if (s0.proto == Proto::Unknown) s0.proto = s0.buf[0] == '{' ? Proto::Json : Proto::Binary;
                if (s0.buf.size() > 65536) { drop(fd); continue; }  // chống client gửi rác không đúng khung
                if (s0.proto == Proto::Binary) { read_binary(fd); continue; }
                size_t pos;
                while (sessions_.count(fd) && (pos = sessions_[fd].buf.find('\n')) != std::string::npos) {
                    std::string line = sessions_[fd].buf.substr(0, pos);
                    sessions_[fd].buf.erase(0, pos + 1);
                    if (!line.empty()) on_line(fd, line);
                }
            }
        }
    }
};
