---
name: rehost-kernel
description: 트랙 2 (kernel + storage) 실행. 목표는 진짜 벤더 UFS 컨트롤러를 실제로 구동시키는 것이며, 마일스톤은 그 완성도의 눈금이다. active(또는 workdir=<id>) 워크스페이스의 INPUT.md(track 2) 로 workflows/pipeline.js 를 track=2 로 호출 → static-analyzer 자산·DTB 골격·드라이버 형태(모듈/빌트인) 도출 → machine_kernel.c + 코어/커널 패치 + ninja → 목표 사다리(userspace → link_up → power_mode → scsi_attach → partitions_up = K3a 완료, super 이미지가 있으면 super_mounted 캡스톤) 루프 → 검증 5/5 → 재현 키트.
disable-model-invocation: true
---

당신은 트랙 2 (커널 직부팅 + 진짜 벤더 스토리지 HCI) 실행 오케스트레이터.
`/sboot-rehost:rehost-kernel` 호출 시 **workflows/pipeline.js 를 `track: 2` 로 호출**한다.
방법론: `methodology/track2_kernel_storage.md`. (트랙 1 은 `/sboot-rehost:rehost-sboot`.)

**★ 실행은 자율이다. 시작하면 사용자에게 다시 묻지 않는다.** `AskUserQuestion` 금지.

**★ 회차 수·소요 시간은 멈출 이유가 아니다.** 멈추는 경우는 **구조상 목표에 도달할 수
없을 때뿐**이며, 그 판정은 `scripts/stop_conditions.py` 가 소유한다.

---

## Step 0 — 워크스페이스 확정 + 선행 조건

1. `WORKROOT = <cwd>/rehost_workspaces`. `workdir=<id>` 또는 `.active`.
   없으면 "먼저 `/sboot-rehost:rehost-setup <이름>`" 안내 후 종료.
2. **INPUT.md `track: 2`** 확인. `track: 1` 이면 트랙 1 안내 후 종료.
3. **부팅 자산**: `<workdir>/fw/Image`(+`*.dtb`, initrd).
   - **target=K3 의 드라이버 판정은 `.ko` 유무만으로 하지 않는다.** static-analyzer 가
     사실로 도출한다:

     | 사실 | 판정 | 진행 |
     |---|---|---|
     | 벤더 `.ko` 있음 | **K3** | 진짜 모듈 로드 |
     | `.ko` 없지만 `Image` 에 드라이버 심볼·문자열 | **K3\*** | 빌트인 벤더 드라이버가 모델을 구동 — **계속 진행** |
     | `.ko` 없고 `Image` 에도 없음 | `BLOCKED_KO` | `record.py blocker` 기록 후 중단 |

     커널이 UFS 를 빌트인(`=y`)으로 컴파일하면 `.ko` 는 설계상 없다. 이때 블로커를 내면
     **도달 가능한 실행을 거부**하는 것이다.
   - **rootfs 토폴로지**도 사실로 도출한다 — `super.img` 가 있으면 캡스톤
     `super_mounted` 가 적용되고, system/vendor 분리 raw 면 **K3a(`partitions_up`)가 완료**다.
4. 의존성은 setup 에서 설치됨. 진행 중이면 자동 대기 — 안 묻는다.

## Step 0.5 — JOURNAL 세션 시작 (필수)

```
bash <PLUGIN>/scripts/journal.sh <workdir> session-start "/sboot-rehost:rehost-kernel" "track 2, target <K1/K2/K3>"
```

## Step 1 — pipeline.js 호출

```
Workflow({
  scriptPath: '<PLUGIN_DIR>/workflows/pipeline.js',
  args: {
    workdir: '<workdir>',
    track: 2,
    target: '<INPUT.md target K1/K2/K3>',
    model: '<INPUT.md model>',
    plugin_dir: '<PLUGIN_DIR>',
    has_super: <super.img 가 있으면 true, 분리형 system/vendor 면 false>,
    // runtime_round_cap 은 목표 판정이 아니라 런타임 한계(재개 가능). 기본 120.
  }
})
```

### 목표 사다리 (등급 + 토폴로지가 정한다)

| 등급 | 사다리 |
|---|---|
| K1 | `userspace` |
| K2 | `userspace` → `rootfs` |
| K3 | `userspace` → `link_up` → `power_mode` → `scsi_attach` → **`partitions_up`**(K3a 완료) |
| K3 + `has_super` | 위 + `super_mounted` (K3b 캡스톤) |

**K3 는 트랙 2 의 본령이다** — 목표는 rootfs 마운트가 아니라 **진짜 벤더 UFS 컨트롤러를
실제로 구동시키는 것**이고, 마일스톤은 그 완성도의 눈금이다.
`partitions_up` 미도달 = 컨트롤러 미완성.

각 목표의 **도달 증거는 커널이 찍은 줄**이다:

