---
name: rehost-export
description: 완성된 리호스팅을 "빌드 없이 바로 실행" 가능한 공유 키트로 내보낸다. active(또는 workdir=<id>) 워크스페이스의 목표 등급 완료를 확인한 뒤, examples/ 구조처럼 프리빌트 QEMU + 펌웨어/디스크 이미지 + machine 소스 + 스크립트 + docs + evidence 를 rehost_exports/<model>_<build>/<target>/ 에 조립. 이 폴더는 항상 gitignore. 생성 위치를 사용자에게 안내.
disable-model-invocation: true
---

당신은 **결과물 내보내기(export)** 오케스트레이터. 사용자가 sboot/kernel 목표까지 도달한 뒤
`/sboot-rehost:rehost-export` 를 부르면, **다른 사람이 빌드 없이 바로 실행**할 수 있는 키트를 만든다.

- 대상: active(또는 `workdir=<id>`) 워크스페이스.
- 산출: `<cwd>/rehost_exports/<model>_<build>/<target>/` (등급별로 폴더가 하나씩).
- **이 폴더들은 항상 gitignore** (프리빌트 QEMU·펌웨어 대용량/저작권).

---

## Step 0 — 완료 확인 (★ 미완이면 export 금지)

INPUT.md 의 `target` 확인 후 그 등급의 **목표 도달**을 검증:
- `VERIFICATION.md` 가 **6/6 REAL** 이어야 한다. 5/6 이하면 "아직 FORCED — export 불가" 안내 후 종료.
- 등급별 최종 칸: **F1**=부트로더 표면, **F2**=`kernel_entry`, **F3**=`rootfs` 마운트.
  콘솔/VERIFICATION 로 확인. 미도달이면 "미완 — export 불가" 안내 후 종료.

완료면: `bash <PLUGIN>/scripts/journal.sh <WS> session-start "/sboot-rehost:rehost-export" "키트 생성 <target>"`.

## Step 1 — 대상 경로 결정

- `model`/`build` = INPUT.md 슬롯. firmware key = `<model>_<build>` (build 미상이면 `<model>_<id>`).
- `DEST = <cwd>/rehost_exports/<firmware>/<target>/`. 이미 있으면 갱신 전 확인(덮어쓰기 경고).

## Step 2 — 키트 조립 (기계적)

프리빌트 QEMU 경로 확인: `~/qemu-build/qemu-10.2.2/build/qemu-system-aarch64`.
`scripts/make_export.sh` 호출 (env 로 파라미터):

```
WS=<workspace> DEST=<dest> \
QEMU=~/qemu-build/qemu-10.2.2/build/qemu-system-aarch64 \
MACHINE=<INPUT machine name> CPU=<cpu> \
[INPUT_CMD=help] \
[EUFS_LU_IMAGE=<합성 매체 lu0.img> EUFS_LBS=4096] \
bash <PLUGIN>/scripts/make_export.sh
```

이게: `bin/`(프리빌트 QEMU) + `firmware/`(sboot.bin 또는 Image/dtb/initrd) + `machine/`(machine.c
또는 machine_kernel.c + `<hci>.c/.h` + `bypasses.md`) + `scripts/`(patch·build) +
`evidence/` + turnkey `run.sh`·`setup.sh`·`.gitignore` 생성.

`evidence/` 에는 **사람이 읽는 기록과 기계가 읽는 측정치가 둘 다** 들어간다:
`VERIFICATION.md` `ANALYSIS.md` `PROGRESS.md` `JOURNAL.md` `STATIC.md` `stage_map.json` `RESUME.md`
`INPUT.md` 콘솔·요약 로그 + 하니스 입력 기록(`input_*.txt`, `input_summary.json`) +
**`metrics.jsonl`**(시간·토큰) **`rounds.jsonl`**(회차별 지문/분류/fixer/효과)
`blockers.jsonl` `verdict_script.json`(스크립트 1 차 6/6 측정) `analysis.json`.

**`ANALYSIS.md` 는 `make_export.sh` 가 `analyze_run.py` 를 돌려 만든다.** 시간·토큰 총량만
넘기면 받는 사람이 jsonl 을 직접 읽어야 하므로, 기록에서 계산되는 것은 계산해서 넣는다:

| 절 | 답하는 질문 |
|---|---|
| 2 | 단계별로 시간과 토큰이 얼마나 들었나 |
| 3 | 어느 회차가 오래 걸렸나 (재분석·재생성 시간은 분리) |
| 4 | 어느 정지점에 회차를 가장 많이 썼나 |
| 5 | 관측이 안 바뀐 정체 구간은 어디였고 무엇이 그것을 끝냈나 |
| 6 | 분류·담당별 분포와 관측을 바꾼 비율 |
| 7 | 실제로 부팅을 전진시킨 변경은 무엇이었나 |
| 10 | 왜 오래 걸렸나 — 관측·비용·근거 3 항으로 |
| 11 | 기록 자체의 한계 (번호 중복, 누락된 측정) |

