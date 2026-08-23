#!/usr/bin/env python3
"""record.py - append run measurements to JSONL as they happen.

JOURNAL.md (via journal.sh) carries the human-readable record; this script
carries the **machine-readable measurements**. Timestamps always come from the
real system clock - never fabricated or reconstructed after the fact.

Five streams, written at the workdir root:

  metrics.jsonl      time, tokens and other measurement events, per stage
  rounds.jsonl       one line per round (fingerprint / category / fixer / effect).
                     Feeds the stop conditions and prevents retrying a change.
                     **A round that names a fixer must carry `rationale`** - the
                     one line saying why that change. Without it the round cannot
                     be explained later, so it is flagged rationale_missing.
  blockers.jsonl     hard blockers observed **as fact** (structurally unreachable).
                     These are the stop inputs the supervisor cannot argue with.
  prompts.jsonl      **user input, verbatim.** What the person actually typed,
                     with the phase/round it landed in. A run that stalls is read
                     back through these, so the text is never summarised here.
  resolutions.jsonl  how a stop point was actually cleared: what was tried, what
                     worked, and the evidence. Feeds the ANALYSIS.md timeline.

Usage:
  record.py <workdir> start   <timer>
  record.py <workdir> metric  [k=v ...]
  record.py <workdir> round   [k=v ...]
  record.py <workdir> blocker code=<CODE> [k=v ...]
  record.py <workdir> prompt  --stdin=text [k=v ...]      # or text="..."
  record.py <workdir> resolution stop=<name> fix="..." [k=v ...]

Value rules for k=v:
  - integers, floats, true, false and null keep their JSON type
  - hex literals (0x...) stay strings, since addresses are compared as text
  - "none" stays the string "none"; it is a valid milestone value
  - timer=<name> adds elapsed_s measured from the matching `start`
  - ts (ISO8601 with offset) and epoch are always added
  - --stdin=<field> reads that field's value from stdin instead of argv, which
    is how multi-line prompt text keeps its newlines and quoting intact

Examples:
  record.py "$WD" start run12
  record.py "$WD" metric phase=Run round=12 event=run_end timer=run12 \\
            exceptions=3 console_bytes=308 tokens_total=124300
  record.py "$WD" round round=12 goal=link_up fp_far=0x12860010 \\
            category=pwrmode_timeout fixer=fixer-storage effect=progress \\
            rationale="FAR 이 PMU 창 안이라 그 창만 매핑"
  record.py "$WD" blocker code=BLOCKED_KO detail="벤더 .ko 가 없고 커널 빌트인도 아닙니다"
  printf '%s' "$USER_PROMPT" | record.py "$WD" prompt --stdin=text phase=Run round=12
  record.py "$WD" resolution stop=smc_undef tried=3 rounds=12-15 \\
            fix="SiP 0xc2001014 를 shim 에 추가" evidence=07_logs/console_15.txt
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
    "prompt": "prompts.jsonl",
    "resolution": "resolutions.jsonl",
}

# Fields an op cannot be written without. A line missing these is worse than no
# line: it looks like a record of something while naming neither the subject nor
# the outcome.
REQUIRED = {
    "blocker": ("code",),
    "prompt": ("text",),
    "resolution": ("stop", "fix"),
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


# Free-form prose that must survive as typed. Without this a prompt of "123"
# would land in the log as the integer 123, and a rationale of "0x40" would keep
# its quotes but lose the fact that it was written as prose, not an address.
VERBATIM = ("text", "fix", "rationale", "detail", "evidence", "note", "tried")


def parse_pairs(argv):
    fields = {}
    for arg in argv:
        if "=" not in arg:
            print(f"record: expected k=v, got: {arg}", file=sys.stderr)
            sys.exit(1)
        key, value = arg.split("=", 1)
        key = key.strip()
        fields[key] = value if key in VERBATIM else coerce(value)
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
        stdin_field = None
        pairs = []
        for arg in rest:
            if arg.startswith("--stdin="):
                stdin_field = arg.split("=", 1)[1].strip()
            else:
                pairs.append(arg)

        fields = parse_pairs(pairs)
        if stdin_field:
            # Verbatim: no strip, no coerce. Prompt text keeps its newlines, and
            # trailing whitespace can itself be part of what the person typed.
            fields[stdin_field] = sys.stdin.read()

        missing = [k for k in REQUIRED.get(op, ())
                   if k not in fields or fields[k] in (None, "")]
        if missing:
            print(f"record: {op} requires {', '.join(k + '=' for k in missing)}",
                  file=sys.stderr)
            sys.exit(1)

        # A round that names a fixer but not why it changed that place cannot be
        # explained later - not by the resume file, not by the analysis, not by
        # us. Flag it on the line rather than dropping the line: what ran is
        # still worth recording, and the flag is what says it is unexplained.
        if op == "round" and fields.get("fixer") and not fields.get("rationale"):
            print("record: round names a fixer without rationale= "
                  "- recorded as rationale_missing", file=sys.stderr)
            fields["rationale_missing"] = True

        append(workdir, op, fields)
        return

    print(f"record: unknown op '{op}'", file=sys.stderr)
    print(__doc__)
    sys.exit(1)


if __name__ == "__main__":
    main()
