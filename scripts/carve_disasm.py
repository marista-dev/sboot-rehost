#!/usr/bin/env python3
"""
carve_disasm.py — capstone 래퍼.
static-analyzer agent 가 호출.

--arch arm64 (기본) | arm32   AArch32/Thumb 부트로더(예: MediaTek LK)는 arm32.

사용법:
  carve_disasm.py disasm <bl3.bin> <file_off> <size> <base_va>
  carve_disasm.py xref <bl3.bin> <ascii_string>
  carve_disasm.py find_xref_to <bl3.bin> <target_va> <base_va>
  carve_disasm.py carve_check <bl3.bin>
  carve_disasm.py score_entry <bl3.bin> <off>
"""
import sys
import os
import struct

try:
    import capstone
except ImportError:
    print("ERROR: capstone 미설치. pip3 install capstone", file=sys.stderr)
    sys.exit(2)


ARCH = "arm64"          # set by main() from --arch


def _md():
    """Disassembler for the target's architecture.

    Not every bootloader at this stage is AArch64: MediaTek LK runs AArch32
    Thumb-2, so hardcoding ARM64 would make every derivation on such an image
    silently wrong rather than merely unsupported.
    """
    if ARCH == "arm32":
        md = capstone.Cs(capstone.CS_ARCH_ARM, capstone.CS_MODE_THUMB)
        md.skipdata = True
        return md
    return capstone.Cs(capstone.CS_ARCH_ARM64, capstone.CS_MODE_ARM)


def _md_arm():
    """AArch32 in ARM (non-Thumb) mode - reset vectors are usually ARM."""
    return capstone.Cs(capstone.CS_ARCH_ARM, capstone.CS_MODE_ARM)


def disasm(path, off, size, base):
    data = open(path, "rb").read()[off:off + size]
    md = _md()
    for ins in md.disasm(data, base):
        print(f"0x{ins.address:08x}: {ins.mnemonic:10s} {ins.op_str}  ; {ins.bytes.hex()}")


def xref(path, needle):
    data = open(path, "rb").read()
    if isinstance(needle, str):
        needle = needle.encode("latin-1")
    pos = data.find(needle)
    if pos < 0:
        print("NOT FOUND")
        return
    print(f"file_offset: 0x{pos:x}")


def find_xref_to(path, target_va, base_va):
    """target_va 를 가리키는 정렬된 포인터 위치들을 binary 안에서 검색.

    포인터 폭은 아키텍처가 정한다. AArch32 부트로더(LK)에서 8 B 포인터를 찾으면
    히트가 0 이 나와 "명령 테이블 없음" 으로 오판한다.
    """
    width = 4 if ARCH == "arm32" else 8
    fmt = "<I" if width == 4 else "<Q"
    data = open(path, "rb").read()
    needle = struct.pack(fmt, target_va & (0xFFFFFFFF if width == 4 else 0xFFFFFFFFFFFFFFFF))
    pos = 0
    hits = []
    while True:
        pos = data.find(needle, pos)
        if pos < 0:
            break
        if pos % width == 0:
            hits.append(pos)
        pos += 1
    for h in hits:
        va = base_va + h
        print(f"file_offset: 0x{h:x}  va: 0x{va:x}  (ptr {width}B)")
    if not hits:
        print("NOT FOUND")


# What a "full" bootloader image looks like depends on the vendor. Samsung S-Boot
# is a ~4 MB AArch64 image with its shell banner; MediaTek LK is a ~1.5 MB
# AArch32 image with entirely different strings. Judging LK by the S-Boot
# yardstick reports a carve and blocks a perfectly complete image.
CARVE_PROFILES = {
    "arm64": {
        "min_size": 4 * 1024 * 1024,
        "strings": [b"S-BOOT", b"autoboot", b"Following commands",
                    b"help", b"reset", b"dramtest"],
        "need": 3,
    },
    "arm32": {
        "min_size": 512 * 1024,
        "strings": [b"Little Kernel", b"lk build", b"fastboot", b"preloader",
                    b"boot mode", b"help", b"printenv"],
        "need": 2,
    },
}


