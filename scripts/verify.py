#!/usr/bin/env python3
"""verify.py - measure the 5/5 verification in code (stage 1 verdict).

This is stage 1 of a two-stage check. The verifier agent re-examines the
verdict_script.json produced here. That agent may freely lower the verdict
(REAL -> FORCED) but may only raise it (FORCED -> REAL) when it can show
byte-level evidence.

Track 1 (bootloader shell) items:
  1. PC trace        shell_func / exec_command address appears in the trace
  2. output byte-match  every console token exists inside the BL3 binary
  3. source negative    the machine .c contains none of the output strings
  4. single UART path   qemu_chr_fe_write appears exactly once
  5. bypass record      every entry has all four fields

Track 2 (kernel + storage) items:
  1. boot progress   `Run /init`
  2. kernel evidence per grade (K2: erofs mounted / K3: sda partitions, power mode)
  3. source negative the machine .c (+HCI) contains none of those strings
  4. real driver     UTRD/Query/SCSI transactions in the trace (N/A unless K3)
  5. bypass record   four fields

Item names and evidence strings stay in Korean on purpose: they are copied
straight into VERIFICATION.md, which the user reads.

Usage:
  verify.py <workdir> --track 1 --bl3 <bl3.bin> [--pc 0x...]
  verify.py <workdir> --track 2 --target K3

Output: JSON on stdout + <workdir>/verdict_script.json
"""
import argparse
import glob
import json
import os
import re
import sys

BYPASS_KEYS = ("대상:", "이유:", "방법:", "부작용:")


# --- input discovery ---------------------------------------------------------
def newest(paths):
    files = [p for p in paths if os.path.isfile(p)]
    return max(files, key=os.path.getmtime) if files else None


def find_console(workdir, track):
    pattern = "kboot_*.txt" if track == 2 else "console_*.txt"
    return newest(glob.glob(os.path.join(workdir, "07_logs", pattern)))


def find_trace(workdir, track):
    prefix = "kboot_" if track == 2 else "run_"
    home = os.path.expanduser("~/rehost/_traces")
    return newest(glob.glob(os.path.join(home, prefix + "*.log")) +
                  glob.glob(os.path.join(workdir, "07_logs", prefix + "*.log")))


def find_machine_sources(workdir, track):
    src = os.path.join(workdir, "06_machine")
    if track == 2:
        names = (glob.glob(os.path.join(src, "machine_kernel.c")) +
                 glob.glob(os.path.join(src, "*ufs*.c")) +
                 glob.glob(os.path.join(src, "*hci*.c")))
    else:
        names = glob.glob(os.path.join(src, "machine.c"))
    return [n for n in names if os.path.isfile(n)]


def find_bypass(workdir):
    src = os.path.join(workdir, "06_machine")
    for name in ("bypasses.md", "우회_패치_목록.md"):
        path = os.path.join(src, name)
        if os.path.isfile(path):
            return path
    return None


def derive_pcs(workdir):
    """Pull shell_func / exec_command addresses out of STATIC.md.

    Item 1 needs the PCs that prove the real shell ran. Requiring the caller to
    pass them by hand meant the item failed permanently whenever --pc was
    omitted, capping the verdict at 4/5. Deriving them here keeps the item
    honest without hand-holding; an explicit --pc still wins.
    """
    static = os.path.join(workdir, "STATIC.md")
    if not os.path.isfile(static):
        return []
    found = []
    with open(static, encoding="utf-8", errors="replace") as fh:
        for line in fh:
            if re.search(r"shell_func|exec_command", line, re.I):
                found += re.findall(r"0x[0-9a-fA-F]{4,}", line)
    seen, ordered = set(), []
    for pc in found:
        key = pc.lower()
        if key not in seen:
            seen.add(key)
            ordered.append(pc)
    return ordered


def read_bytes(path):
    if not path or not os.path.isfile(path):
        return b""
    with open(path, "rb") as fh:
        return fh.read()


