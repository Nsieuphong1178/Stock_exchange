#include <cstdlib>
#include <string>

#include "gateway.hpp"

int main(int argc, char** argv) {
    int port = argc > 1 ? std::atoi(argv[1]) : 9000;
    Logger::get().open("exchange.log");
    Gateway gw({"AAA", "BBB", "CCC"});
    if (argc > 2) gw.set_idle_timeout(std::atoi(argv[2]));  // giây; mặc định 10
    return gw.run(port);
}
