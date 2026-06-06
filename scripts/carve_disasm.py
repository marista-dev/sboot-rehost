#!/usr/bin/env python3
"""
carve_disasm.py — capstone 래퍼.
bl3-analyzer / stub-locator agent 에서 호출.

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


def _md():
    return capstone.Cs(capstone.CS_ARCH_ARM64, capstone.CS_MODE_ARM)


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
    """target_va 를 가리키는 8 B 정렬 위치들을 binary 안에서 검색."""
    data = open(path, "rb").read()
    needle = struct.pack("<Q", target_va)
    pos = 0
    hits = []
    while True:
        pos = data.find(needle, pos)
        if pos < 0:
            break
        if pos % 8 == 0:
            hits.append(pos)
        pos += 1
    for h in hits:
        va = base_va + h
        print(f"file_offset: 0x{h:x}  va: 0x{va:x}")
    if not hits:
        print("NOT FOUND")


def carve_check(path):
    """BL3 가 full 인지 carve 인지 판정."""
    data = open(path, "rb").read()
    size = len(data)
    known = [
        b"S-BOOT", b"autoboot", b"Following commands",
        b"help", b"reset", b"dramtest",
    ]
    found = []
    for s in known:
        off = data.find(s)
        if off >= 0:
            found.append((s.decode(), hex(off)))
    is_full = size >= 4 * 1024 * 1024 and len(found) >= 3
    print(f"size: {size} ({size // 1024 // 1024} MB)")
    print(f"found_strings: {found}")
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
