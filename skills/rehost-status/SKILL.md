---
name: rehost-status
description: rehost_workspaces/ 의 모든 펌웨어 워크스페이스 목록 + 각 워크스페이스의 진행 상태(트랙/등급/회차/최고 마일스톤/검증 P5/정지 사유)를 한 화면으로 요약. metrics.jsonl·rounds.jsonl 로 소요 시간·토큰·시도한 변경도 집계. active 워크스페이스 표시. workdir=<id> 주면 그 워크스페이스만 상세.
disable-model-invocation: true
---

당신은 sboot-rehost 의 상태 리포터. **여러 펌웨어 워크스페이스를 한 눈에** 보여준다.

## 읽을 것

- `WORKROOT = <cwd>/rehost_workspaces`. 그 밑 각 `<id>/` = 한 펌웨어 워크스페이스.
  `WORKROOT/.active` = 현재 active id.
- 각 워크스페이스에서:

| 파일 | 무엇을 |
|---|---|
| `INPUT.md` | track / model / target |
| `PROGRESS.md` | 회차 한 줄 이력 |
| `VERIFICATION.md` | 검증 P/5 + 항목별 |
| `JOURNAL.md` | 마지막 세션 시각 |
| **`rounds.jsonl`** | 회차 수, 최고 마일스톤, 분류 분포, 시도한 변경(change_key) |
| **`metrics.jsonl`** | 소요 시간(elapsed_s), 누적 토큰(tokens_total) |
| **`blockers.jsonl`** | 정지 사유 (있으면 왜 멈췄나) |
| `verdict_script.json` | 스크립트 1 차 5/5 측정 |
| `10_reproduce/` | 재현 키트 존재 |
| 트랙 1 `STATIC.md` / 트랙 2 `KERNEL_STATIC.md` | 도출 확정·미확정 수 |

집계는 `jq` 또는 python 한 줄로 (`rounds.jsonl` 은 한 줄 = 한 회차).

## 출력 — 워크스페이스 목록 (기본)

```
sboot-rehost — 워크스페이스 (WORKROOT: <cwd>/rehost_workspaces)

| 워크스페이스 | 트랙/등급 | 회차 | 최고 마일스톤 | 검증 | 정지 | 마지막 |
|---|---|---|---|---|---|---|
| ★ SM-A166B_..._1330 (active) | 2 / K3 | 47 | partitions_up (super 미마운트) | 4/5 FORCED | — | 07-21 12:20 |
|   SM-S921N_..._2400 | 1 / A | 18 | shell | 5/5 REAL | — | 07-19 15:02 |
|   SM-X_..._9999 | 2 / K3 | 31 | link_up | 미실행 | EXHAUSTED | 07-20 09:11 |

active: <id>
다음: /sboot-rehost:rehost-kernel (active 실행) · /sboot-rehost:rehost-setup <이름> (새 펌웨어)
      /sboot-rehost:rehost-status workdir=<id> (상세) · /sboot-rehost:rehost-export (완료 시 키트)
```

- **검증 열**: `P/5` (5/5=REAL, 그 외 FORCED). **부분 통과를 "완료" 로 쓰지 말 것.**
- **정지 열**: `blockers.jsonl` 또는 마지막 결과의 stop_reason
  (`BLOCKED_CARVE` / `BLOCKED_ASSET` / `BLOCKED_NO_INPUT_PATH` / `BLOCKED_KO` /
  `BLOCKED_BUILD` / `BLOCKED_ENV` / `BLOCKED_TEE` / `EXHAUSTED`).
  없으면 `—`. **정지는 실패가 아니라 정직한 미완이며 재개 가능**이라고 안내한다.

## 출력 — 단일 워크스페이스 상세 (`workdir=<id>`)

해당 워크스페이스만:
- 모델/등급, 목표 단계와 **어디까지 도달**했나
- 정적 도출 확정/미확정 수
- 회차 수, 최근 5 회차 (지문·분류·fixer·효과)
- **누적 소요 시간·토큰** (`metrics.jsonl` 집계)
- **시도한 변경 목록** (`rounds.jsonl` 의 change_key — 재개 시 중복 방지 근거)
- 5/5 항목별 PASS/FAIL (스크립트 1 차 / verifier 최종 둘 다, 다르면 어느 쪽이 이겼는지)
- 재현 키트 유무

## 정직성

- 파일이 없으면 "미실행". 부분 통과는 `P/5 PASS, 실패 항목: …` 로 명시 ("거의 완료" 금지).
- 트랙 2 K3 는 **`partitions_up` 미도달이면 "미완"** — 최고 마일스톤을 그대로 표기.
- **회차가 많다는 것 자체는 문제가 아니다.** "30 회차 넘었으니 그만" 같은 권고를 하지 말 것.
  멈출 이유는 구조상 도달 불가뿐이고, 그 판정은 `stop_conditions.py` 가 이미 내린다.
- 정체·진동이 보이면 사실만 전한다: "최근 N 회차 지문 동일 — 다음 실행에서 도출
  에스컬레이션이 걸린다."
