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
  2. kernel evidence per grade. For K3 this is the UFS controller completion
     bar, not "any storage line" - see K3_STAGES.
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

# The four bypass fields, written with optional markdown emphasis and, for the
# side-effect field, the longer "알려진 부작용" wording that real workspaces use.
BYPASS_FIELDS = {
    "대상": r"대상",
    "이유": r"이유",
    "방법": r"방법",
    "부작용": r"(?:알려진\s*)?부작용",
}


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
    """Every bypass entry must carry all four fields.

    Real workspaces write these with markdown emphasis (`**대상**:`) and often
    spell the last one "알려진 부작용", so matching the bare literal `대상:`
    reported zero fields and failed a compliant file. Match the field name with
    optional emphasis and an optional leading list marker instead.
    """
    path = find_bypass(workdir)
    if not path:
        return False, "우회 기록 파일이 없습니다 (06_machine/bypasses.md)"
    text = read_text(path)
    counts = {}
    for label, pattern in BYPASS_FIELDS.items():
        rx = re.compile(rf"^[\s>\-*+]*\**\s*{pattern}\s*\**\s*[:：]", re.M)
        counts[label] = len(rx.findall(text))
    entries = counts["대상"]
    complete = entries > 0 and len(set(counts.values())) == 1
    if complete:
        return True, f"{os.path.basename(path)}: 우회 {entries} 건, 모두 4 항목을 갖췄습니다"
    return False, f"{os.path.basename(path)}: 항목 수가 어긋납니다 {counts}"


def code_literals(path):
    """Return only the C string literals of a source file.

    Item 3 asks whether the machine *prints* console text. Searching the whole
    file also hits analysis comments and `#include "qapi/error.h"`, which are
    not output at all - that produced false leaks on a workspace whose verdict
    was genuinely 5/5. Strip comments and includes, then keep the literals.
    """
    src = read_text(path)
    src = re.sub(r"/\*.*?\*/", " ", src, flags=re.S)      # block comments
    src = re.sub(r"//[^\n]*", " ", src)                    # line comments
    src = re.sub(r"^\s*#\s*include[^\n]*", " ", src, flags=re.M)
    return " ".join(re.findall(r'"((?:[^"\\]|\\.)*)"', src))


def check_source_negative(sources, console_bytes):
    """A console token of 5+ chars appearing in a machine string literal is
    self-injection. Comments and include paths are not output, so they do not
    count."""
    tokens = set(re.findall(rb"[\w\-]{5,}", console_bytes))
    leaked = []
    for path in sources:
        literals = code_literals(path)
        for token in tokens:
            word = token.decode("latin-1")
            if word in literals:
                leaked.append(f"{os.path.basename(path)}:{word}")
    if leaked:
        return False, f"머신 소스의 문자열 리터럴에 출력 문자열이 {len(leaked)} 건 있습니다: {leaked[:10]}"
    return True, (f"머신 소스 {len(sources)} 개의 문자열 리터럴에 출력 문자열이 없습니다 "
                  f"(주석·#include 는 출력이 아니므로 제외)")


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

    # Item 4 depends on the interactive surface. For a UART shell the risk is the
    # machine writing text itself, so we count output paths. For a fastboot
    # surface the output path is USB and the real risk is the machine inventing
    # the *input* command - that would be circular verification, not a rehost.
    if args.surface == "fastboot":
        token = args.input_token or "getvar:"
        planted = [os.path.basename(p) for p in sources if token in code_literals(p)]
        items.append({
            "n": 4, "name": "입력이 외부에서 옴 (머신이 명령을 지어내지 않음)",
            "pass": not planted,
            "evidence": (f"머신 소스에 입력 명령 '{token}' 리터럴이 없습니다 — "
                         f"호스트가 보낸 것으로 처리됩니다"
                         if not planted else
                         f"머신 소스 {planted} 에 입력 명령 '{token}' 이 리터럴로 있습니다 — "
                         f"머신이 명령을 지어낸 순환검증입니다"),
        })
    else:
        calls = sum(read_text(p).count("qemu_chr_fe_write") for p in sources)
        items.append({"n": 4, "name": "UART 단일 경로 (qemu_chr_fe_write 1 자리)",
                      "pass": calls == 1,
                      "evidence": f"qemu_chr_fe_write 호출이 {calls} 곳입니다"})

    ok, detail = check_bypass(workdir)
    items.append({"n": 5, "name": "우회 기록 4 항목", "pass": ok, "evidence": detail})

    return items, console_path, trace_path, sources


