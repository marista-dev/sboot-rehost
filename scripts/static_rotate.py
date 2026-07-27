#!/usr/bin/env python3
"""static_rotate.py - keep the derivation record usable as it grows.

Every escalation appends a `### round N 재도출` subsection with its evidence to
STATIC.md / KERNEL_STATIC.md. That is the right thing to write - the evidence is
what makes a row trustworthy - but the file is read again by the analyst on every
later round, so on a long run it grows past 300 KB and each round costs more than
the one before. On the S921N run rounds went from six minutes to twenty while the
firmware stood still.

Rotation moves the OLD evidence prose out to an archive and keeps the thing the
loop actually reads: the stop-point table. Rows written inside the subsections
being archived are promoted into the main table first, so nothing derived is
lost - archiving without promoting would silently delete facts.

Usage:
  static_rotate.py <workdir> [--track 1|2] [--max-bytes N] [--keep N]

Output: JSON on stdout. A no-op is reported as rotated=false, never as an error.
"""
import argparse
import json
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from derived_facts import FENCE, HEADING, OWNER, ROW, SECTION  # noqa: E402

ARCHIVE_NAME = "static_archive.md"


def sections(lines):
    """(start, end) of the derived-stop-point section, or None."""
    start = None
    fenced = False
    for i, line in enumerate(lines):
        if FENCE.match(line):
            fenced = not fenced
            continue
        if fenced:
            continue
        head = HEADING.match(line)
        if not head:
            continue
        level = len(head.group(1))
        if start is None:
            if level <= 2 and SECTION in line:
                start = i
        elif level <= 2:
            return start, i
    return (start, len(lines)) if start is not None else None


def subsection_bounds(lines, start, end):
    """Index ranges of each `###`+ subsection inside the section."""
    bounds, fenced, opened = [], False, None
    for i in range(start + 1, end):
        if FENCE.match(lines[i]):
            fenced = not fenced
            continue
        if fenced:
            continue
        head = HEADING.match(lines[i])
        if head and len(head.group(1)) >= 3:
            if opened is not None:
                bounds.append((opened, i))
            opened = i
    if opened is not None:
        bounds.append((opened, end))
    return bounds


def is_row(line):
    stripped = line.strip()
    if not stripped.startswith("|"):
        return None
    match = ROW.match(stripped)
    if not match:
        return None
    if match.group(1).lower() in ("시그니처", "signature", "name"):
        return None
    cells = [c.strip() for c in stripped.strip("|").split("|")]
    if not any(OWNER.match(c.strip("` ")) for c in cells[1:]):
        return None
    return match.group(1)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("workdir")
    parser.add_argument("--track", type=int, default=1)
    parser.add_argument("--max-bytes", type=int, default=120000,
                        help="rotate only once the record is larger than this")
    parser.add_argument("--keep", type=int, default=3,
                        help="how many recent escalation subsections stay inline")
    args = parser.parse_args()

    path = os.path.join(
        args.workdir, "KERNEL_STATIC.md" if args.track == 2 else "STATIC.md")
    result = {"source": path, "rotated": False, "promoted": 0, "archived": 0}

    if not os.path.exists(path):
        result["reason"] = "기록 파일이 아직 없습니다"
        print(json.dumps(result, ensure_ascii=False, indent=2))
        return

    size = os.path.getsize(path)
    result["bytes_before"] = size
    if size <= args.max_bytes:
        result["reason"] = f"{size}B — 아직 회전 기준({args.max_bytes}B) 이하"
        print(json.dumps(result, ensure_ascii=False, indent=2))
        return

    with open(path, encoding="utf-8", errors="replace") as fh:
        lines = fh.read().splitlines(keepends=True)

    found = sections(lines)
    if not found:
        result["reason"] = "도출 표 섹션을 찾지 못했습니다"
        print(json.dumps(result, ensure_ascii=False, indent=2))
        return

    start, end = found
    subs = subsection_bounds(lines, start, end)
    older = subs[:-args.keep] if args.keep > 0 else subs
    if not older:
        result["reason"] = f"보관 대상 하위 절 없음 (최근 {args.keep}개만 존재)"
        print(json.dumps(result, ensure_ascii=False, indent=2))
        return

    # Rows written inside the subsections we are about to archive. They must land
    # in the main table before the prose leaves, or the archive would take facts
    # with it.
    promoted = {}
    for lo, hi in older:
        for i in range(lo, hi):
            signature = is_row(lines[i])
            if signature:
                promoted[signature] = lines[i] if lines[i].endswith("\n") else lines[i] + "\n"

    # The main table is the last run of table lines before the first subsection.
    preamble_end = older[0][0]
    table_last = None
    for i in range(start + 1, preamble_end):
        if lines[i].strip().startswith("|"):
            table_last = i
    if table_last is None:
        result["reason"] = "본문 표를 찾지 못해 회전하지 않았습니다 (안전 정지)"
        print(json.dumps(result, ensure_ascii=False, indent=2))
        return

    # A promoted signature that already has a row supersedes it: re-derivation
    # corrects the earlier record rather than sitting next to it.
    existing = {}
    for i in range(start + 1, preamble_end):
        signature = is_row(lines[i])
        if signature:
            existing[signature] = i
    for signature, row in list(promoted.items()):
        if signature in existing:
            lines[existing[signature]] = row
            del promoted[signature]

    archive_path = os.path.join(args.workdir, "08_docs", ARCHIVE_NAME)
    os.makedirs(os.path.dirname(archive_path), exist_ok=True)
    archived_text = "".join("".join(lines[lo:hi]) for lo, hi in older)
    with open(archive_path, "a", encoding="utf-8") as fh:
        fh.write(f"\n<!-- {os.path.basename(path)} 에서 이관 -->\n")
        fh.write(archived_text)

    pointer = (f"\n> 오래된 재도출 근거 {len(older)}건은 "
               f"`08_docs/{ARCHIVE_NAME}` 로 옮겼습니다. "
               f"표의 행은 모두 위 본문 표에 남아 있습니다.\n\n")

    out = []
    out.extend(lines[:table_last + 1])
    out.extend(promoted.values())
    out.extend(lines[table_last + 1:older[0][0]])
    out.append(pointer)
    out.extend(lines[older[-1][1]:])

    with open(path, "w", encoding="utf-8") as fh:
        fh.write("".join(out))

    result.update({
        "rotated": True,
        "promoted": len(promoted),
        "archived": len(older),
        "archive": archive_path,
        "bytes_after": os.path.getsize(path),
    })
    print(json.dumps(result, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
