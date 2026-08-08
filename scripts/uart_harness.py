#!/usr/bin/env python3
"""uart_harness.py - drive the guest's UART from OUTSIDE the machine.

Why this exists
---------------
A bootloader's autoboot gate is one-shot: it polls the console for a specific
input pattern - typically several carriage returns in a row - and if it does not
see it, it stops listening and boots on. Reaching the surface therefore depends
on input arriving WHILE the gate is polling, and on it being the pattern the gate
checks for. Input comes from here, a process outside QEMU, because a machine that
seeds its own RX buffer types its own commands and a surface reached that way is
verifying itself (honesty rule 7).

Three states, and no fourth
---------------------------
The previous version ran one loop that mixed supplying the pattern, watching for
the prompt and sending the command, and tied all three to one wall-clock fraction
of the budget (65%). Past that point it fired the command blind and stopped
offering the pattern entirely. The S921N logs show what that costs: run 7, 8 and 9
ALL ended with "command (prompt not observed)" - including the two runs that did
reach the shell. The designed branch (see the prompt -> send the command) never
executed once, and the last 35% of every round had nothing to give a gate that
opened late.

So the work is split into states with no give-up:

  SUPPLY    keep the pattern in front of the gate. Runs until the prompt appears
            or the budget ends - never until a guessed fraction of it.
  DISPATCH  prompt seen: stop supplying, send the command exactly once.
  COLLECT   read console only.

If the prompt never appears the command is NOT sent and the summary says so. A
run that could not reach the surface has to look like one.

Knowing when to refill
----------------------
The machine can report RX consumption on stderr (see machine.c.tmpl,
REHOST_RX_REPORT). When those lines are present the harness refills only once the
buffer has actually drained, so the gate gets its run of bytes without burying
the later command under a hundred empty command lines. When they are absent -
an older machine, or one built before the counters existed - it falls back to
"the console went quiet, so the firmware is probably blocked on a poll".

Usage:
  uart_harness.py --console <file> --input-log <file> [--plan <json>]
                  [--summary <json>] [--timeout N] [--cmd help]
                  [--prompt-token STR] [--surface shell|fastboot]
                  -- <qemu> <args...>

The QEMU command must NOT carry -serial: this attaches the guest console to the
process pipes instead.

Exit code: QEMU's, or 124 when the timeout expired (the normal end of a round).
"""
import argparse
import json
import os
import re
import subprocess
import sys
import threading
import time

DEFAULT_CR_COUNT = 3        # honest fallback, reported as a default
DEFAULT_INTERVAL = 0.05     # polling step; small so the prompt is noticed quickly
MIN_RESEND = 0.3            # gap between two refills; polling is faster than typing
QUIET_RESEND = 0.4          # fallback: console silent this long -> firmware is waiting
MAX_REFILLS = 40            # bound on how much we may pour in; reported when hit

# The machine's out-of-band consumption report (machine.c.tmpl rehost_rx_report).
# It goes to stderr, never to the console, so it cannot contaminate the guest
# output that verification reads. Single-letter fields: s served, e empty,
# p status polls, q still queued - short enough that no console token can
# collide with them in verify.py item 3.
RX_REPORT = re.compile(
    r"REHOST-RX\s+s=(\d+)\s+e=(\d+)\s+p=(\d+)\s+q=(\d+)")