def carve_check(path):
    """부트로더 이미지가 full 인지 carve(부분 추출)인지 판정."""
    prof = CARVE_PROFILES[ARCH]
    data = open(path, "rb").read()
    size = len(data)
    found = []
    for s in prof["strings"]:
        off = data.find(s)
        if off >= 0:
            found.append((s.decode(errors="replace"), hex(off)))
    is_full = size >= prof["min_size"] and len(found) >= prof["need"]
    print(f"arch: {ARCH}")
    print(f"size: {size} ({size // 1024} KB, 기준 {prof['min_size'] // 1024} KB 이상)")
    print(f"found_strings: {found}  (기준 {prof['need']} 개 이상)")
    print(f"is_full: {is_full}")


def score_entry(path, off):
    """AArch64 부팅 패턴 점수."""
    data = open(path, "rb").read()
    chunk = data[off:off + 0x100]
    md = _md()
    insns = list(md.disasm(chunk, off))
    text = "\n".join(f"{i.mnemonic} {i.op_str}" for i in insns)
    score = 0
    reasons = []
    if ARCH == "arm32":
        # AArch32 bootloaders start at an exception vector table and set up
        # MMU/caches through CP15, which look nothing like the AArch64 pattern.
        if "mrc" in text or "mcr" in text:
            score += 3; reasons.append("CP15 mrc/mcr (+3)")
        if text.strip().startswith("b ") or "\nb " in text:
            score += 3; reasons.append("벡터 b reset (+3)")
        if "cpsid" in text or "cpsr" in text:
            score += 2; reasons.append("cpsid/CPSR (+2)")
        if any(i.mnemonic in ("b", "bl", "blx") for i in insns[-5:]):
            score += 1; reasons.append("b/bl 끝 (+1)")
        print(f"score: {score}/10  (arch=arm32)")
        for r in reasons: print(f"  {r}")
        print("--- 첫 0x40 디스어셈블 ---")
        for ins in insns[:16]:
            print(f"  0x{ins.address:08x}: {ins.mnemonic:10s} {ins.op_str}")
        return
    if "msr vbar_el" in text:
        score += 3
        reasons.append("msr vbar_el (+3)")
    if "currentel" in text and ("b.eq" in text or "b.ne" in text):
        score += 3
        reasons.append("EL 분기 (+3)")
    if "msr scr_el3" in text or "msr sctlr_el" in text:
        score += 2
        reasons.append("msr scr/sctlr (+2)")
    if "daifset" in text:
        score += 1
        reasons.append("daifset (+1)")
    if any(i.mnemonic in ("b", "bl") for i in insns[-5:]):
        score += 1
        reasons.append("b/bl 끝 (+1)")
    print(f"score: {score}/10")
    for r in reasons:
        print(f"  {r}")
    print(f"--- 첫 0x40 디스어셈블 ---")
    for ins in insns[:16]:
        print(f"  0x{ins.address:08x}: {ins.mnemonic:10s} {ins.op_str}")


def main():
    global ARCH
    argv = sys.argv[1:]
    # --arch arm64|arm32 may appear anywhere; strip it before positional parsing.
    if "--arch" in argv:
        i = argv.index("--arch")
        ARCH = argv[i + 1] if i + 1 < len(argv) else "arm64"
        del argv[i:i + 2]
    if ARCH not in ("arm64", "arm32"):
        print(f"carve_disasm: unknown --arch '{ARCH}' (arm64|arm32)", file=sys.stderr)
        sys.exit(1)
    sys.argv = [sys.argv[0]] + argv

    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(1)
    op = sys.argv[1]
    if op == "disasm":
        disasm(sys.argv[2], int(sys.argv[3], 0), int(sys.argv[4], 0), int(sys.argv[5], 0))
    elif op == "xref":
        xref(sys.argv[2], sys.argv[3])
    elif op == "find_xref_to":
        find_xref_to(sys.argv[2], int(sys.argv[3], 0), int(sys.argv[4], 0))
    elif op == "carve_check":
        carve_check(sys.argv[2])
    elif op == "score_entry":
        score_entry(sys.argv[2], int(sys.argv[3], 0))
    else:
        print(__doc__)
        sys.exit(1)


if __name__ == "__main__":
    main()
