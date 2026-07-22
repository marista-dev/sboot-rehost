#!/usr/bin/env python3
"""derived_facts.py - measure what the analyst actually added, instead of asking it.

The loop needs to know whether a re-derivation produced anything new. Asking the
analyst ("how many new facts did you find?") makes the stop condition depend on a
self-reported number that nothing can contradict, so the same address gets
"newly derived" every round and the loop never ends.

The analyst appends its findings to one record per firmware - the `## 도출된 정지점`
table in STATIC.md / KERNEL_STATIC.md. This script parses that table, remembers
every signature it has already seen in derived_facts.jsonl, and reports how many
are new. Re-deriving the same stop point adds no row, so `new` is 0 and the
exhaustion condition becomes a fact rather than a claim.

Usage:
  derived_facts.py <workdir> [--track 1|2] [--peek]

  --peek   report without recording, so a caller can look without consuming

Output: JSON on stdout
"""
import argparse
import json
import os
import re
import sys

SECTION = "도출된 정지점"
ROW = re.compile(r"^\|\s*`?([A-Za-z0-9_]+)`?\s*\|(.*)$")


def parse_table(path):
    """Rows of the derived-stop-point table, in file order."""
    if not os.path.exists(path):
        return []
    rows, inside = [], False
    with open(path, encoding="utf-8", errors="replace") as fh:
        for line in fh:
            stripped = line.strip()
            if stripped.startswith("#"):
                inside = SECTION in stripped
                continue
            if not inside or not stripped.startswith("|"):
                continue
            match = ROW.match(stripped)
            if not match:
                continue
            signature = match.group(1)
            # skip the header and its |---|---| separator
            if signature.lower() in ("시그니처", "signature", "name"):
                continue
            cells = [c.strip() for c in stripped.strip("|").split("|")]
            rows.append({
                "signature": signature,
                "observation": cells[1] if len(cells) > 1 else "",
                "mechanism": cells[2] if len(cells) > 2 else "",
                "fixer": cells[3].strip("`") if len(cells) > 3 else "",
                "treatment": cells[4] if len(cells) > 4 else "",
            })
    return rows


def read_seen(path):
    if not os.path.exists(path):
        return []
    seen = []
    with open(path, encoding="utf-8") as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                seen.append(json.loads(line))
            except json.JSONDecodeError:
                continue
    return seen


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("workdir")
    parser.add_argument("--track", type=int, default=1)
    parser.add_argument("--peek", action="store_true",
                        help="report without recording")
    args = parser.parse_args()

    static = os.path.join(
        args.workdir, "KERNEL_STATIC.md" if args.track == 2 else "STATIC.md")
    ledger = os.path.join(args.workdir, "derived_facts.jsonl")

    rows = parse_table(static)
    seen = {r.get("signature") for r in read_seen(ledger)}
    fresh = [r for r in rows if r["signature"] not in seen]

    if fresh and not args.peek:
        with open(ledger, "a", encoding="utf-8") as fh:
            for row in fresh:
                fh.write(json.dumps(row, ensure_ascii=False) + "\n")

    json.dump({
        "source": static,
        "source_exists": os.path.exists(static),
        "total": len(rows),
        "new": len(fresh),
        "new_signatures": [r["signature"] for r in fresh],
        # Everything derived so far, so the classifier and the fixers can match
        # against it without re-reading the markdown themselves.
        "stop_points": rows,
    }, sys.stdout, ensure_ascii=False, indent=2)
    sys.stdout.write("\n")


if __name__ == "__main__":
    main()