**대용량 이미지(super/disk)**: make_export 가 자동으로 못 넣은 것은 직접 `firmware/` 로
복사 (또는 너무 크면 `firmware/README.txt` 에 "본인 disk.img 를 여기 두세요" 안내 + run.sh 가 `EUFS_LU_IMAGE` 참조).

## Step 3 — 문서 생성 (docs/ + README + HOW-TO-RUN)

워크스페이스의 JOURNAL/PROGRESS/bypasses/VERIFICATION + `rounds.jsonl`/`metrics.jsonl` 을
근거로 `DEST/docs/` 에 서술:
- `01_what-was-built.md` — 무엇을 리호스트했나 (등급·도달 지점).
- `02_boot-chain.md` — 부팅 체인에서 어느 스테이지를 실행했고 어디를 건너뛰었나.
- `03_trial-and-error.md` — JOURNAL 의 시행착오(원인/분석/해결) + `rounds.jsonl` 의
  분류 분포·시도한 변경 목록 요약.
- `04_timeline.md` — JOURNAL 세션 시각 + **`ANALYSIS.md` 2·3 절**(단계별 소요·비용,
  소요가 길었던 회차). 수치를 다시 추정하지 말고 `ANALYSIS.md` 의 값을 인용한다.
- `07_cost-analysis.md` — **`ANALYSIS.md` 4·5·7·10 절**을 근거로: 어느 정지점이 회차를
  가장 많이 먹었는지, 정체 구간이 무엇으로 끝났는지, 어느 변경이 실제로 부팅을
  전진시켰는지, 왜 오래 걸렸는지. 논문·보고서에 그대로 옮길 수 있는 수준으로 쓴다.
- `05_bypasses.md` — `06_machine/bypasses.md` (`[대상/이유/방법/부작용]`).
- `06_verification.md` — 6/6 **2 단 검증** 결과: 스크립트 1 차(`verdict_script.json`) 와
  verifier 2 차(`VERIFICATION.md`) 를 **둘 다** 싣고, 판정이 달랐다면 어느 쪽이 이겼고
  근거가 무엇인지 명시 (올리는 방향 override 는 byte 증거가 있어야 유효).

`DEST/README.md`(개요 + 한 줄 실행 + **실행 비용과 소요** 요약) + `DEST/HOW-TO-RUN.md`
(전제·실행·재빌드). 모든 서술은 실제 기록 근거로만 (지어내기 금지, 정직성).

### 문서 서술 규칙 (docs/ · README · HOW-TO-RUN 전부)

- 자연스럽고 공식적인 한국어로 쓴다. 구어체·감탄·과장은 쓰지 않는다.
- **용어를 새로 만들지 않는다.** 현업 통용 용어이거나 이 저장소가 이미 쓰는 용어
  (정지점 · 회차 · 우회 · 마일스톤 · 부팅 깊이 · 도출)만 쓴다. `fastboot` · `UART` ·
  `MemoryRegion` 처럼 그대로 쓰는 것이 표준인 말은 억지로 옮기지 않는다.
- **항목화한다.** 줄글 문단을 늘어놓지 않는다. 비교할 값이 둘 이상이면 표, 순서가 있으면
  번호 목록, 그 밖에는 굵은 표제어를 단 글머리표를 쓴다.
- 수치에는 근거 파일을 붙인다 — "오래 걸렸다" 가 아니라 "1 시간 40 분 (`ANALYSIS.md` 5 절)".
- 확인하지 못한 것은 확인하지 못했다고 적는다. 빈칸을 추측으로 채우지 않는다.

## Step 4 — gitignore 보장 (★ 항상)

`<cwd>/rehost_exports/.gitignore` 에 `*` 를 써서 **exports 전체를 git 미추적**으로:
```
bash -c 'mkdir -p "<cwd>/rehost_exports"; printf "*\n" > "<cwd>/rehost_exports/.gitignore"'
```
(키트 내부에도 make_export 가 `.gitignore`(bin/ firmware/ *.img) 를 둠.)

## Step 5 — 통지 (★ 생성 위치 안내)

```
== export 완료 ==
생성 위치:  <cwd>/rehost_exports/<firmware>/<target>/     (git 미추적)
포함:  bin/qemu-system-aarch64 (프리빌트) · firmware/ · machine/ · scripts/ · docs/ · evidence/ · run.sh
바로 실행(받는 사람):  cd <경로> && bash run.sh     (오류 시 bash setup.sh 먼저)
공유:  이 폴더를 zip/복사로 전달 (git 에는 안 올라감).
같은 펌웨어를 다른 등급으로:  그 워크스페이스를 active 로 두고 /sboot-rehost:rehost-export.
```

`journal.sh <WS> session-end "/sboot-rehost:rehost-export" "키트 -> rehost_exports/<firmware>/<target>"`.

---

## 정직성

- **미완이면 export 금지** (6/6 미만이거나 목표 단계 미도달). 완료로 위장 금지.
- docs/evidence 는 실제 JOURNAL/VERIFICATION/콘솔 근거로만. 없는 결과 지어내지 말 것.
- export 폴더는 항상 gitignore (펌웨어 저작권·대용량). 생성 위치를 반드시 사용자에게 안내.