def load_plan(path):
    """The derived input plan, or an honest default.

    The pattern is a property of the firmware - the gate counts a specific number
    of a specific byte, and some gates fail on a single empty poll - so
    static-analyzer derives it and writes it here. Hardcoding one vendor's gate
    would strand every other bootloader.

    `contiguous` and `empty_poll_budget` used to live only in the human-readable
    `evidence` prose. On S921N that prose said, correctly, "w21=0, so one empty
    poll fails it" - and nothing in the code could read it. Undeclared now means
    the strictest reading: a generous guess fails silently, a strict one costs a
    few extra carriage returns.
    """
    plan = {
        "byte": "\r",
        "count": DEFAULT_CR_COUNT,
        "contiguous": True,
        "empty_poll_budget": 0,
        "one_shot": True,
        "gate_addr": None,
        "source": "default",
        "evidence": "",
    }
    if not path or not os.path.exists(path):
        return plan
    try:
        with open(path, encoding="utf-8") as fh:
            data = json.load(fh)
    except (OSError, ValueError):
        return plan
    gate = data.get("autoboot_interrupt") or {}
    if not gate:
        return plan
    raw = gate.get("bytes")
    if isinstance(raw, str) and raw:
        plan["byte"] = raw.encode().decode("unicode_escape")
    if isinstance(gate.get("count"), int) and gate["count"] > 0:
        plan["count"] = gate["count"]
    if isinstance(gate.get("contiguous"), bool):
        plan["contiguous"] = gate["contiguous"]
    if isinstance(gate.get("empty_poll_budget"), int) and gate["empty_poll_budget"] >= 0:
        plan["empty_poll_budget"] = gate["empty_poll_budget"]
    if isinstance(gate.get("one_shot"), bool):
        plan["one_shot"] = gate["one_shot"]
    plan["gate_addr"] = gate.get("gate_addr")
    plan["evidence"] = gate.get("evidence", "")
    plan["source"] = "derived"
    return plan