def read_text(path):
    if not path or not os.path.isfile(path):
        return ""
    with open(path, encoding="utf-8", errors="replace") as fh:
        return fh.read()


# --- shared items ------------------------------------------------------------
def check_bypass(workdir):
    path = find_bypass(workdir)
    if not path:
        return False, "우회 기록 파일이 없습니다 (06_machine/bypasses.md)"
    text = read_text(path)
    counts = {key: text.count(key) for key in BYPASS_KEYS}
    entries = counts["대상:"]
    complete = entries > 0 and len(set(counts.values())) == 1
    if complete:
        return True, f"{os.path.basename(path)}: 우회 {entries} 건, 모두 4 항목을 갖췄습니다"
    return False, f"{os.path.basename(path)}: 항목 수가 어긋납니다 {counts}"


def check_source_negative(sources, console_bytes):
    """A console token of 5+ chars showing up in machine source means self-injection."""
    tokens = set(re.findall(rb"[\w\-]{5,}", console_bytes))
    leaked = []
    for path in sources:
        src = read_text(path)
        for token in tokens:
            word = token.decode("latin-1")
            if word in src:
                leaked.append(f"{os.path.basename(path)}:{word}")
    if leaked:
        return False, f"머신 소스에 출력 문자열이 {len(leaked)} 건 누출됐습니다: {leaked[:10]}"
    return True, f"머신 소스 {len(sources)} 개에 출력 문자열이 없습니다"


# --- track 1 -----------------------------------------------------------------
def verify_track1(workdir, args):
    console_path = args.console or find_console(workdir, 1)
    trace_path = args.trace or find_trace(workdir, 1)
    sources = [args.machine] if args.machine else find_machine_sources(workdir, 1)
    console = read_bytes(console_path)
    bl3 = read_bytes(args.bl3)
    pcs = args.pc or derive_pcs(workdir)
    items = []

    trace = read_text(trace_path)
    hits = [pc for pc in pcs if pc.lower() in trace.lower()]
    if hits:
        evidence = f"트레이스에서 PC {hits} 확인"
    elif not pcs:
        evidence = "STATIC.md 에서 shell_func / exec_command 주소를 찾지 못했습니다"
    else:
        evidence = f"기대한 PC {pcs} 가 트레이스에 없습니다"
    items.append({"n": 1, "name": "PC 트레이스 (shell 함수 · exec_command 진입)",
                  "pass": bool(hits), "evidence": evidence})

    tokens = set(re.findall(rb"[\w\-]{3,}", console))
    missing = sorted(t.decode("latin-1") for t in tokens if bl3.find(t) < 0)
    items.append({
        "n": 2, "name": "출력 byte-match (콘솔 토큰이 BL3 안에 존재)",
        "pass": bool(tokens) and not missing,
        "evidence": (f"토큰 {len(tokens)} 개가 모두 BL3 안에 있습니다" if tokens and not missing
                     else f"토큰 {len(tokens)} 개 중 {len(missing)} 개를 BL3 에서 찾지 못했습니다: {missing[:10]}"),
    })

    ok, detail = check_source_negative(sources, console)
    items.append({"n": 3, "name": "소스 negative (머신 C 에 출력 문자열 없음)",
                  "pass": ok, "evidence": detail})

    calls = sum(read_text(p).count("qemu_chr_fe_write") for p in sources)
    items.append({"n": 4, "name": "UART 단일 경로 (qemu_chr_fe_write 1 자리)",
                  "pass": calls == 1,
                  "evidence": f"qemu_chr_fe_write 호출이 {calls} 곳입니다"})

    ok, detail = check_bypass(workdir)
    items.append({"n": 5, "name": "우회 기록 4 항목", "pass": ok, "evidence": detail})

    return items, console_path, trace_path, sources


# --- track 2 -----------------------------------------------------------------
MILESTONE_EVIDENCE = {
    "K1": [r"Run /init"],
    "K2": [r"erofs: \(device dm-\d+\): mounted"],
    "K3": [r"\bsda: sda\d", r"Power mode change", r"\[sda\] Attached SCSI disk"],
}


