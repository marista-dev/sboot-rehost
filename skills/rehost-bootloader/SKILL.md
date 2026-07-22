---
name: rehost-bootloader
description: 트랙 1 (부트로더 단계) 실행. 부팅 체인에서 커널 직전의 부트로더를 QEMU 위에서 진짜로 실행해 그 부트로더의 인터랙티브 표면(UART 셸 또는 fastboot/USB)에 도달한다. Samsung S-Boot(AArch64) · MediaTek LK(AArch32) · Qualcomm aboot 등 벤더 구현체가 달라도 같은 단계이므로 같은 명령이다. INPUT.md(track 1)로 workflows/pipeline.js 를 track=1 로 호출.
disable-model-invocation: true
---

당신은 **트랙 1 (부트로더 단계)** 실행 오케스트레이터.
`/sboot-rehost:rehost-bootloader` 호출 시 **`workflows/pipeline.js` 를 `track: 1` 로 호출**한다.
(커널 단계는 `/sboot-rehost:rehost-kernel`.)

## 이 명령이 다루는 자리

```
BROM → Preloader / BL1·BL2 → ★ 부트로더 ★ → 커널
                              │
        Samsung Exynos ───────┤ S-Boot   (AArch64)
        MediaTek       ───────┤ LK       (AArch32 Thumb)
        Qualcomm       ───────┤ aboot
        일반 임베디드     ───────┘ U-Boot
```

ARM TF-A 용어의 **BL33(non-secure world bootloader)** 자리다. **벤더 구현체가 달라도 같은
단계이므로 같은 명령**이며, 구현체 차이는 `profiles/` 와 목표 표면이 흡수한다.

**★ 실행은 자율이다.** `AskUserQuestion` 호출 금지.
**★ 회차 수·소요 시간은 멈출 이유가 아니다.** 멈추는 경우는 구조상 도달 불가일 때뿐이며,
그 판정은 `scripts/stop_conditions.py` 가 소유한다.

---

## ★ 목표는 "인터랙티브 표면" 이다 — 셸이 전부가 아니다

부트로더마다 **사용자 명령을 받는 경로가 다르다.** 목표는 "셸" 이 아니라
**그 부트로더에서 실제로 도달 가능한 인터랙티브 표면**이다.

| 표면 | 무엇 | 도달 증거 | 대표 |
|---|---|---|---|
| `shell` | UART 콘솔 명령 루프 | 프롬프트 + `help` 출력 | Samsung S-Boot |
| `fastboot` | USB 명령 dispatch | `getvar:` 수신·에코·dispatch | MediaTek LK |

`INPUT.md` 의 `bl_surface` 슬롯이 결정하며, **static-analyzer 가 사실로 확정**한다.

### 표면을 잘못 잡으면 도달 불가를 도달로 착각한다

실제 사례(MediaTek LK): 12명령 콘솔이 바이너리에 **실재하지만** UART 드라이버에 수신
경로가 없고(출력 전용), 어떤 USB 리더도 그 명령 테이블을 참조하지 않아 **인터랙티브
도달이 구조적으로 불가능**했다. 트램폴린으로 `help` 를 강제 호출해 출력시키는 건
**FORCED**(등급 A 아님)이고, 진짜 도달 가능한 표면은 **fastboot** 였다.

static-analyzer 가 이걸 도출하면:
- 표면을 `fastboot` 로 확정하고 계속 진행하거나,
- 어느 표면에도 입력 경로가 없으면 **`BLOCKED_NO_INPUT_PATH`** 로 정직하게 정지한다.

---

## Step 0 — 워크스페이스 확정 + 선행 조건

1. `WORKROOT = <cwd>/rehost_workspaces`. `workdir=<id>` 또는 `.active`.
   없으면 "먼저 `/sboot-rehost:rehost-setup <이름>`" 안내 후 종료.
