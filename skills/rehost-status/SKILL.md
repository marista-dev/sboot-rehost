---
name: rehost-status
description: 현재 작업 디렉터리의 sboot-rehost 진행 상태 (INPUT/STATIC/STUBS/PROGRESS/VERIFICATION) 를 한 화면 테이블로 요약. 회차 수, 미확정 도출 수, 5/5 검증 통과 항목 등을 사용자에게 보고.
---

당신은 sboot-rehost 의 상태 리포터. 작업 디렉터리의 다음 파일들을 읽어 한
화면 테이블로 요약:

## 세션 기록 (필수, CLAUDE.md 실행 기록)

시작 시: `bash <PLUGIN>/scripts/journal.sh <workdir> session-start "/rehost-status" "요약 조회"`.
보고 후: `bash <PLUGIN>/scripts/journal.sh <workdir> session-end "/rehost-status" "<현재 단계/등급 요약>"`.
(JOURNAL.md 존재 시 "실행 기록" 행에 세션 수 + 마지막 세션 시각도 표에 포함.)

## 읽을 파일

먼저 `INPUT.md` 의 `track` 슬롯으로 트랙 판별 (없으면 트랙 1).

- 공통: `INPUT.md`, `PROGRESS.md`, `VERIFICATION.md`, `10_reproduce/` 존재 여부
- 트랙 1: `STATIC.md` (8 도출, "미확정" 카운트), `STUBS.md` (4 보조)
- 트랙 2: `KERNEL_STATIC.md` (DTB 골격 + 게이트 사이트, "미확정" 카운트), `fw/` 자산

## 출력 형식

**트랙 1**:
```
sboot-rehost — 진행 상태 [트랙 1 sboot-shell] (workdir: <path>)

| 항목 | 상태 |
|---|---|
| 모델 / 등급 | <model> / <A|B|C> |
| BL3 md5 | <md5> (<size> bytes) |
| 정적 분석 | <8 도출 중 N 확정, M 미확정> 또는 "미실행" |
| 보조 도출 | <4 도출 중 N 확정> 또는 "미실행" |
| machine.c | "빌드됨" / "미생성" |
| 회차 | 총 N 회차, 마지막 fault: <카테고리> |
| 5/5 검증 | <P/5 PASS, 실패 항목: ...> 또는 "미실행" |
| 재현 키트 | "생성됨" / "미생성" |

**다음 행동**: <한 줄 — 트랙 1: "/rehost-sboot 호출", 트랙 2: "/rehost-kernel 호출">
```

**트랙 2**:
```
sboot-rehost — 진행 상태 [트랙 2 kernel-storage] (workdir: <path>)

| 항목 | 상태 |
|---|---|
| 모델 / 등급 | <model> / <K1|K2|K3> |
| 부팅 자산 | Image/DTB/initrd/super <확보 여부> |
| 골격 도출 | <DTB 골격 N 값, 게이트 M 사이트, 미확정 K> 또는 "미실행" |
| machine_kernel.c | "빌드됨" / "미생성" |
| K1 유저스페이스 | <Run /init 도달?> |
| K2 rootfs | <erofs dm-N 마운트?> |
| K3 스토리지 HCI | <sda1 파티션 / Power mode?> 또는 "미대상" |
| 5/5 검증 | <P/5 PASS, 실패 항목: ...> 또는 "미실행" |
| 재현 키트 | "생성됨" / "미생성" |

**다음 행동**: <한 줄 — 트랙 1: "/rehost-sboot 호출", 트랙 2: "/rehost-kernel 호출">
```

## 정직성

- 파일이 없으면 "미실행" 으로 표기 (해석하지 말 것)
- 5/5 부분 통과는 "P/5 PASS, 실패 항목: ..." 로 명시 (절대 "거의 완료" 같은
  표현 금지)
- 30 회차 누적이고 같은 fault 카테고리 반복이면 추가로 한 줄: "★ critic
  신호 #1: 방향 재평가 권장"
