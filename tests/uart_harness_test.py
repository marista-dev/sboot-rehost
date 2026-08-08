#!/usr/bin/env python3
"""uart_harness_test.py - regression tests for the input harness.

These run without QEMU: tests/fake_guest.py stands in for the guest. They exist
because the S921N logs showed the harness failing in a way no artifact flagged -
run 7, 8 and 9 all ended with the command fired blind, including the two runs
that reached the shell - so the designed path was never exercised and nothing
said so.

Case B is the one that matters. The old harness gave up on the gate at 65% of
the budget and fired the command without ever seeing the prompt; a gate that
opens at 80% could therefore never be reported honestly.

Usage:  python3 tests/uart_harness_test.py
Exit code 0 when every case passes.
"""
import json
import os
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
HARNESS = os.path.join(ROOT, "scripts", "uart_harness.py")
GUEST = os.path.join(HERE, "fake_guest.py")
PROMPT = "S-BOOT # "


def run_case(name, guest_args, timeout=4.0, plan=None):
    workdir = tempfile.mkdtemp(prefix="uart-harness-")
    console = os.path.join(workdir, "console.txt")
    inlog = os.path.join(workdir, "input.txt")
    summary = os.path.join(workdir, "input_summary.json")
    plan_path = None
    if plan is not None:
        plan_path = os.path.join(workdir, "input_plan.json")
        with open(plan_path, "w", encoding="utf-8") as fh:
            json.dump(plan, fh)

    cmd = [sys.executable, HARNESS,
           "--console", console, "--input-log", inlog, "--summary", summary,
           "--timeout", str(timeout), "--cmd", "help",
           "--prompt-token", PROMPT, "--surface", "shell"]
    if plan_path:
        cmd += ["--plan", plan_path]
    cmd += ["--", sys.executable, GUEST] + guest_args

    proc = subprocess.run(cmd, capture_output=True, timeout=timeout + 20)
    with open(summary, encoding="utf-8") as fh:
        got = json.load(fh)
    with open(console, "rb") as fh:
        text = fh.read().decode("latin-1")
    got["_console"] = text
    got["_prompts"] = text.count(PROMPT)
    got["_stderr"] = proc.stderr.decode("latin-1")
    return name, got, workdir


def check(name, got, expected):
    problems = []
    for key, want in expected.items():
        have = got.get(key)
        if have != want:
            problems.append(f"    {key}: 기대 {want!r} / 실제 {have!r}")
    if problems:
        print(f"[FAIL] {name}")
        print("\n".join(problems))
        return False
    print(f"[PASS] {name}")
    return True


def main():
    gate_count = 10
    plan = {"autoboot_interrupt": {"bytes": "\\r", "count": gate_count,
                                   "contiguous": True, "empty_poll_budget": 0,
                                   "gate_addr": "0xf4844f7c",
                                   "evidence": "test"}}
    ok = True

    # A - the gate opens early, inside any reasonable window.
    name, got, _ = run_case(
        "A 게이트가 창 안(0.8s)에서 열린다",
        ["--gate-at", "0.8", "--gate-count", str(gate_count),
         "--prompt", PROMPT, "--run", "4", "--rx-report"],
        timeout=4.0, plan=plan)
    ok &= check(name, got, {"prompt_seen": True, "command_sent": True,
                            "command_blind": False, "input_starved": False})

    # B - the gate opens at 80% of the budget. The old harness had already fired
    # the command blind by 65% and stopped supplying the pattern, so this case
    # could not be reported honestly. THIS IS THE REGRESSION.
    name, got, _ = run_case(
        "B 게이트가 창 밖(예산 80%)에서 열린다 ★ 핵심 회귀",
        ["--gate-at", "3.2", "--gate-count", str(gate_count),
         "--prompt", PROMPT, "--run", "5", "--rx-report"],
        timeout=4.0, plan=plan)
    ok &= check(name, got, {"prompt_seen": True, "command_sent": True,
                            "command_blind": False})

    # C - the surface never comes up. The command must not be sent: a run that
    # could not reach the surface has to look like one.
    name, got, _ = run_case(
        "C 표면이 끝까지 안 열린다 → 명령을 보내지 않는다",
        ["--gate-at", "0.8", "--gate-count", str(gate_count),
         "--prompt", PROMPT, "--run", "4", "--rx-report", "--never-prompt"],
        timeout=3.0, plan=plan)
    ok &= check(name, got, {"prompt_seen": False, "command_sent": False})

    # D - no RX report channel (a machine built before the counters). The
    # fallback must still reach the surface.
    name, got, _ = run_case(
        "D 머신이 RX 를 보고하지 않는다 (구 워크스페이스) → 폴백으로 도달",
        ["--gate-at", "1.2", "--gate-count", str(gate_count),
         "--prompt", PROMPT, "--run", "4"],
        timeout=4.0, plan=plan)
    ok &= check(name, got, {"prompt_seen": True, "command_sent": True,
                            "rx_reported": False})

    # E - the command must land as a command, not behind a hundred empty lines.
    # 92 empty prompts is what the S921N run actually produced.
    name, got, _ = run_case(
        "E 명령이 빈 줄 뒤에 묻히지 않는다",
        ["--gate-at", "0.8", "--gate-count", str(gate_count),
         "--prompt", PROMPT, "--run", "4", "--rx-report"],
        timeout=4.0, plan=plan)
    if got["_prompts"] > 6:
        print(f"[FAIL] {name}\n    프롬프트 재출력 {got['_prompts']} 회 — "
              f"잔여 패턴이 빈 명령줄로 소비되고 있습니다")
        ok = False
    elif "Following commands are supported" not in got["_console"]:
        print(f"[FAIL] {name}\n    명령이 실행되지 않았습니다")
        ok = False
    else:
        print(f"[PASS] {name} (프롬프트 {got['_prompts']} 회)")

    # F - the plan's derived fields reach the code, not just the evidence prose.
    name, got, _ = run_case(
        "F 도출된 게이트 성질이 요약에 실린다",
        ["--gate-at", "0.8", "--gate-count", str(gate_count),
         "--prompt", PROMPT, "--run", "3", "--rx-report"],
        timeout=3.0, plan=plan)
    ok &= check(name, got, {"count": gate_count, "contiguous": True,
                            "empty_poll_budget": 0, "source": "derived",
                            "gate_addr": "0xf4844f7c"})

    print()
    print("전부 통과" if ok else "실패한 항목이 있습니다")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