2. **`INPUT.md` `track: 1`** 확인. `track: 2` 면 `/sboot-rehost:rehost-kernel` 안내 후 종료.
3. **부트로더 이미지**: `bootloader_path` (구 워크스페이스의 `bl3_path` 도 인식).
4. **SoC 계열·표면**: `soc_family`(exynos | mediatek | generic)와 `bl_surface`.
   미확정이면 그대로 두고 넘긴다 — static-analyzer 가 확정한다.

## Step 0.5 — JOURNAL 세션 시작 (필수)

```
bash <PLUGIN>/scripts/journal.sh <workdir> session-start "/sboot-rehost:rehost-bootloader" "track 1, <soc_family>, surface <bl_surface>, target <A/B/C>"
```

## Step 1 — pipeline.js 호출

```
Workflow({
  scriptPath: '<PLUGIN_DIR>/workflows/pipeline.js',
  args: {
    workdir: '<workdir>',
    track: 1,
    target: '<INPUT.md target A/B/C>',
    model: '<INPUT.md model>',
    bootloader_path: '<INPUT.md bootloader_path 또는 bl3_path>',
    soc_family: '<exynos | mediatek | generic>',
    bl_surface: '<shell | fastboot | 미확정이면 생략>',
    arch: '<arm64 | arm32>',
    plugin_dir: '<PLUGIN_DIR>',
  }
})
```

### 파이프라인 단계

| 단계 | 하는 일 |
|---|---|
| **Analyze** | `static-analyzer` — **표면 판정 먼저**, 그다음 carve/entry/linker/load/Δ/cmd 테이블/핸들러. `profiles/<soc_family>.yaml` 의 힌트 사용. AArch32 대상은 `carve_disasm.py --arch arm32` |
| **Build** | 표면·아키텍처에 맞는 템플릿으로 머신 소스 생성 → QEMU 통합 + ninja |
| **Loop** | `run_round.sh` → 지문 + **출처 게이트** → `supervisor` → `fault-classifier` → **1 순위 fixer 한 변경** → 검문 → ninja |
| **Verify** | `verify.py --track 1 --surface <표면>` 5/5 측정 → `verifier` 재검증 |
| **Package** | `10_reproduce/` |

## Step 2~5 — 보고 · 정지 · 검증 · 세션 종료

정지 사유별 보고:

| stop_reason | 의미 |
|---|---|
| `BLOCKED_CARVE` | 부트로더 이미지가 carve (부분 추출) |
| **`BLOCKED_NO_INPUT_PATH`** | **어느 표면에도 인터랙티브 입력 경로가 없음** — 구조적 불가 |
| `BLOCKED_BUILD` | ninja 실패 (원문 그대로) |
| `EXHAUSTED` | 무브 소진 |

전부 `success=false`, **REAL 표기 금지**, 재실행하면 이어서 진행.

검증은 **5/5 = REAL, 4/5 이하 = FORCED**. 표면별로 항목 4 가 다르다
(`shell` = UART 단일 경로 / `fastboot` = 입력이 외부에서 옴).

마지막에 반드시:
```
bash <PLUGIN>/scripts/journal.sh <workdir> session-end "/sboot-rehost:rehost-bootloader" "<결과>"
```

---

## 구성 요소

| 이름 | 역할 |
|---|---|
| `static-analyzer` | **표면 판정** + 도출 + 미지 정지점 에스컬레이션 |
| `supervisor` | 라우팅·정지 (정지 조건은 뒤집을 수 없음) |
| `fault-classifier` | 정지점 분류 + fixer 순위 |
| `fixer-memory` / `fixer-el3` / `fixer-bootflow` | 담당 오류 직접 수정 (회차당 하나) |
| `verifier` | 5/5 2 차 재검증 (비대칭 override) |

## 정직성

- 트램폴린으로 명령 출력을 강제하는 것은 **도달이 아니라 FORCED** 다.
  "사용자 입력 → dispatcher" 가 성립해야 도달이다.
- 입력은 **외부에서** 와야 한다. 머신이 명령을 지어내면 순환검증이다 (정직성 §7).
- 5/5 미달 시 "REAL"·"성공" 금지.
