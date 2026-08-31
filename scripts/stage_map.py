#!/usr/bin/env python3
"""stage_map.py - derive the executable stage map of a bootloader container.

A vendor bootloader image is several stages concatenated: some plaintext and
runnable, some encrypted with a key that lives in silicon, some absent entirely.
Rehosting the chain means knowing **which is which, where each one loads, and
where it starts** - and knowing it as derived fact, not as a value borrowed from
another device.

This encodes the procedure that worked, so it can be re-run on the next firmware
instead of re-invented:

  1. entropy grid      plaintext / encrypted / zero-padding, on a fixed grid
  2. entry-stub scan   arch-specific reset-stub signature marks a stage boundary
  3. string context    what each region says about itself
  4. base derivation   basefind, then **cross-checked against a literal anchor**

Step 4's cross-check is the part that must not be skipped. Pointer-containment
alone picked a wrong base on real firmware (off by ~0xBE000000); the base only
became fact when a BSS pointer from the image, converted to a file offset,
landed exactly where the file's zero padding began. A base with no anchor is
reported as a candidate, never as derived.

Usage:
  stage_map.py <image> [--arch arm64|arm32] [--profile <name>]
                       [--out stage_map.json] [--grid 0x800] [--quiet]

Exit codes:
  0  a map was produced (possibly with unresolved bases - see `confidence`)
  3  the architecture has no entry-stub signature yet (arm32): caller should
     report BLOCKED_ARCH rather than pretend the image has no stages
"""
import argparse
import json
import math
import os
import re
import sys
from collections import Counter

# ---- AArch64 encodings we match without a disassembler -----------------------
# Raw masks keep this script dependency-free: capstone is not needed to find a
# reset stub, and requiring it would put a pip install between the analyst and
# the first fact.
A64 = {
    "mrs_currentel": (0xFFFFFFE0, 0xD5384240),
    "msr_vbar_el1":  (0xFFFFFFE0, 0xD518C000),
    "msr_vbar_el2":  (0xFFFFFFE0, 0xD51CC000),
    "msr_vbar_el3":  (0xFFFFFFE0, 0xD51EC000),
}
A64_ADR = (0x9F000000, 0x10000000)

ENC_MIN = 7.5      # entropy at or above this reads as encrypted/compressed
PLAIN_MAX = 5.0    # below this is text, tables or sparse data


def entropy(block):
    if not block:
        return 0.0
    counts = Counter(block)
    n = len(block)
    return -sum((c / n) * math.log2(c / n) for c in counts.values())


def classify(block):
    if not block or block == bytes(len(block)):
        return "zero"
    e = entropy(block)
    if e >= ENC_MIN:
        return "enc"
    if e < PLAIN_MAX:
        return "plain"
    return "mid"          # dense code reads here; so does light compression


def entropy_runs(data, grid):
    """Collapse the grid into labelled runs [start, end, label, max_entropy]."""
    runs, prev = [], None
    for off in range(0, len(data), grid):
        block = data[off:off + grid]
        label = classify(block)
        e = entropy(block)
        if label != prev:
            runs.append([off, off + len(block), label, e])
            prev = label
        else:
            runs[-1][1] = off + len(block)
            runs[-1][3] = max(runs[-1][3], e)
    return [{"start": a, "end": b, "label": l, "max_entropy": round(e, 2)}
            for a, b, l, e in runs]


def words(data):
    """Little-endian 32-bit words with their file offsets, 4-byte aligned."""
    for i in range(0, len(data) - 3, 4):
        yield i, int.from_bytes(data[i:i + 4], "little")


def find_entry_stubs_arm64(data, window=80):
    """A stage's reset stub, not every function that reads CurrentEL.

    The distinguishing shape is `CurrentEL` read **and** a vector base written
    nearby: `mrs xN, currentel` on its own is a getter, and matching on it alone
    reported helper functions as stage boundaries.
    """
    cur, vbar, adrs = [], {}, set()
    for off, w in words(data):
        m, v = A64["mrs_currentel"]
        if w & m == v:
            cur.append(off)
            continue
        for name in ("msr_vbar_el1", "msr_vbar_el2", "msr_vbar_el3"):
            m, v = A64[name]
            if w & m == v:
                vbar[off] = name
        m, v = A64_ADR
        if w & m == v:
            adrs.add(off)

    stubs = []
    for off in cur:
        near = {o: n for o, n in vbar.items() if -16 <= o - off <= window}
        if not near:
            continue                      # a getter, not a stub
        levels = sorted({n.split("_")[-1] for n in near.values()})
        # The stub loads its vector table address before testing the level.
        has_adr = any(off - 24 <= a < off for a in adrs)
        stubs.append({
            "at": off,
            "vbar_writes": levels,
            "adr_before": has_adr,
            # An entry stub is the first instruction of a stage, so the stage
            # starts at the branch that precedes it, not at the `mrs`.
            "stage_start": stub_start(data, off),
        })
    return stubs


