"""Build và chạy MỌI test:  python run_all_tests.py   (mã thoát 0 = tất cả đều qua)

  1. build server + unit test C++ (-Wall -Wextra)
  2. unit test C++ (build/test_core)
  3. test Python: unit + end-to-end với server thật (tests/)
  4. mô phỏng RTL so với golden (rtl/run_sim.py)

Chạy hết cả bốn bước rồi mới tổng kết, để thấy toàn bộ chỗ hỏng thay vì dừng ở lỗi đầu tiên.
"""
import os
import shutil
import subprocess
import sys
import time

ROOT = os.path.dirname(os.path.abspath(__file__))
WIN = os.name == "nt"
EXT = ".exe" if WIN else ""
BUILD = os.path.join(ROOT, "build")


def tool_env():
    env = os.environ.copy()
    env["PYTHONIOENCODING"] = "utf-8"
    if WIN:  # g++ của MSYS2 không nằm trong PATH mặc định
        env["PATH"] = r"C:\msys64\mingw64\bin" + os.pathsep + env["PATH"]
    return env


def sh(cmd, env):
    cmd = [shutil.which(cmd[0], path=env["PATH"]) or cmd[0]] + cmd[1:]  # Windows tìm file chạy theo PATH của cha
    return subprocess.run(cmd, cwd=ROOT, env=env).returncode == 0


def step_build(env):
    os.makedirs(BUILD, exist_ok=True)
    flags = ["-std=c++17", "-Wall", "-Wextra", "-O2"]
    ws2 = ["-lws2_32"] if WIN else []
    return (sh(["g++", *flags, "server/main.cpp", "-o", f"build/exchange_server{EXT}", *ws2], env)
            and sh(["g++", *flags, "server/tests/test_core.cpp", "-o", f"build/test_core{EXT}"], env))


def main():
    env = tool_env()
    if WIN:  # server cũ còn chạy sẽ khoá file .exe, không ghi đè được
        subprocess.run(["taskkill", "/F", "/IM", "exchange_server.exe"], capture_output=True)
    steps = [
        ("build C++", lambda: step_build(env)),
        ("unit test C++", lambda: sh([os.path.join(BUILD, f"test_core{EXT}")], env)),
        ("test Python (unit + e2e)", lambda: sh([sys.executable, "-m", "unittest", "discover", "tests"], env)),
        ("mô phỏng RTL", lambda: sh([sys.executable, os.path.join("rtl", "run_sim.py")], env)),
    ]
    results = []
    for name, fn in steps:
        print(f"\n=== {name} ===", flush=True)
        t0 = time.time()
        ok = fn()
        results.append((name, ok, time.time() - t0))

    print("\n=== Tổng kết ===")
    for name, ok, dt in results:
        print(f"  {'PASS' if ok else 'FAIL'}  {name:<26}{dt:6.1f}s")
    sys.exit(0 if all(ok for _, ok, _ in results) else 1)


if __name__ == "__main__":
    main()
