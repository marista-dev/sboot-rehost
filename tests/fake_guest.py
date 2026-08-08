#!/usr/bin/env python3
"""fake_guest.py - a stand-in for QEMU + the machine, for harness tests.

It reproduces the three things about a real bootloader that the harness has to
cope with, and nothing else:

  1. the autoboot gate opens at a moment the harness cannot predict, and takes a
     run of N bytes in one go - short, and it boots on;
  2. the console is chatty before the gate and the prompt appears after it;
  3. the machine may or may not report RX consumption on stderr, because older
     workspaces were built before those counters existed.

Usage (all times are seconds from start):
  fake_guest.py --gate-at 1.0 --gate-count 10 --prompt 'S-BOOT # '
                [--run 8] [--rx-report] [--never-prompt]
"""
import argparse
import collections
import sys
import threading
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--gate-at", type=float, default=1.0,
                        help="when the autoboot gate polls the console")
    parser.add_argument("--gate-count", type=int, default=10,
                        help="bytes the gate needs to be sitting there")
    parser.add_argument("--prompt", default="S-BOOT # ")
    parser.add_argument("--run", type=float, default=8.0)
    parser.add_argument("--rx-report", action="store_true",
                        help="emit the machine's REHOST-RX lines on stderr")
    parser.add_argument("--never-prompt", action="store_true",
                        help="the gate is never satisfied, whatever arrives")
    args = parser.parse_args()

    rx = collections.deque()
    lock = threading.Lock()
    served = [0]
    empty = [0]
    polls = [0]

    def reader():
        while True:
            chunk = sys.stdin.buffer.read(1)
            if not chunk:
                return
            with lock:
                rx.append(chunk)

    threading.Thread(target=reader, daemon=True).start()

    def report():
        if not args.rx_report:
            return
        with lock:
            queued = len(rx)
        sys.stderr.write(f"REHOST-RX s={served[0]} e={empty[0]} "
                         f"p={polls[0]} q={queued}\n")
        sys.stderr.flush()

    def take(n):
        """Consume up to n bytes, counting the way the machine model counts."""
        out = b""
        for _ in range(n):
            polls[0] += 1
            with lock:
                if rx:
                    out += rx.popleft()
                    served[0] += 1
                    drained = not rx
                else:
                    empty[0] += 1
                    drained = False
                    break
            if drained:
                report()
        if not out:
            empty[0] += 1
            report()
        return out

    def say(text):
        sys.stdout.write(text)
        sys.stdout.flush()

    started = time.time()
    line = 0
    while time.time() - started < args.gate_at:
        line += 1
        say(f"[0: {time.time() - started:9.6f}] boot log line {line}\n")
        time.sleep(0.05)

    grabbed = take(args.gate_count)
    passed = len(grabbed) >= args.gate_count and not args.never_prompt
    report()

    if not passed:
        # The gate was not satisfied, so the bootloader boots on. This is the
        # failure the harness must be able to tell apart from a firmware fault.
        say("check sbl_shell mode\n")
        while time.time() - started < args.run:
            line += 1
            say(f"[0: {time.time() - started:9.6f}] autoboot line {line}\n")
            time.sleep(0.05)
        return 0

    say("\nautoboot aborted..\n")
    say(args.prompt)
    pending = b""
    while time.time() - started < args.run:
        got = take(64)
        if not got:
            time.sleep(0.02)
            continue
        pending += got
        while b"\r" in pending:
            cmd, pending = pending.split(b"\r", 1)
            text = cmd.decode("latin-1").strip()
            if text:
                say(f"\n{text}\nFollowing commands are supported:\n* help\n")
            say(args.prompt)
    return 0


if __name__ == "__main__":
    sys.exit(main())