# --- track 2 -----------------------------------------------------------------
# Rootfs and link-up wording differ by firmware: EROFS over dm-linear on a super
# image, or plain ext4 on a raw block device; ufshcd core or the vendor glue
# driver. Accept either rather than encoding one device's shape as universal.
ROOTFS_PATTERNS = [
    r"erofs: \(device dm-\d+\): mounted",
    r"EXT4-fs \([^)]+\): mounted filesystem",
    r"VFS: Mounted root \(\w+ filesystem\)",
]
LINK_UP_PATTERNS = [
    r"scsi host\d+: ufshcd",
    r"ufs\w*[^\n]*: UFS link established",
]

# K3 is the point of track 2: driving a real vendor UFS controller far enough
# that the kernel enumerates partitions. The methodology sets the bar at
# partitions_up (minimum completion); super_mounted is the capstone and only
# applies to firmware that ships a super image.
K3_STAGES = {
    "partitions_up": [r"\bsda: sda\d"],
    "super_mounted": [r"supermount: SUCCESS",
                      r"erofs: \(device dm-\d+\): mounted"],
}
# Rungs below the completion bar. Reaching one of these is progress, not K3.
K3_PROGRESS = {
    "link_up": LINK_UP_PATTERNS,
    "power_mode": [r"Power mode change\(\d+\)"],
    "scsi_attach": [r"\[sda\] Attached SCSI disk"],
}


def any_match(patterns, haystack):
    return [p for p in patterns if re.search(p, haystack)]


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

    # --- item 2: grade-specific kernel evidence ---
    if target == "K3":
        reached = [name for name, pats in K3_PROGRESS.items() if any_match(pats, haystack)]
        parts = any_match(K3_STAGES["partitions_up"], haystack)
        capstone = any_match(K3_STAGES["super_mounted"], haystack)
        if parts:
            best = "super_mounted (캡스톤)" if capstone else "partitions_up (최소 완료)"
            evidence = (f"커널이 파티션을 열거했습니다 — 도달 {best}. "
                        f"통과한 하위 단: {reached or '기록 없음'}")
        else:
            evidence = (f"파티션 열거(`sda: sdaN`)가 없습니다. 도달한 하위 단: "
                        f"{reached or '없음'} — 방법론상 partitions_up 미도달은 "
                        f"UFS 컨트롤러 미완성입니다")
        items.append({"n": 2, "name": "커널 메시지 증거 (K3 — partitions_up 필수)",
                      "pass": bool(parts), "evidence": evidence})
    else:
        patterns = ROOTFS_PATTERNS if target == "K2" else [r"Run /init"]
        found = any_match(patterns, haystack)
        items.append({
            "n": 2, "name": f"커널 메시지 증거 ({target})",
            "pass": bool(found),
            "evidence": (f"커널이 찍은 줄에서 {found} 확인" if found
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


def k3_stage_report(haystack):
    """Which rung of the UFS controller ladder the run actually cleared."""
    cleared = [n for n, p in K3_PROGRESS.items() if any_match(p, haystack)]
    if any_match(K3_STAGES["partitions_up"], haystack):
        cleared.append("partitions_up")
    if any_match(K3_STAGES["super_mounted"], haystack):
        cleared.append("super_mounted")
    if "super_mounted" in cleared:
        stage = "K3b (캡스톤 — 완전한 UFS 컨트롤러)"
    elif "partitions_up" in cleared:
        stage = "K3a (최소 완료 — 파티션 열거)"
    else:
        stage = "미완 (UFS 컨트롤러 미완성)"
    return {"stage": stage, "cleared": cleared}


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
    parser.add_argument("--surface", default="shell", choices=("shell", "fastboot"),
                        help="track 1 interactive surface; selects item 4")
    parser.add_argument("--input-token", default=None,
                        help="fastboot surface: the command the host injects (default getvar:)")
    args = parser.parse_args()

    if args.track == 1:
        if not args.bl3:
            print("verify: track 1 requires --bl3", file=sys.stderr)
            sys.exit(1)
        items, console, trace, sources = verify_track1(args.workdir, args)
        storage = None
    else:
        items, console, trace, sources = verify_track2(args.workdir, args)
        storage = k3_stage_report(
            read_bytes(console).decode("utf-8", errors="replace") + "\n" + read_text(trace))

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
    if storage:
        result["ufs_controller"] = storage

    with open(os.path.join(args.workdir, "verdict_script.json"), "w", encoding="utf-8") as fh:
        json.dump(result, fh, ensure_ascii=False, indent=2)

    json.dump(result, sys.stdout, ensure_ascii=False, indent=2)
    sys.stdout.write("\n")


if __name__ == "__main__":
    main()
