#!/usr/bin/env python3
"""uart_harness.py - drive the guest's UART from OUTSIDE the machine.

Why this exists
---------------
A bootloader's autoboot gate is one-shot: it polls the console for a specific
input pattern - typically several carriage returns in a row - and if it does not
see it, it stops listening and boots on. Reaching the shell therefore depends on
input arriving WHILE the gate is polling, and on it being the pattern the gate
checks for.

The run script used `-serial file:` (output only), so no input path existed at
all, and the machine model seeded its own RX buffer once at reset with the
command. Three things were wrong with that:

  1. the seeded bytes were `help\\r`, not the CR run the gate counts, so the gate
     could never be satisfied and every round polled it forever;
  2. one shot at t=0 cannot be timed against a gate that opens later;
  3. a machine that types its own commands is verifying itself - honesty rule 7,
     and what verify.py item 4 refuses on the fastboot surface.

So input comes from here, a process outside QEMU, and every byte sent is written
to the input log so a reader can check what we typed versus what the firmware
printed.

Usage:
  uart_harness.py --console <file> --input-log <file> [--plan <json>]
                  [--timeout N] [--cmd help] [--prompt-token STR]
                  [--surface shell|fastboot] -- <qemu> <args...>

The QEMU command must NOT carry -serial: this attaches the guest console to the
process pipes instead.

Exit code: QEMU's, or 124 when the timeout expired (the normal end of a round).
"""
import argparse
import json
import os
import subprocess
import sys
import threading
import time

DEFAULT_CR_COUNT = 3        # honest fallback, reported as a default
DEFAULT_INTERVAL = 0.25     # seconds between attempts while the gate may be open
GATE_WINDOW = 0.65          # fraction of the budget spent trying to interrupt


def load_plan(path):
    """The derived input plan, or an honest default.

    The pattern is a property of the firmware (the gate counts a specific number
    of a specific byte), so static-analyzer derives it and writes it here.
    Hardcoding one vendor's pattern would strand every other bootloader.
    """
    plan = {"byte": "\r", "count": DEFAULT_CR_COUNT, "source": "default"}
    if not path or not os.path.exists(path):
        return plan
    try:
        with open(path, encoding="utf-8") as fh:
            data = json.load(fh)
    except (OSError, ValueError):
        return plan
    gate = data.get("autoboot_interrupt") or {}
    raw = gate.get("bytes")
    if isinstance(raw, str) and raw:
        plan["byte"] = raw.encode().decode("unicode_escape")
    if isinstance(gate.get("count"), int) and gate["count"] > 0:
        plan["count"] = gate["count"]
    plan["source"] = "derived"
    plan["evidence"] = gate.get("evidence", "")
    return plan


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--console", required=True)
    parser.add_argument("--input-log", required=True)
    parser.add_argument("--plan", default=None)
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

    console = open(args.console, "wb", buffering=0)
    inlog = open(args.input_log, "w", encoding="utf-8")
    inlog.write(f"# 하니스가 보낸 입력 (머신이 만든 것이 아님)\n")
    inlog.write(f"# 인터럽트 패턴: {plan['byte']!r} x{plan['count']} ({plan['source']})\n")
    inlog.flush()

    # stderr is inherited on purpose: QEMU's startup errors are how a run that
    # never began is diagnosed, and swallowing them is what made a dead QEMU look
    # like a clean round in the first place.
    proc = subprocess.Popen(qemu, stdin=subprocess.PIPE, stdout=subprocess.PIPE)

    seen = bytearray()
    lock = threading.Lock()

    def pump():
        while True:
            chunk = proc.stdout.read(1)
            if not chunk:
                return
            console.write(chunk)
            with lock:
                seen.extend(chunk)
                if len(seen) > 65536:      # only the tail is ever matched against
                    del seen[:32768]

    reader = threading.Thread(target=pump, daemon=True)
    reader.start()

    def send(data, note):
        try:
            proc.stdin.write(data)
            proc.stdin.flush()
        except (BrokenPipeError, ValueError):
            return False
        inlog.write(f"{time.time():.3f} {note}: {data!r}\n")
        inlog.flush()
        return True

    def surface_up():
        if not args.prompt_token:
            return False
        with lock:
            return args.prompt_token.encode() in seen

    started = time.time()
    deadline = started + args.timeout
    gate_until = started + args.timeout * GATE_WINDOW
    sent_cmd = False
    rc = None

    # Phase 1 - keep offering the interrupt pattern while the gate may be open.
    # Repeating matters: the gate opens at a point in the boot we cannot predict,
    # and a single shot at reset is a guess about timing.
    while time.time() < deadline:
        rc = proc.poll()
        if rc is not None:
            break
        if args.surface == "shell" and not sent_cmd:
            if surface_up():
                send(args.cmd.encode() + b"\r", "명령")
                sent_cmd = True
            elif time.time() < gate_until:
                if not send(pattern, "autoboot 중단 시도"):
                    break
            else:
                # The window closed without a prompt. Send the command once
                # anyway: if the surface did come up without printing a token we
                # would recognise, the dispatch still shows in the trace.
                send(args.cmd.encode() + b"\r", "명령 (프롬프트 미관측)")
                sent_cmd = True
        time.sleep(DEFAULT_INTERVAL)

    if rc is None:
        proc.terminate()
        try:
            proc.wait(timeout=3)
        except subprocess.TimeoutExpired:
            proc.kill()
        rc = 124                      # the normal end of a round

    reader.join(timeout=2)
    console.close()
    inlog.write(f"# 종료 rc={rc}, 프롬프트 관측={surface_up()}\n")
    inlog.close()
    return rc


if __name__ == "__main__":
    sys.exit(main())
