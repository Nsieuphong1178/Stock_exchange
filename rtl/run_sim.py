"""Chạy mô phỏng RTL:  python rtl/run_sim.py [parser] [parser64] [book] [ouch] [risk] [pipeline] [pipeline64] [t2t]   (không tham số = chạy tất cả)

  parser : eth_udp_itch_parser.v. gen_vectors.py chạy server C++ thật, bắt gói UDP, bọc thành khung Ethernet
  parser64: eth_udp_itch_parser64.v. 64 bit/chu kỳ, VLAN, nhiều message/gói; gen_vectors64.py (rơi/trùng gói, lỗi giữa gói)
  pipeline64: parser64 -> FIFO -> book, 100.009 message đóng gói 1..4 message/gói, đo FIFO cần sâu bao nhiêu
  book   : itch_book.v.           gen_book_vectors.py sinh 100.000 message ngẫu nhiên + golden
  ouch   : ouch_encoder.v.        gen_ouch_vectors.py: lệnh ngẫu nhiên, byte mong đợi do client/ouch.py mã hoá
  risk   : pretrade_risk.v.       tb_risk.v: kịch bản có chủ đích, kết quả mong đợi viết cứng (không cần golden)
  t2t    : cả chuỗi khung Ethernet -> parser -> book -> chiến lược -> risk -> mã hoá lệnh; đo độ trễ tick-to-trade
  pipeline: parser -> FIFO -> book. Cùng 100.000 message nhưng bọc thành khung Ethernet (xen khung lỗi)
Mỗi test: sinh vector -> Verilator biên dịch -> chạy testbench so với golden -> in PASS/FAIL.

Cần: server đã build (build/exchange_server.exe, chỉ cho test parser) và Verilator
(MSYS2: pacman -S mingw-w64-x86_64-verilator). Mã thoát 0 = mọi test được chọn đều PASS.

Phần xử lý riêng cho Windows/MSYS2 bên dưới là để vòng qua các lỗi của bộ công cụ trên máy này, không liên quan
tới thiết kế:
  - make của MSYS2 làm rơi biến TMP/TEMP => g++ báo "Cannot create temporary file in C:\\WINDOWS\\"
  - g++ 16.1 + -std=c++20 + -Os bị lỗi link thiếu std::string(string&&) => dùng -O2
  - bước ghép verilator_includer lỗi => build từng file .cpp riêng (VM_PARALLEL_BUILDS=1)
  - main() sinh bởi --main không được tự thêm vào bước link => truyền VM_USER_CLASSES
"""
import os
import shutil
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RTL = os.path.join(ROOT, "rtl")
SIM = os.path.join(RTL, "sim")
MSYS = r"C:\msys64"

TESTS = {
    "parser": dict(gen="gen_vectors.py", top="tb_parser", srcs=["eth_udp_itch_parser.v", "tb_parser.v"]),
    "book": dict(gen="gen_book_vectors.py", top="tb_book", srcs=["itch_book.v", "tb_book.v"]),
    "parser64": dict(gen="gen_vectors64.py", gen_args=["parser"], top="tb_parser64",
                     srcs=["eth_udp_itch_parser64.v", "tb_parser64.v"]),
    "pipeline64": dict(gen="gen_vectors64.py", gen_args=["pipeline"], top="tb_pipeline64",
                       srcs=["eth_udp_itch_parser64.v", "itch_book.v", "sfifo.v", "itch_pipeline64.v", "tb_pipeline64.v"]),
    "linerate": dict(gen="gen_vectors64.py", gen_args=["linerate"], top="tb_pipeline64",
                     srcs=["eth_udp_itch_parser64.v", "itch_book.v", "sfifo.v", "itch_pipeline64.v", "tb_pipeline64.v"]),
    "stress64": dict(gen="gen_vectors64.py", gen_args=["stress"], top="tb_parser64_stress",
                     srcs=["eth_udp_itch_parser64.v", "tb_parser64_stress.v"]),
    "ouch": dict(gen="gen_ouch_vectors.py", top="tb_ouch", srcs=["ouch_encoder.v", "tb_ouch.v"]),
    "risk": dict(gen=None, top="tb_risk", srcs=["pretrade_risk.v", "tb_risk.v"]),
    "t2t": dict(gen="gen_book_vectors.py", gen_args=["--frames", "--t2t"], top="tb_t2t",
                srcs=["eth_udp_itch_parser.v", "itch_book.v", "itch_pipeline.v", "sfifo.v", "pretrade_risk.v",
                      "strategy_threshold.v", "ouch_encoder.v", "tick_to_trade.v", "tb_t2t.v"]),
    "pipeline": dict(gen="gen_book_vectors.py", gen_args=["--frames"], top="tb_pipeline",
                     srcs=["eth_udp_itch_parser.v", "itch_book.v", "itch_pipeline.v", "tb_pipeline.v"]),
}


