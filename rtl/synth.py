"""Tổng hợp từng khối RTL bằng Yosys cho Xilinx 7-series và in bảng tài nguyên.   python rtl/synth.py [khối ...]

Đây là tổng hợp MÃ NGUỒN MỞ (Yosys, synth_xilinx -family xc7) thay cho Vivado/Quartus vốn không có trên máy này:
  - Số LUT / FF / BRAM / DSP là ước lượng tốt cho ánh xạ vào 7-series nhưng KHÔNG trùng khớp từng con số với Vivado.
  - Cột "mức logic" là độ dài đường tổ hợp dài nhất theo số ô (lệnh `ltp` của Yosys). CẢNH BÁO: KHÔNG đáng tin để so sánh Fmax:
    nó đếm từng ô CARRY4/DSP riêng lẻ và còn TĂNG (179 -> 295) khi Fmax thật tăng (48 -> 112 MHz) sau khi chia pipeline cho
    pretrade_risk. Muốn biết tốc độ, dùng chế độ --par (đặt-và-đi-dây).
  - Vivado/Quartus không có trên máy này. Yosys cũng không tổng hợp xong parser64 (cây mux của phiên bản mở vòng 8 byte khiến nó
    treo > 45 phút ở bước tối ưu mux): đó là một kết quả, xem docs/ARCHITECTURE.md.

Chế độ --par: tổng hợp cho ECP5 (synth_ecp5) rồi đặt-và-đi-dây bằng nextpnr-ecp5 để lấy Fmax SAU ĐỊNH TUYẾN thật trên LFE5U-85F.
ECP5 là FPGA giá rẻ dùng LUT4 và chậm hơn nhiều so với Xilinx 7-series/UltraScale mà HFT dùng, nên chỉ nên đọc số này như
TƯƠNG ĐỐI (so khối này với khối kia, trước và sau khi sửa), không phải con số sẽ có trên phần cứng HFT.
Vì các khối có hàng trăm cổng (không đủ chân I/O), mỗi khối được bọc trong một vỏ tự sinh: đầu vào nạp qua thanh ghi dịch 1 bit,
đầu ra rút gọn bằng cây XOR có thanh ghi trung gian (nhanh hơn khối cần đo nên không che đường găng của nó).

Cài đặt (một lần):  pacman -S mingw-w64-x86_64-yosys mingw-w64-x86_64-nextpnr    (MSYS2)
"""
import os
import re
import shutil
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RTL = os.path.join(ROOT, "rtl")
BUILD = os.path.join(ROOT, "build")
MSYS = r"C:\msys64"

# tên khối -> (module gốc, các file nguồn, tham số ghi đè)
TARGETS = {
    "parser8": ("eth_udp_itch_parser", ["eth_udp_itch_parser.v"], {}),
    "parser64": ("eth_udp_itch_parser64", ["eth_udp_itch_parser64.v"], {}),
    "risk": ("pretrade_risk", ["pretrade_risk.v"], {}),
    "strategy": ("strategy_threshold", ["strategy_threshold.v"], {}),
    "encoder": ("ouch_encoder", ["ouch_encoder.v"], {}),
    "fifo64x208": ("sfifo", ["sfifo.v"], {"W": 208, "AW": 6}),
    "book": ("itch_book", ["itch_book.v"], {}),
    "book_async": ("itch_book_async", ["itch_book_async.v"], {}),   # bản cũ đọc bất đồng bộ, để so sánh
    "t2t": ("tick_to_trade", ["eth_udp_itch_parser.v", "itch_book.v", "itch_pipeline.v", "sfifo.v", "pretrade_risk.v",
                              "strategy_threshold.v", "ouch_encoder.v", "tick_to_trade.v"], {}),
}
DEFAULT = ["parser8", "risk", "strategy", "encoder", "fifo64x208"]   # parser64 (treo) / book (nặng) / t2t: gọi tên riêng


