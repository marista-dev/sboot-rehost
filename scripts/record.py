#!/usr/bin/env python3
"""record.py - append run measurements to JSONL as they happen.

JOURNAL.md (via journal.sh) carries the human-readable record; this script
carries the **machine-readable measurements**. Timestamps always come from the
real system clock - never fabricated or reconstructed after the fact.

Three streams, written at the workdir root:

  metrics.jsonl   time, tokens and other measurement events, appended per stage
  rounds.jsonl    one line per round (fingerprint / category / fixer / effect).
                  Feeds the stop conditions and prevents retrying a change.
  blockers.jsonl  hard blockers observed **as fact** (structurally unreachable).
                  These are the stop inputs the supervisor cannot argue with.

Usage:
  record.py <workdir> start   <timer>
  record.py <workdir> metric  [k=v ...]
  record.py <workdir> round   [k=v ...]
  record.py <workdir> blocker code=<CODE> [k=v ...]

Value rules for k=v:
  - integers, floats, true, false and null keep their JSON type
  - hex literals (0x...) stay strings, since addresses are compared as text
  - "none" stays the string "none"; it is a valid milestone value
  - timer=<name> adds elapsed_s measured from the matching `start`
  - ts (ISO8601 with offset) and epoch are always added

Examples:
  record.py "$WD" start run12
  record.py "$WD" metric phase=Run round=12 event=run_end timer=run12 \\
            exceptions=3 console_bytes=308 tokens_total=124300
  record.py "$WD" round round=12 goal=link_up fp_far=0x12860010 \\
            category=pwrmode_timeout fixer=fixer-storage effect=progress
  record.py "$WD" blocker code=BLOCKED_KO detail="target=K3 인데 벤더 .ko 가 없습니다"
"""
import json
import os
import sys
import time
from datetime import datetime

STREAMS = {
    "metric": "metrics.jsonl",
    "round": "rounds.jsonl",
    "blocker": "blockers.jsonl",
}


def state_dir(workdir):
    path = os.path.join(workdir, "08_docs", ".record")
    os.makedirs(path, exist_ok=True)
    return path


def coerce(text):
    """Convert a k=v value to its JSON type.

    Hex literals stay strings on purpose: an address is the backbone of the
    fingerprint comparison, so converting 0x12860010 to an integer would both
    diverge from how the logs print it and erase any case distinction.
    "none" is left alone because it is a legitimate milestone value.
    """
    low = text.lower()
    if low == "true":
        return True
    if low == "false":
        return False
    if low in ("null", ""):
        return None
    if low.startswith("0x") or low.startswith("-0x"):
        return text
    try:
        return int(text, 10)
    except ValueError:
        pass
    try:
        return float(text)
    except ValueError:
        pass
    return text


def parse_pairs(argv):
    fields = {}
    for arg in argv:
        if "=" not in arg:
            print(f"record: expected k=v, got: {arg}", file=sys.stderr)
            sys.exit(1)
        key, value = arg.split("=", 1)
        fields[key.strip()] = coerce(value)
    return fields


def stamp():
    now = datetime.now().astimezone()
    return now.strftime("%Y-%m-%dT%H:%M:%S%z"), int(time.time())


def start_timer(workdir, name):
    with open(os.path.join(state_dir(workdir), f"timer_{name}.epoch"), "w") as fh:
        fh.write(str(int(time.time())))
    print(f"record: timer '{name}' started")


def elapsed_for(workdir, name):
    path = os.path.join(state_dir(workdir), f"timer_{name}.epoch")
    if not os.path.exists(path):
        return None
    try:
        with open(path) as fh:
            return int(time.time()) - int(fh.read().strip())
    except (ValueError, OSError):
        return None


def append(workdir, stream, fields):
    ts, epoch = stamp()
    record = {"ts": ts, "epoch": epoch}

    timer = fields.get("timer")
    if isinstance(timer, str):
        seconds = elapsed_for(workdir, timer)
        if seconds is not None:
            record["elapsed_s"] = seconds

    record.update(fields)

    os.makedirs(workdir, exist_ok=True)
    path = os.path.join(workdir, STREAMS[stream])
    with open(path, "a", encoding="utf-8") as fh:
        fh.write(json.dumps(record, ensure_ascii=False) + "\n")
    print(f"record: {STREAMS[stream]} <- {json.dumps(record, ensure_ascii=False)}")


def main():
    if len(sys.argv) < 3:
        print(__doc__)
        sys.exit(1)

    workdir, op, rest = sys.argv[1], sys.argv[2], sys.argv[3:]

    if op == "start":
        if not rest:
            print("record: start needs a timer name", file=sys.stderr)
            sys.exit(1)
        start_timer(workdir, rest[0])
        return

    if op in STREAMS:
        fields = parse_pairs(rest)
        if op == "blocker" and "code" not in fields:
            print("record: blocker requires code=<CODE>", file=sys.stderr)
            sys.exit(1)
        append(workdir, op, fields)
        return

    print(f"record: unknown op '{op}'", file=sys.stderr)
    print(__doc__)
    sys.exit(1)


if __name__ == "__main__":
    main()