def run(cmd, env=None, **kw):
    # Windows tìm file chạy theo PATH của tiến trình cha, không theo env truyền vào => tự tra đường dẫn đầy đủ
    cmd = [shutil.which(cmd[0], path=(env or os.environ)["PATH"]) or cmd[0]] + cmd[1:]
    print("$", " ".join(cmd))
    r = subprocess.run(cmd, env=env, **kw)
    if r.returncode:
        print(f"lệnh thất bại (mã {r.returncode})")
    return r.returncode == 0


def run_test(name, env):
    spec = TESTS[name]
    top = spec["top"]
    obj = os.path.join(ROOT, "build", f"rtl_obj_{name}")
    print(f"\n=== RTL: {name} ===")
    if spec["gen"] and not run([sys.executable, os.path.join(RTL, spec["gen"]), *spec.get("gen_args", [])], env=env):
        return False

    shutil.rmtree(obj, ignore_errors=True)
    srcs = [os.path.join(RTL, s) for s in spec["srcs"]]
    verilate = ["verilator_bin" if os.name == "nt" else "verilator", "--timing", "-Wall", "-Wno-TIMESCALEMOD",
                "--top-module", top, "--Mdir", obj, "-o", f"sim_{name}", *srcs]
    if os.name == "nt":
        if not run(verilate + ["--main", "--exe"], env=env):  # chỉ sinh C++, tự gọi make bên dưới
            return False
        tmp = os.environ.get("LOCALAPPDATA", r"C:\Users\Public").replace("\\", "/") + "/Temp"
        if not run(["make", "-C", obj, "-f", f"V{top}.mk", "-j", "1", f"TMP={tmp}", f"TEMP={tmp}",
                    "OPT_GLOBAL=-O2", "OPT_FAST=-O2", "OPT_SLOW=-O2",
                    f"VM_USER_CLASSES=V{top}__main", "VM_PARALLEL_BUILDS=1"], env=env, stdout=subprocess.DEVNULL):
            return False
        exe = os.path.join(obj, f"sim_{name}.exe")
    else:
        if not run(verilate + ["--binary"], env=env):
            return False
        exe = os.path.join(obj, f"sim_{name}")

    # chạy trong rtl/sim để $readmemh tìm thấy các file .mem
    out = subprocess.run([exe], cwd=SIM, capture_output=True, text=True, encoding="utf-8", env=env)
    print(out.stdout.strip())
    return "PASS" in out.stdout and out.returncode == 0


def main():
    env = os.environ.copy()
    if os.name == "nt":
        env["PATH"] = os.pathsep.join([MSYS + r"\mingw64\bin", MSYS + r"\usr\bin", env["PATH"]])
        env["VERILATOR_ROOT"] = MSYS + "/mingw64/share/verilator"  # 'verilator' là script perl, gọi thẳng verilator_bin.exe
    env.setdefault("PYTHONIOENCODING", "utf-8")

    names = sys.argv[1:] or list(TESTS)
    unknown = [n for n in names if n not in TESTS]
    if unknown:
        sys.exit(f"test không tồn tại: {unknown}; có: {list(TESTS)}")
    results = {n: run_test(n, env) for n in names}
    print("\n" + "  ".join(f"{n}: {'PASS' if ok else 'FAIL'}" for n, ok in results.items()))
    sys.exit(0 if all(results.values()) else 1)


if __name__ == "__main__":
    main()
