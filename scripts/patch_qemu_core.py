#!/usr/bin/env python3
"""patch_qemu_core.py — faithful SMC 코어 3 패치 (QEMU 10.2.2 target/arm).
멱등. 전부 cpu->interrupt_handler != NULL 로 게이트 → virt 등 타 머신 무영향.

  1) cpu.h           : ARMCPU 에 `void (*interrupt_handler)(CPUState*)` 추가.
  2) tcg/op_helper.c : pre_smc 의 has_el3=false UDEF 2 경로를 핸들러 설정 시 우회 → SMC→EXCP_SMC.
  3) helper.c        : EXCP_SMC 를 핸들러로 라우팅 (SMC 전용; HVC 는 커널 EL2/pKVM 에 맡김).

anchor 가 다른 QEMU 버전이면 count!=1 로 fail-loud (다른 버전은 anchor 재확인)."""
import sys, os
Q = os.environ.get("QEMU_SRC", os.path.expanduser("~/qemu-build/qemu-10.2.2"))
CPUH, OPH, HLP = Q+"/target/arm/cpu.h", Q+"/target/arm/tcg/op_helper.c", Q+"/target/arm/helper.c"

def patch(path, old, new, marker, tag):
    s = open(path).read()
    if marker in s: print("  [skip]", tag); return
    if s.count(old) != 1:
        print("  [FAIL] %s: anchor count=%d (expected 1) -- ABORT" % (tag, s.count(old))); sys.exit(1)
    open(path, "w").write(s.replace(old, new, 1)); print("  [ok]  ", tag)

patch(CPUH,
    "    uint32_t psci_conduit;\n",
    "    uint32_t psci_conduit;\n\n    /* Board SMC interception (faithful EL3 firmware shim). */\n"
    "    void (*interrupt_handler)(CPUState *cs);\n",
    "interrupt_handler", "cpu.h: ARMCPU.interrupt_handler")

patch(OPH,
    "    if (!arm_feature(env, ARM_FEATURE_EL3) &&\n"
    "        !(arm_hcr_el2_eff(env) & HCR_NV) &&\n"
    "        cpu->psci_conduit != QEMU_PSCI_CONDUIT_SMC) {",
    "    if (!cpu->interrupt_handler &&\n"
    "        !arm_feature(env, ARM_FEATURE_EL3) &&\n"
    "        !(arm_hcr_el2_eff(env) & HCR_NV) &&\n"
    "        cpu->psci_conduit != QEMU_PSCI_CONDUIT_SMC) {",
    "if (!cpu->interrupt_handler &&\n        !arm_feature(env, ARM_FEATURE_EL3) &&\n        !(arm_hcr_el2_eff",
    "pre_smc: skip 1st UDEF")

patch(OPH,
    "    if (!arm_is_psci_call(cpu, EXCP_SMC) &&\n"
    "        (smd || !arm_feature(env, ARM_FEATURE_EL3))) {",
    "    if (!cpu->interrupt_handler &&\n"
    "        !arm_is_psci_call(cpu, EXCP_SMC) &&\n"
    "        (smd || !arm_feature(env, ARM_FEATURE_EL3))) {",
    "if (!cpu->interrupt_handler &&\n        !arm_is_psci_call(cpu, EXCP_SMC) &&",
    "pre_smc: skip 2nd UDEF")

patch(HLP,
    "    if (tcg_enabled() && arm_is_psci_call(cpu, cs->exception_index)) {\n"
    "        arm_handle_psci_call(cpu);",
    "    if (cpu->interrupt_handler &&\n        cs->exception_index == EXCP_SMC) {\n"
    "        cpu->interrupt_handler(cs);\n        return;\n    }\n\n"
    "    if (tcg_enabled() && arm_is_psci_call(cpu, cs->exception_index)) {\n"
    "        arm_handle_psci_call(cpu);",
    "cpu->interrupt_handler &&\n        cs->exception_index == EXCP_SMC) {",
    "helper.c: route EXCP_SMC (SMC-only)")

print("QEMU 10.2.2 core: faithful SMC interception in place (idempotent).")