def synth(name, timeout):
    top, files, params = TARGETS[name]
    os.makedirs(os.path.join(BUILD, "tmp"), exist_ok=True)
    tmp = os.path.join(BUILD, "tmp")
    env = os.environ.copy()
    env["PATH"] = MSYS + r"\mingw64\bin;" + MSYS + r"\usr\bin;" + env["PATH"]
    env["TMP"] = env["TEMP"] = tmp   # Yosys/abc ghi file tạm ở đây (mặc định C:\WINDOWS không ghi được)
    log = os.path.join(BUILD, f"synth_{name}.log")
    reads = "; ".join(f"read_verilog -sv {os.path.join(RTL, f).replace(chr(92), '/')}" for f in files)
    chp = "; ".join(f"chparam -set {k} {v} {top}" for k, v in params.items())
    script = f"{reads}; hierarchy -top {top}; {chp + '; ' if chp else ''}synth_xilinx -family xc7 -top {top} -flatten; stat; ltp -noff"
    try:
        r = subprocess.run([shutil.which("yosys", path=env["PATH"]) or "yosys", "-q", "-l", log, "-p", script], env=env, capture_output=True, text=True, timeout=timeout)
    except subprocess.TimeoutExpired:
        return {"name": name, "error": f"quá {timeout}s"}
    if r.returncode:
        return {"name": name, "error": (r.stderr or r.stdout).strip().splitlines()[-1][:120]}
    text = open(log, encoding="utf-8", errors="replace").read()
    stat = text[text.rindex("Printing statistics"):] if "Printing statistics" in text else text
    cells = {m.group(2): int(m.group(1)) for m in re.finditer(r"^\s+(\d+)\s+(\w+)\s*$", stat, re.M) if not m.group(2).isdigit()}
    count = lambda pat: sum(v for k, v in cells.items() if re.fullmatch(pat, k))
    ltp = re.findall(r"Longest topological path in \S+ \(length=(\d+)\)", text)
    return {"name": name, "lut": count(r"LUT\d"), "ff": count(r"FD[CPRS]E?"), "bram": count(r"RAMB(18|36)E1"),
            "lutram": count(r"RAM(32|64|128|256)\w*"), "dsp": count(r"DSP48E1"), "carry": count(r"CARRY4"),
            "muxf": count(r"MUXF\d"), "depth": int(ltp[-1]) if ltp else None}


PORT_RE = re.compile(r"\b(input|output)\s+(?:wire|reg)?\s*(?:\[(\w+):(\w+)\])?\s*(\w+)")


def parse_ports(path, top):
    """Cổng của module `top` dưới dạng [(hướng, độ rộng, tên)]; None nếu độ rộng phụ thuộc tham số."""
    text = open(path, encoding="utf-8").read()
    text = re.sub(r"//[^\n]*", "", text)
    start = text.index("module " + top)
    header = text[start:text.index(");", start)]
    if "#(" in header:   # bỏ khối tham số #( ... ): các tham số của khối đo đều có giá trị mặc định dùng được
        header = header[header.index(") (", header.index("#(")):]
    ports = []
    for d, hi, lo, name in PORT_RE.findall(header):
        if hi and not (hi.isdigit() and lo.isdigit()):
            return None
        ports.append((d, int(hi) - int(lo) + 1 if hi else 1, name))
    return ports


def make_wrapper(top, ports):
    ins = [(w, n) for d, w, n in ports if d == "input" and n != "clk"]
    outs = [(w, n) for d, w, n in ports if d == "output"]
    win, wout = sum(w for w, _ in ins), sum(w for w, _ in outs)
    lines = ["module par_wrap(input clk, input din, output reg dout);",
             f"  reg [{win - 1}:0] sh; always @(posedge clk) sh <= {{sh[{win - 2}:0], din}};"]
    conns, off = ["    .clk(clk)"], 0
    for w, n in ins:
        conns.append(f"    .{n}(sh[{off + w - 1}:{off}])")
        off += w
    for w, n in outs:
        lines.append(f"  wire [{w - 1}:0] o_{n};")
        conns.append(f"    .{n}(o_{n})")
    lines.append(f"  {top} u (\n" + ",\n".join(conns) + "\n  );")
    lines.append(f"  reg [{wout - 1}:0] r; always @(posedge clk) r <= {{" + ", ".join(f"o_{n}" for _, n in outs) + "};")
    g = 32
    ngrp = (wout + g - 1) // g
    lines.append(f"  reg [{ngrp - 1}:0] x; integer i;")
    pad = ngrp * g - wout
    lines.append(f"  wire [{ngrp * g - 1}:0] rp = " + (f"{{{pad}'d0, r}};" if pad else "r;"))
    lines.append(f"  always @(posedge clk) begin for (i = 0; i < {ngrp}; i = i + 1) x[i] <= ^rp[i*{g} +: {g}]; dout <= ^x; end")
    lines.append("endmodule")
    return "\n".join(lines) + "\n"