class Guest:
    """QEMU plus the two things we learn from it: console text and RX reports."""

    def __init__(self, argv):
        self.proc = subprocess.Popen(argv, stdin=subprocess.PIPE,
                                     stdout=subprocess.PIPE,
                                     stderr=subprocess.PIPE)
        self.lock = threading.Lock()
        self.seen = bytearray()          # console tail, for prompt matching
        self.console_len = 0             # total, not just the retained tail
        # None until the machine reports; that distinction matters, because
        # "the machine never told us" and "the firmware never read" are
        # different facts and only one of them is about the firmware.
        self.rx_served = None
        self.rx_empty = None
        self.rx_polls = None
        self.rx_pending = None
        self.rx_reports = 0

    def start_readers(self, console_file):
        threading.Thread(target=self._pump_stdout, args=(console_file,),
                         daemon=True).start()
        threading.Thread(target=self._pump_stderr, daemon=True).start()

    def _pump_stdout(self, console_file):
        while True:
            chunk = self.proc.stdout.read(1)
            if not chunk:
                return
            console_file.write(chunk)
            with self.lock:
                self.seen.extend(chunk)
                self.console_len += 1
                if len(self.seen) > 65536:      # only the tail is ever matched
                    del self.seen[:32768]

    def _pump_stderr(self):
        """Parse the RX report, then pass every line through untouched.

        run_qemu.sh redirects this process's stderr into qemu_<n>.stderr.txt and
        the machine's diagnostics are read from there, so consuming the pipe
        without forwarding would delete them. QEMU's own startup errors are also
        how a run that never began gets diagnosed.
        """
        for raw in self.proc.stderr:
            match = RX_REPORT.search(raw.decode("utf-8", errors="replace"))
            if match:
                with self.lock:
                    (self.rx_served, self.rx_empty,
                     self.rx_polls, self.rx_pending) = (int(g) for g in match.groups())
                    self.rx_reports += 1
            try:
                sys.stderr.buffer.write(raw)
                sys.stderr.buffer.flush()
            except (BrokenPipeError, ValueError):
                pass

    def snapshot(self):
        with self.lock:
            return {
                "console_len": self.console_len,
                "served": self.rx_served,
                "pending": self.rx_pending,
                "polls": self.rx_polls,
                "reports": self.rx_reports,
                "have_reports": self.rx_reports > 0,
            }

    def prompt_seen(self, token):
        if not token:
            return False
        with self.lock:
            return token.encode() in self.seen


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--console", required=True)
    parser.add_argument("--input-log", required=True)
    parser.add_argument("--plan", default=None)
    parser.add_argument("--summary", default=None,
                        help="where to write the machine-readable run summary; "
                             "defaults to input_summary.json beside the input log")
    parser.add_argument("--timeout", type=float, default=8.0)
    parser.add_argument("--cmd", default="help")
    parser.add_argument("--prompt-token", default=None,
                        help="console text meaning the surface is up; when seen, "
                             "the harness stops interrupting and sends the command")
    parser.add_argument("--surface", default="shell")
    parser.add_argument("qemu", nargs=argparse.REMAINDER)
    args = parser.parse_args()

    qemu = [a for a in args.qemu if a != "--"]
    if not qemu:
        print("uart_harness: QEMU 명령이 필요합니다", file=sys.stderr)
        return 2

    plan = load_plan(args.plan)
    pattern = (plan["byte"] * plan["count"]).encode()
    summary_path = args.summary or os.path.join(
        os.path.dirname(os.path.abspath(args.input_log)), "input_summary.json")

    console = open(args.console, "wb", buffering=0)
    inlog = open(args.input_log, "w", encoding="utf-8")
    inlog.write("# 하니스가 보낸 입력 (머신이 만든 것이 아님)\n")
    inlog.write(f"# 인터럽트 패턴: {plan['byte']!r} x{plan['count']} ({plan['source']}, "
                f"contiguous={plan['contiguous']}, "
                f"empty_poll_budget={plan['empty_poll_budget']})\n")
    inlog.flush()

    guest = Guest(qemu)
    guest.start_readers(console)

    sent_bytes = 0
    refills = 0
    # Bytes written since the last report we saw. The machine reports what is
    # queued at the moment it drains, so without this the harness would keep
    # reading a stale "queue is empty" and pour a refill in every cycle.
    sent_since_report = 0

    def send(data, note):
        nonlocal sent_bytes, sent_since_report
        try:
            # One write for the whole pattern: a gate with empty_poll_budget 0
            # fails if the run of bytes is broken by a single empty poll, so the
            # burst must not be split across writes.
            guest.proc.stdin.write(data)
            guest.proc.stdin.flush()
        except (BrokenPipeError, ValueError):
            return False
        sent_bytes += len(data)
        sent_since_report += len(data)
        inlog.write(f"{time.time():.3f} {note}: {data!r}\n")
        inlog.flush()
        return True

    started = time.time()
    deadline = started + args.timeout
    state = "SUPPLY"
    prompt_at = None
    command_sent = False
    supply_capped = False
    last_send = 0.0
    last_console_len = 0
    last_console_change = started
    last_reports_seen = 0
    rc = None

    # Prime immediately: a gate that opens early is the case a first shot at t=0
    # is for, and the buffer holds the bytes until something reads them.
    if send(pattern, "autoboot 중단 시도 (최초 공급)"):
        last_send = started
        refills = 1

    while time.time() < deadline:
        rc = guest.proc.poll()
        if rc is not None:
            break

        now = time.time()
        snap = guest.snapshot()
        if snap["console_len"] != last_console_len:
            last_console_len = snap["console_len"]
            last_console_change = now
        if snap["reports"] != last_reports_seen:
            last_reports_seen = snap["reports"]
            sent_since_report = 0

        if state == "SUPPLY":
            if guest.prompt_seen(args.prompt_token):
                prompt_at = now - started
                state = "DISPATCH"
                continue
            if refills < MAX_REFILLS and now - last_send >= MIN_RESEND:
                if snap["have_reports"]:
                    # The machine tells us what is left. Top up when the gate
                    # could be starved, and stop pouring once it cannot be.
                    queued = (snap["pending"] or 0) + sent_since_report
                    due = queued < plan["count"]
                else:
                    # No report channel: a console that has stopped growing is
                    # the firmware sitting in a poll, which is when a refill can
                    # actually be taken.
                    due = now - last_console_change >= QUIET_RESEND
                if due and send(pattern, "autoboot 중단 시도"):
                    last_send = now
                    refills += 1
            elif refills >= MAX_REFILLS and not supply_capped:
                supply_capped = True
                inlog.write(f"# 공급 상한 {MAX_REFILLS} 회 도달 — 더 붓지 않고 "
                            f"프롬프트만 기다립니다\n")
                inlog.flush()

        elif state == "DISPATCH":
            if args.surface == "shell" and not command_sent:
                command_sent = send(args.cmd.encode() + b"\r", "명령 (프롬프트 관측 후)")
            state = "COLLECT"

        time.sleep(DEFAULT_INTERVAL)

    # The prompt can land in the last polling interval; check once more so a run
    # that did reach the surface is not reported as one that did not.
    if prompt_at is None and guest.prompt_seen(args.prompt_token):
        prompt_at = time.time() - started

    if rc is None:
        guest.proc.terminate()
        try:
            guest.proc.wait(timeout=3)
        except subprocess.TimeoutExpired:
            guest.proc.kill()
        rc = 124                      # the normal end of a round

    time.sleep(0.2)                   # let the reader threads drain the pipes
    console.close()

    snap = guest.snapshot()
    summary = {
        "pattern": plan["byte"],
        "count": plan["count"],
        "source": plan["source"],
        "contiguous": plan["contiguous"],
        "empty_poll_budget": plan["empty_poll_budget"],
        "gate_addr": plan["gate_addr"],
        "surface": args.surface,
        "prompt_token": args.prompt_token or "",
        "timeout_s": args.timeout,
        "elapsed_s": round(time.time() - started, 3),
        "bytes_sent": sent_bytes,
        "supply_attempts": refills,
        "supply_capped": supply_capped,
        "prompt_seen": prompt_at is not None,
        "prompt_seen_at_s": round(prompt_at, 3) if prompt_at is not None else None,
        "command_sent": command_sent,
        # The old harness fired the command without ever seeing the prompt and
        # called it a round. It is kept as an explicit field so a run can never
        # again claim the surface on the strength of a blind write.
        "command_blind": False,
        "rx_reported": snap["have_reports"],
        "rx_served": snap["served"],
        "rx_pending": snap["pending"],
        "rx_polls": snap["polls"],
        "exit_code": rc,
    }
    # The gate was looking and we had nothing to give it. That is a harness
    # failure, not a decision the firmware made, and the two must not be
    # recorded as the same observation.
    summary["input_starved"] = bool(
        snap["have_reports"] and (snap["polls"] or 0) > 0 and (snap["served"] or 0) == 0)
    summary["input_offered"] = sent_bytes > 0

    with open(summary_path, "w", encoding="utf-8") as fh:
        json.dump(summary, fh, ensure_ascii=False, indent=2)

    inlog.write(f"# 종료 rc={rc}, 프롬프트 관측={summary['prompt_seen']}, "
                f"명령 전송={command_sent}, 공급 {refills}회/{sent_bytes}B")
    if snap["have_reports"]:
        inlog.write(f", 펌웨어가 읽은 바이트={snap['served']} "
                    f"(폴링 {snap['polls']}, 남은 {snap['pending']})")
    inlog.write("\n")
    inlog.close()

    if not summary["prompt_seen"]:
        print("uart_harness: 프롬프트를 관측하지 못해 명령을 보내지 않았습니다 "
              f"(표면 미도달, {summary_path})", file=sys.stderr)
    if summary["input_starved"]:
        print("uart_harness: ★ 펌웨어가 콘솔을 폴링했으나 우리 바이트를 한 번도 "
              "읽지 않았습니다 — 하니스 문제이지 펌웨어 판정이 아닙니다", file=sys.stderr)
    return rc


if __name__ == "__main__":
    sys.exit(main())