def stub_start(data, mrs_off, back=32):
    """Walk back to the `b .+4` / `adr` preamble that opens the stub."""
    start = mrs_off
    for off in range(max(0, mrs_off - back), mrs_off, 4):
        w = int.from_bytes(data[off:off + 4], "little")
        if w & 0xFC000000 == 0x14000000:      # unconditional B
            start = off
            break
        m, v = A64_ADR
        if w & m == v:
            start = min(start, off)
    return start


def strings_in(data, lo, hi, minlen=8, limit=4000):
    out = []
    for m in re.finditer(rb"[ -~]{%d,}" % minlen, data[lo:hi]):
        out.append((lo + m.start(), m.group().decode("ascii", "replace")))
        if len(out) >= limit:
            break
    return out


def basefind(data, lo, hi, granule=0x1000, floor=0x1000):
    """Rank candidate load bases by how many in-image pointers they explain."""
    span = hi - lo
    vals = []
    for i in range(lo, max(lo, hi - 8), 8):
        v = int.from_bytes(data[i:i + 8], "little")
        if floor <= v < (1 << 32):
            vals.append(v)
    if not vals:
        return [], 0
    cands = {(v // granule) * granule for v in vals}
    scored = []
    for base in cands:
        n = sum(1 for v in vals if base <= v < base + span)
        if n:
            scored.append((n, base))
    scored.sort(reverse=True)
    return scored[:32], len(vals)


def anchor_check(data, lo, hi, base, zero_min=0x400):
    """Does a pointer from this region land where the file's padding starts?

    A stage's BSS begins right after its loaded image, so `bss_start - base`
    converted to a file offset must land on zero padding. That coincidence is
    what turns a base candidate into a derived value; without it two bases a
    megabyte apart score almost the same.
    """
    span = hi - lo
    hits = []
    for i in range(lo, max(lo, hi - 8), 8):
        v = int.from_bytes(data[i:i + 8], "little")
        if not (base <= v < base + span + (1 << 24)):
            continue
        off = lo + (v - base)
        if not (lo < off <= len(data) - zero_min):
            continue
        if data[off:off + zero_min] == bytes(zero_min):
            # Padding must START here, or every offset inside a big zero run
            # would look like an anchor.
            if off >= 4 and data[off - 4:off] != bytes(4):
                hits.append({"literal_at": i, "value": v, "file_offset": off})
    return hits


MIN_POINTERS = 8


def low_base_hint(data, lo, hi, sample=4000):
    """Do this stage's own branch targets stay inside the image?

    A first stage often runs at address 0, where every internal call is an
    absolute low address. basefind cannot see that - it only looks at high
    values - so the stage reports no base when the answer is simply zero.
    """
    inside = outside = 0
    span = hi - lo
    for off in range(lo, min(hi, lo + sample * 4), 4):
        w = int.from_bytes(data[off:off + 4], "little")
        if w & 0xFC000000 != 0x94000000:        # BL imm26
            continue
        imm = w & 0x03FFFFFF
        if imm & (1 << 25):
            imm -= (1 << 26)
        target = (off - lo) + imm * 4
        if 0 <= target < span:
            inside += 1
        else:
            outside += 1
    if inside and inside >= outside * 3:
        return (f"내부 BL 대상 {inside}개가 전부 이미지 안입니다 — **base=0 실행 가능성**. "
                f"호출 대상 몇 개를 디스어셈블해 정상 함수 프롤로그인지 확인하십시오")
    return None


def derive_base(data, lo, hi):
    scored, total = basefind(data, lo, hi)
    if not scored:
        return {"load_base": None, "confidence": "none",
                "why": "주소로 볼 만한 64비트 값이 이 구간에 없습니다",
                "low_base_hint": low_base_hint(data, lo, hi)}
    best = []
    for n, base in scored[:12]:
        hits = anchor_check(data, lo, hi, base)
        best.append((len(hits), n, base, hits))
    best.sort(reverse=True)
    anchors, contained, base, hits = best[0]
    if anchors:
        return {
            "load_base": base,
            "confidence": "derived",
            "pointer_containment": round(contained / max(total, 1), 3),
            "anchors": hits[:4],
            "why": "리터럴 앵커가 파일의 제로 패딩 시작에 정확히 착지 (교차검증 통과)",
        }
    contained, base = scored[0]
    # A handful of matches is not a candidate. AArch64 instruction words read as
    # plausible addresses (an `msr vbar_el3` is 0xd51ec000), so a base supported
    # by a few words is usually the encoding of an opcode, not a load address.
    if contained < MIN_POINTERS:
        return {
            "load_base": None,
            "confidence": "none",
            "why": (f"최상위 후보 0x{base:08x} 를 뒷받침하는 포인터가 {contained}개뿐입니다 "
                    f"(하한 {MIN_POINTERS}). 명령어 인코딩이 주소처럼 보인 것일 수 있어 "
                    f"후보로도 내지 않습니다"),
            "low_base_hint": low_base_hint(data, lo, hi),
        }
    return {
        "load_base": base,
        "confidence": "candidate",
        "pointer_containment": round(contained / max(total, 1), 3),
        "anchors": [],
        "why": "포인터 포함률 1위이나 **앵커 교차검증 실패** — 확정값으로 쓰지 마십시오",
    }


def label_region(strs, hints):
    """Name a region from what it says about itself. Unknown stays unknown."""
    joined = " ".join(s for _, s in strs[:600]).lower()
    scores = {}
    for name, keys in hints.items():
        hit = sum(1 for k in keys if k.lower() in joined)
        if hit:
            scores[name] = hit
    if not scores:
        return None, {}
    top = max(scores.items(), key=lambda kv: kv[1])
    return top[0], scores


DEFAULT_HINTS = {
    "first_stage": ["loading", "rx done", "header fail", "preloader", "bl1"],
    "dram_init":   ["dmc", "dram", "mif", "lpddr", "ddr", "training"],
    "bootloader":  ["autoboot", "following commands", "s-boot", "little kernel",
                    "fastboot", "board_power_off", "boot linux"],
    "secure_os":   ["teegris", "sec_os", "trusty", "tzsw"],
    "el3_monitor": ["unhandled kernel synchronous exception", "esr_el1",
                    "runtime service", "smc_handler"],
    "crypto":      ["cryptomanager", "crypto_operation", "rpmb"],
    "power_fw":    ["enter_wfi", "nvic", "acpm", "dvfs"],
}


def load_profile_hints(profile):
    """Profile hints override the defaults; a missing profile is not an error."""
    if not profile:
        return DEFAULT_HINTS
    here = os.path.dirname(os.path.abspath(__file__))
    path = os.path.join(os.path.dirname(here), "profiles", f"{profile}.yaml")
    if not os.path.exists(path):
        return DEFAULT_HINTS
    # Deliberately not a YAML parse: only `stage_hints:` is read, so the script
    # keeps working on a machine without PyYAML installed.
    hints = dict(DEFAULT_HINTS)
    try:
        text = open(path, encoding="utf-8").read()
    except OSError:
        return hints
    block = re.search(r"^\s*stage_hints:\s*$(.*?)(?=^\S|\Z)", text,
                      re.M | re.S)
    if not block:
        return hints
    for line in block.group(1).splitlines():
        # Digits belong in a key: el3_monitor, bl2, el2_hyp. Without them the
        # line is skipped in silence and the default quietly wins.
        m = re.match(r"\s+([a-z0-9_]+):\s*\[(.*)\]\s*$", line)
        if m:
            keys = [k.strip().strip('"\'') for k in m.group(2).split(",")]
            hints[m.group(1)] = [k for k in keys if k]
    return hints


def split_at_encryption(lo, hi, runs, grid):
    """A stage that begins in plaintext and continues into ciphertext is TWO
    stages, not one encrypted stage.

    The previous rule marked the whole stub-to-stub span `encrypted` when more
    than 60% of its bytes were high-entropy. On Exynos 9820 that discarded BL1:
    20 KB of plaintext with the entry stub at 0x10, sitting in front of EPBL's
    38 KB of ciphertext. 38912/59392 = 65.5%, so the executable head was skipped
    with the tail and the reset PC moved forward to the bootloader - which is
    exactly the "start at BL33" shortcut this flow exists to avoid. Exynos 2400
    has the same shape (32 KB plaintext head).

    The entry stub sits at `lo`, so the head is the part that can actually be
    entered. The tail starts on ciphertext and cannot be, whatever its ratio.
    """
    enc = [r for r in runs if r["label"] == "enc"
           and r["end"] > lo and r["start"] < hi]
    if not enc:
        return [(lo, hi, "exec")]

    cut = max(min(r["start"] for r in enc), lo)
    if cut - lo < grid:
        # No plaintext head worth entering: the stage begins in ciphertext.
        return [(lo, hi, "encrypted")]
    if hi - cut < grid:
        # Ciphertext is a trailing fragment (packed data, keys), not a stage.
        return [(lo, hi, "exec")]
    return [(lo, cut, "exec"), (cut, hi, "encrypted")]


def build_map(data, arch, hints, grid):
    runs = entropy_runs(data, grid)
    if arch == "arm64":
        stubs = find_entry_stubs_arm64(data)
    else:
        stubs = None                       # signature not defined for this arch

    stages = []
    if stubs is not None:
        bounds = sorted({s["stage_start"] for s in stubs})
        # A stage runs from its stub to the next stub; the tail belongs to the
        # last one. Regions before the first stub are stage 0 (the entry stage,
        # whose stub is the image header rather than a CurrentEL test).
        edges = [0] + bounds + [len(data)]
        for span_lo, span_hi in zip(edges, edges[1:]):
            if span_hi - span_lo < grid:
                continue
            for lo, hi, state in split_at_encryption(span_lo, span_hi, runs, grid):
                if hi - lo < grid:
                    continue
                strs = strings_in(data, lo, hi)
                name, scores = label_region(strs, hints)
                enc_bytes = sum(min(r["end"], hi) - max(r["start"], lo)
                                for r in runs if r["label"] == "enc"
                                and r["end"] > lo and r["start"] < hi)
                entry = next((s for s in stubs if s["stage_start"] == lo), None)
                i = len(stages)
                stage = {
                    "index": i,
                    "name": name or f"stage{i}",
                    "identified": bool(name),
                    "file_range": [lo, hi],
                    "size": hi - lo,
                    "state": state,
                    "entry_pc_file_offset": entry["stage_start"] if entry else None,
                    "vbar_writes": entry["vbar_writes"] if entry else [],
                    "encrypted_bytes": enc_bytes,
                    "evidence": {
                        "label_scores": scores,
                        "sample_strings": [s for _, s in strs[:6]],
                    },
                }
                if state == "exec":
                    stage.update({"base": derive_base(data, lo, hi)})
                stages.append(stage)

    return {
        "image_size": len(data),
        "arch": arch,
        "grid": grid,
        "entropy_runs": [r for r in runs if r["end"] - r["start"] >= grid],
        "encrypted_total": sum(r["end"] - r["start"] for r in runs if r["label"] == "enc"),
        "entry_stubs": stubs or [],
        "stages": stages,
        "notes": ([] if stubs is not None else
                  [f"arch={arch}: 진입 스텁 시그니처가 아직 정의되지 않았습니다. "
                   f"스테이지를 도출하지 못했으므로 BLOCKED_ARCH 로 정지하십시오 "
                   f"— '스테이지 없음'이 아닙니다."]),
    }


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("image")
    ap.add_argument("--arch", default="arm64", choices=("arm64", "arm32"))
    ap.add_argument("--profile", default=None, help="profiles/<name>.yaml 의 stage_hints 사용")
    ap.add_argument("--out", default=None, help="기본: <image 디렉터리>/stage_map.json")
    ap.add_argument("--grid", default="0x800", help="엔트로피 격자 크기 (기본 0x800)")
    ap.add_argument("--quiet", action="store_true")
    args = ap.parse_args()

    with open(args.image, "rb") as fh:
        data = fh.read()

    grid = int(args.grid, 0)
    result = build_map(data, args.arch, load_profile_hints(args.profile), grid)
    result["image"] = os.path.abspath(args.image)

    out = args.out or os.path.join(os.path.dirname(os.path.abspath(args.image)),
                                   "stage_map.json")
    with open(out, "w", encoding="utf-8") as fh:
        json.dump(result, fh, ensure_ascii=False, indent=2)

    if not args.quiet:
        print(f"stage_map: {out}")
        print(f"  arch={result['arch']}  이미지 {result['image_size']:,} B  "
              f"암호화 {result['encrypted_total']:,} B")
        for s in result["stages"]:
            base = s.get("base") or {}
            b = base.get("load_base")
            conf = base.get("confidence", "-")
            print(f"  [{s['index']}] {s['name']:<14} {s['state']:<9} "
                  f"0x{s['file_range'][0]:06x}-0x{s['file_range'][1]:06x} "
                  f"base={'0x%08x' % b if b is not None else '미도출':<12} ({conf})")
        for n in result["notes"]:
            print(f"  ! {n}")

    return 3 if result["notes"] else 0


if __name__ == "__main__":
    sys.exit(main())
