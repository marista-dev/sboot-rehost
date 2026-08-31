#!/usr/bin/env python3
"""trace_filter.py - keep the part of a QEMU trace we actually read.

`-d int,in_asm,nochain` writes 10-12 GB per round on a firmware that faults in a
loop. Fifteen rounds filled a 281 GB disk and took WSL down with it. None of that
volume is consumed: the pipeline reads four things out of a trace.

  1. how many exceptions happened          (a count, not the lines)
  2. the FIRST exception block             (the origin - what needs fixing)
  3. the LAST FAR/ELR                      (kept for the record, not diagnosis)
  4. whether each stage entry PC appears, in order   (the chain-trace metric)

So this filter sits between QEMU and the log file and keeps exactly that, in
bounded space. It streams: memory stays flat however long the run goes.

Usage (QEMU writes into a FIFO, this reads it):
  mkfifo $F
  trace_filter.py --out run_3.log --stats st.json --watch 0xc9000000,0x2100000 < $F &
  qemu ... -D $F

Output is a normal text log, so everything downstream keeps working: the head
carries the first exception blocks, the tail carries the last matching lines, and
the middle is replaced by one line saying what was dropped.
"""
import argparse
import collections
import json
import re
import sys

EXC = re.compile(r"Taking exception")
# The lines the summary greps for. Anything matching is worth keeping in the tail.
KEEP = re.compile(r"Taking exception|FAR |ELR |ESR |UPLOAD|E_SYNC|panic|abort|smc",
                  re.I)


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--out", required=True, help="filtered log to write")
    ap.add_argument("--stats", default=None, help="JSON with the counts")
    ap.add_argument("--watch", default="",
                    help="comma-separated PCs to keep every first sighting of")
    ap.add_argument("--head-blocks", type=int, default=40,
                    help="exception blocks kept verbatim from the start")
    ap.add_argument("--block-lines", type=int, default=12,
                    help="lines kept per exception block")
    ap.add_argument("--tail-lines", type=int, default=400,
                    help="matching lines kept from the end")
    args = ap.parse_args()

    watch = []
    for w in args.watch.split(","):
        w = w.strip().lower()
        if w:
            watch.append(w if w.startswith("0x") else "0x" + w)

    head = []                       # verbatim start of the trace
    tail = collections.deque(maxlen=args.tail_lines)
    seen_pc = {}                    # pc -> line number of first sighting
    exc_total = 0
    lines_total = 0
    bytes_total = 0
    blocks_kept = 0
    in_block = 0

    for raw in sys.stdin:
        lines_total += 1
        bytes_total += len(raw)
        line = raw.rstrip("\n")

        if EXC.search(line):
            exc_total += 1
            if blocks_kept < args.head_blocks:
                blocks_kept += 1
                in_block = args.block_lines
        # A stage entry PC proves the chain walked. Only the FIRST sighting
        # matters, and order is what the metric checks, so record it once in the
        # order it happened. Checked before the block branch: an entry PC often
        # appears inside the exception block that faulted on it.
        low = line.lower()
        for pc in watch:
            if pc not in seen_pc and pc in low:
                seen_pc[pc] = lines_total
                if in_block <= 0:
                    head.append(f"[stage-entry {pc} @line {lines_total}] {line[:200]}")

        if in_block > 0:
            head.append(line)
            in_block -= 1
            continue

        if KEEP.search(line):
            tail.append(line)

    # A run that produced NO trace must leave an empty file. "trace and console
    # both zero bytes" is how the harness tells a QEMU that never started from a
    # firmware that faulted; writing a summary line here would erase that signal
    # and an environment failure would be reported as a verdict about the firmware.
    if lines_total == 0:
        open(args.out, "w").close()
        if args.stats:
            with open(args.stats, "w", encoding="utf-8") as fh:
                json.dump({"exceptions": 0, "lines_in": 0, "bytes_in": 0,
                           "lines_kept": 0, "stage_entries_seen": []},
                          fh, ensure_ascii=False, indent=2)
        return 0

    with open(args.out, "w", encoding="utf-8", errors="replace") as fh:
        for line in head:
            fh.write(line + "\n")
        fh.write(f"\n=== 중간 생략: 원본 {lines_total:,} 줄 / {bytes_total:,} B "
                 f"중 위 {len(head):,} 줄과 아래 {len(tail):,} 줄만 남겼습니다 "
                 f"(예외 {exc_total:,} 건) ===\n\n")
        for line in tail:
            fh.write(line + "\n")

    if args.stats:
        with open(args.stats, "w", encoding="utf-8") as fh:
            json.dump({
                "exceptions": exc_total,
                "lines_in": lines_total,
                "bytes_in": bytes_total,
                "lines_kept": len(head) + len(tail),
                "stage_entries_seen": [
                    {"pc": pc, "line": n}
                    for pc, n in sorted(seen_pc.items(), key=lambda kv: kv[1])
                ],
            }, fh, ensure_ascii=False, indent=2)
    return 0


if __name__ == "__main__":
    sys.exit(main())