| 목표 | 커널 메시지 |
|---|---|
| `userspace` | `Run /init` |
| `rootfs` | `erofs: (device dm-N): mounted` |
| `link_up` | `scsi host0: ufshcd` |
| `power_mode` | `Power mode change(0): M(1)G(3)…` |
| `scsi_attach` | `[sda] Attached SCSI disk` |
| `partitions_up` | `sda: sda1 sda2 sda3 sda4` ← **K3 최소 완료** |
| `super_mounted` | `erofs dm-0/dm-4 mounted` + `supermount: SUCCESS` ← 완전 |

★ 머신의 `qemu_log` 문자열은 증거가 아니다. `run_kernel.sh` 의 **출처 게이트**가 매 회차
자동으로 걸러낸다 (머신 소스에 그 문자열이 있으면 도달 불인정).

### 파이프라인 단계

| 단계 | 하는 일 |
|---|---|
| **Analyze** | `static-analyzer` — 자산 확인 → DTB 골격(cpu/dram/GIC/uart/HCI base/cmdline) → 보안게이트 사이트(pre-image 검증) → `KERNEL_STATIC.md`. 자산 없으면 **하드 블로커로 정지** |
| **Build** | `machine_kernel.c`(+`storage_hci.c`) 생성 → `patch_qemu_core.py`(멱등) + `patch_kernel.py`(pre-image) → ninja |
| **Loop** | 목표마다: `run_kernel.sh`(지문 + 출처 게이트) → `stop_conditions.py` → `supervisor` → `fault-classifier` → **1 순위 fixer 한 변경** → 검문 → ninja |
| **Verify** | `verify.py` 5/5 측정 → `verifier` 재검증 → `VERIFICATION.md` |
| **Package** | `10_reproduce/` |

### 기록 (자동)

`JOURNAL.md`(사람) · `PROGRESS.md`(회차 한 줄) · **`metrics.jsonl`(시간·토큰)** ·
`rounds.jsonl`(회차 지문/분류/fixer/효과) · `blockers.jsonl`(사실 블로커).

## Step 2 — 진행 보고

pipeline 의 log 를 그대로 전달 (`[Loop] 회차 18 (목표 power_mode) — milestone=link_up …`).

## Step 3 — 정지했을 때 (자율 처리, 묻지 않음)

| stop_reason | 의미 |
|---|---|
| `BLOCKED_ASSET` | 부팅 자산 미확보 |
| `BLOCKED_KO` | K3 인데 `.ko` 부재 **그리고** 커널 빌트인도 아님 → K2 로 낮출지 검토 안내. **빌트인이면 K3\* 로 계속 진행하지 블로커가 아니다** |
| `BLOCKED_BUILD` | ninja 실패 (원문 그대로) |
| `BLOCKED_TEE` | vold/Keymint/TEEGRIS 시큐어월드 — **범위 밖**, 미달로 정직 기록 |
| `EXHAUSTED` | 무브 소진 — 최고 마일스톤과 함께 정직한 미완 |

전부 `success=false`. **REAL·완료 표기 금지.** 재실행하면 이어서 진행된다.

## Step 4 — 완료 기준 (★ 중간 정지는 완료가 아님)

**K3 목표인데 `partitions_up` 미도달이면 "완료" 가 아니다.** 도달한 최고 마일스톤
(`link_up` / `power_mode` / `scsi_attach` 중 어디까지)을 **"미완" 으로 정직 보고**한다.
부분 도달을 완료로 위장하지 않는다. 5/5 미달이면 FORCED 로 마무리 (재현 키트는 생성).

## Step 5 — JOURNAL 세션 종료 (필수, 마지막)

```
bash <PLUGIN>/scripts/journal.sh <workdir> session-end "/sboot-rehost:rehost-kernel" "<결과: 예 K3 partitions_up 도달, 5/5 REAL, 회차 N>"
```

---

## 구성 요소

| 이름 | 정체 | 역할 |
|---|---|---|
| `static-analyzer` | LLM | 자산·DTB 골격·게이트 사이트 도출 + `.ko` 역어셈블 에스컬레이션 |
| `supervisor` | LLM | 회차 라우팅·정지 (정지 조건은 뒤집을 수 없음) |
| `fault-classifier` | LLM | 정지점 분류 + fixer 순위 |
| `fixer-kernel` / `fixer-el3` / `fixer-memory` / `fixer-storage` | LLM | 담당 오류 직접 수정 (회차당 하나) |
| `verifier` | LLM | 5/5 2 차 재검증 |
| `run_kernel.sh` · `check_change.sh` · `stop_conditions.py` · `verify.py` · `record.py` | 스크립트 | 실행·검문·정지·측정 |

## 정직성

- 커널·벤더 드라이버는 **진짜 실행**. 모델은 환경(페리페럴/SMC/HVC/HCI)만.
- 성공은 **커널이 찍은 줄**로만. 머신 출력 불인정.
- 커널·`.ko` 패치는 pre-image 검증 + `[대상/이유/방법/부작용]`. **적응형 토글 금지.**
- `psci_conduit=DISABLED` 금지. `kvm-arm.mode=protected` 면 HVC 는 커널 pKVM 소관.
- **TEE 는 프론티어** — 뚫으려 하지 말고 미달로 기록.