def verify_track2(workdir, args):
    console_path = args.console or find_console(workdir, 2)
    trace_path = args.trace or find_trace(workdir, 2)
    sources = [args.machine] if args.machine else find_machine_sources(workdir, 2)
    console = read_bytes(console_path)
    trace = read_text(trace_path)
    haystack = console.decode("utf-8", errors="replace") + "\n" + trace
    target = (args.target or "K2").upper()
    items = []

    init_ok = "Run /init" in haystack
    items.append({"n": 1, "name": "부팅 진행 (Run /init)", "pass": init_ok,
                  "evidence": ("콘솔에서 'Run /init' 을 확인했습니다" if init_ok
                               else "'Run /init' 이 콘솔·트레이스에 없습니다")})

    patterns = MILESTONE_EVIDENCE.get(target, MILESTONE_EVIDENCE["K2"])
    found = [p for p in patterns if re.search(p, haystack)]
    items.append({
        "n": 2, "name": f"커널 메시지 증거 ({target})",
        "pass": bool(found),
        "evidence": (f"커널이 찍은 줄에서 {found} 패턴을 확인했습니다" if found
                     else f"기대한 패턴 {patterns} 이 보이지 않습니다"),
    })

    ok, detail = check_source_negative(sources, console)
    items.append({"n": 3, "name": "소스 negative (머신 C 에 그 문자열 없음)",
                  "pass": ok, "evidence": detail})

    if target == "K3":
        markers = [m for m in ("UTRD", "UPIU", "Query", "SCSI") if m in trace]
        items.append({"n": 4, "name": "벤더 드라이버 실제 구동 (UTRD/Query/SCSI)",
                      "pass": len(markers) >= 2,
                      "evidence": f"트레이스에서 확인한 트랜잭션 마커: {markers}"})
    else:
        items.append({"n": 4, "name": "벤더 드라이버 실제 구동",
                      "pass": True,
                      "evidence": f"해당 없음 (target={target}, 제네릭 스토리지)"})

    ok, detail = check_bypass(workdir)
    items.append({"n": 5, "name": "우회 기록 4 항목", "pass": ok, "evidence": detail})

    return items, console_path, trace_path, sources


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("workdir")
    parser.add_argument("--track", type=int, choices=(1, 2), required=True)
    parser.add_argument("--target", default=None, help="track 1: A/B/C, track 2: K1/K2/K3")
    parser.add_argument("--bl3", default=None, help="track 1 BL3 binary")
    parser.add_argument("--machine", default=None, help="machine source (auto-discovered if omitted)")
    parser.add_argument("--console", default=None)
    parser.add_argument("--trace", default=None)
    parser.add_argument("--pc", action="append",
                        help="track 1 item 1 expected PC; derived from STATIC.md when omitted")
    args = parser.parse_args()

    if args.track == 1:
        if not args.bl3:
            print("verify: track 1 requires --bl3", file=sys.stderr)
            sys.exit(1)
        items, console, trace, sources = verify_track1(args.workdir, args)
    else:
        items, console, trace, sources = verify_track2(args.workdir, args)

    passes = sum(1 for i in items if i["pass"])
    result = {
        "track": args.track,
        "target": args.target,
        "passes": passes,
        "total": len(items),
        "verdict": "REAL" if passes == len(items) else "FORCED",
        "items": items,
        "inputs": {"console": console, "trace": trace, "sources": sources},
        "note": ("스크립트 1 차 측정입니다. verifier 가 2 차로 재검증하며, "
                 "FORCED 를 REAL 로 올리려면 byte-level 증거가 필요합니다."),
    }

    with open(os.path.join(args.workdir, "verdict_script.json"), "w", encoding="utf-8") as fh:
        json.dump(result, fh, ensure_ascii=False, indent=2)

    json.dump(result, sys.stdout, ensure_ascii=False, indent=2)
    sys.stdout.write("\n")


if __name__ == "__main__":
    main()