def tool_env():
    tmp = os.path.join(BUILD, "tmp")
    os.makedirs(tmp, exist_ok=True)
    env = os.environ.copy()
    env["PATH"] = MSYS + r"\mingw64\bin;" + MSYS + r"\usr\bin;" + env["PATH"]
    env["TMP"] = env["TEMP"] = tmp   # xem ghi chú ở synth()
    return env


def par(name, freq=150):
    top, files, params = TARGETS[name]
    if params:
        return {"name": name, "error": "tham số hoá, chưa hỗ trợ vỏ tự sinh"}
    ports = parse_ports(os.path.join(RTL, files[-1]), top)
    if ports is None:
        return {"name": name, "error": "cổng có độ rộng tham số, chưa hỗ trợ vỏ tự sinh"}
    env = tool_env()
    wrap = os.path.join(BUILD, f"par_wrap_{name}.v")
    open(wrap, "w", encoding="utf-8").write(make_wrapper(top, ports))
    js = os.path.join(BUILD, f"par_{name}.json")
    fwd = lambda p: p.replace("\\", "/")
    reads = "; ".join(f"read_verilog -sv {fwd(os.path.join(RTL, f))}" for f in files)
    y = subprocess.run([shutil.which("yosys", path=env["PATH"]) or "yosys", "-q", "-p",
                        f"{reads}; read_verilog -sv {fwd(wrap)}; synth_ecp5 -top par_wrap -json {fwd(js)}"],
                       env=env, capture_output=True, text=True, timeout=3600)
    if y.returncode:
        return {"name": name, "error": (y.stderr or y.stdout).strip().splitlines()[-1][:100]}
    n = subprocess.run([shutil.which("nextpnr-ecp5", path=env["PATH"]) or "nextpnr-ecp5", "--85k", "--package", "CABGA381",
                        "--json", js, "--freq", str(freq), "--seed", "1", "--timing-allow-fail"],
                       env=env, capture_output=True, text=True, timeout=3600)
    out = n.stdout + n.stderr
    open(os.path.join(BUILD, f"par_{name}.log"), "w", encoding="utf-8").write(out)
    fm = re.findall(r"Max frequency for clock[^:]*:\s*([\d.]+) MHz", out)
    use = lambda k: (re.findall(r"^Info:\s+" + k + r":\s*(\d+)/", out, re.M) or ["-"])[-1]
    if not fm:
        return {"name": name, "error": (re.findall(r"ERROR:.*", out) or ["không thấy Fmax"])[0][:100]}
    return {"name": name, "fmax": float(fm[-1]), "comb": use("TRELLIS_COMB"), "ff": use("TRELLIS_FF"),
            "bram": use("DP16KD"), "mult": use("MULT18X18D")}


def main_par(names):
    print(f"{'khối':<12}{'Fmax (MHz)':>12}{'LUT4':>8}{'FF':>8}{'BRAM':>6}{'MULT18':>8}   (ECP5-85F, sau định tuyến)")
    for n in names:
        print(f"... {n}", file=sys.stderr, flush=True)
        r = par(n)
        if "error" in r:
            print(f"{n:<12}LỖI: {r['error']}")
        else:
            print(f"{n:<12}{r['fmax']:>12.1f}{r['comb']:>8}{r['ff']:>8}{r['bram']:>6}{r['mult']:>8}")


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    if "--par" in sys.argv:
        return main_par(args or ["parser8", "risk", "strategy", "encoder"])
    names = args or DEFAULT
    rows = []
    for n in names:
        print(f"... {n}", file=sys.stderr, flush=True)
        rows.append(synth(n, 1200 if n in ("book", "t2t", "parser64") else 600))
    print(f"{'khối':<12}{'LUT':>8}{'FF':>8}{'BRAM18/36':>11}{'LUTRAM':>8}{'DSP48':>7}{'CARRY4':>8}{'MUXF':>7}{'mức logic':>11}")
    for r in rows:
        if "error" in r:
            print(f"{r['name']:<12}LỖI: {r['error']}")
        else:
            print(f"{r['name']:<12}{r['lut']:>8}{r['ff']:>8}{r['bram']:>11}{r['lutram']:>8}{r['dsp']:>7}{r['carry']:>8}"
                  f"{r['muxf']:>7}{(r['depth'] if r['depth'] is not None else '-'):>11}")


if __name__ == "__main__":
    main()
