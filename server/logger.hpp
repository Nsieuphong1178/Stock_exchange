// Logger: ghi nhật ký ra console và file (audit trail của sàn).
#pragma once
#include <chrono>
#include <cstdio>
#include <ctime>
#include <fstream>
#include <string>

class Logger {
    std::ofstream file_;
    bool console_ = true;
public:
    static Logger& get() { static Logger l; return l; }
    void open(const std::string& path, bool console = true) { file_.open(path, std::ios::app); console_ = console; }
    void log(const char* level, const std::string& msg) {
#ifdef LOGGER_DISABLE  // build để đo độ trễ: g++ -DLOGGER_DISABLE ... => bỏ hẳn chi phí ghi log
        (void)level; (void)msg;
        return;
#endif
        using namespace std::chrono;
        auto now = system_clock::now();
        std::time_t t = system_clock::to_time_t(now);
        int ms = (int)(duration_cast<milliseconds>(now.time_since_epoch()).count() % 1000);
        char buf[32];
        std::tm tmv;
#ifdef _WIN32
        localtime_s(&tmv, &t);
#else
        localtime_r(&t, &tmv);
#endif
        std::strftime(buf, sizeof buf, "%H:%M:%S", &tmv);
        char line[64];
        std::snprintf(line, sizeof line, "%s.%03d [%s] ", buf, ms, level);
        std::string out = std::string(line) + msg + "\n";
        if (file_.is_open()) { file_ << out; file_.flush(); }
        if (console_) { std::fputs(out.c_str(), stderr); }
    }
};

#define LOG_INFO(m) Logger::get().log("INFO", (m))
#define LOG_WARN(m) Logger::get().log("WARN", (m))
#define LOG_ERR(m) Logger::get().log("ERR ", (m))
