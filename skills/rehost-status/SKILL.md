---
name: rehost-status
description: rehost_workspaces/ 의 모든 펌웨어 워크스페이스 목록 + 각 워크스페이스의 진행 상태(트랙/등급/회차/5/5/워크스페이스 마일스톤)를 한 화면으로 요약. active 워크스페이스 표시. workdir=<id> 주면 그 워크스페이스만 상세.
---

당신은 sboot-rehost 의 상태 리포터. **여러 펌웨어 워크스페이스를 한 눈에** 보여준다.

## 읽을 것

- `WORKROOT = <cwd>/rehost_workspaces`. 그 밑의 각 `<id>/` = 한 펌웨어 워크스페이스.
- `WORKROOT/.active` = 현재 active id.
- 각 워크스페이스: `INPUT.md`(track/model/target), `PROGRESS.md`(회차 수·마지막 fault),
  `VERIFICATION.md`(P/5), `JOURNAL.md`(마지막 세션 시각), `10_reproduce/` 존재.
  - 트랙 1: `STATIC.md`/`STUBS.md`. 트랙 2: `KERNEL_STATIC.md`, `07_logs` 콘솔에서 K3 마일스톤.

## 출력 — 워크스페이스 목록 (기본)

```
sboot-rehost — 워크스페이스 (WORKROOT: <cwd>/rehost_workspaces)

| 워크스페이스 | 트랙/등급 | 진행 | 검증 | 마지막 |
|---|---|---|---|---|
| ★ SM-A166B_..._1330 (active) | 2 / K3 | K3 partitions_up (super 미마운트) | 3/5 | 07-10 12:20 |
|   SM-S921N_..._2400 | 1 / A | 셸 도달 | 5/5 REAL | 07-09 15:02 |

active: <id>
다음: /rehost-kernel (active 실행) · /rehost-setup fw=<zip> (새 펌웨어) · /rehost-status workdir=<id> (상세)
```

- 진행 열: 트랙 1 = 회차 수/셸 도달, 트랙 2 = 최고 마일스톤 (K1 유저스페이스 / K2 rootfs /
  K3 link_up·power_mode·scsi_attach·partitions_up·super_mounted).
- 검증 열: `P/5` (5/5=REAL, 그 외 FORCED). **부분 통과를 "완료"로 쓰지 말 것.**

## 출력 — 단일 워크스페이스 상세 (`workdir=<id>` 인자 시)

해당 워크스페이스만 트랙별 상세표 (모델/등급, 정적 도출 확정/미확정, machine.c 빌드 여부,
회차·마지막 fault, K1/K2/K3 마일스톤, 5/5 항목별 PASS/FAIL, 재현 키트).

## 정직성

- 파일 없으면 "미실행". 부분 통과는 `P/5 PASS, 실패 항목: …` 로 명시 ("거의 완료" 금지).
- 트랙 2 K3 는 **진짜 파티션(sda1..) 미도달이면 "미완"** 으로 (완료 아님). 최고 마일스톤 표기.
- 30 회차 + 같은 fault 반복이면 "★ critic 신호 #1: 방향 재평가 권장" 한 줄 추가.
