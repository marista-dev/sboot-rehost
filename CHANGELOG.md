# 변경 이력

이 플러그인은 `.claude-plugin/plugin.json` 의 `version` 을 올렸을 때만 사용자에게
업데이트가 전달된다. 각 버전에 무엇이 들어갔는지 여기에 기록한다.

업데이트 방법은 [README 2. 업데이트](README.md#2-업데이트) 참조.

---

## 0.9.1 — 2026-07-21

문서 보강. 기능 변경 없음.

- `docs/components.md` 신설 — 아키텍처의 각 컴포넌트를 실행 순서대로
  (Analysis → Build → Run → Manage → Diagnosis → Fix → Verify → Package) 정리.
  컴포넌트마다 역할 · 정체 · 입력/출력 · 동작 과정 · 규칙을 항목화.
- `README.md` 을 진입점으로 재작성하고 **업데이트 절** 신설 —
  CLI · VS Code 확장 각각의 절차, 자동 업데이트가 서드파티 마켓플레이스에서
  기본 비활성이라는 점, 업데이트가 안 될 때의 조치.

## 0.9.0 — 2026-07-21

**아키텍처 전면 재설계.** 측정은 스크립트, 해석·제어는 LLM, 정지의 입력값은 사실.

### 에이전트 재편 (8 → LLM 5 역할)
- `static-analyzer` — `bl3-analyzer` + `stub-locator` + `kernel-boot-analyzer` +
  `storage-modeler`(`.ko` 역어셈블) 병합. 사전 도출 + 에스컬레이션 2 모드
- `supervisor` 신설 — 회차 라우팅·정지
- `fault-classifier` 신설 — 분류를 수리에서 분리. `unknown` 이 정상 답
- `fixer-memory` / `el3` / `bootflow` / `kernel` / `storage` — 담당 오류 + 도구로 분화.
  LLM 중 유일하게 쓰기 권한
- `verifier` — 검증 5/5 의 2 차 재검증
- `critic` 삭제 — 정지 조건으로 흡수

### 결정론 계층 신설
- `run_round.sh` — 한 회차를 통째로 수행하고 관측 문서 하나(`observation.json`)를 냄
- `check_change.sh` — diff 로 "회차 = 한 변경" 강제, 우회 4항목 검문
- `stop_conditions.py` — 정지 조건 계산 (구조상 도달 불가만)
- `verify.py` — 검증 5/5 측정
- `record.py` — 시간·토큰 등 측정치를 `metrics.jsonl` · `rounds.jsonl` ·
  `blockers.jsonl` 로 실시간 기록
- `run_qemu.sh` / `run_kernel.sh` — 지문 추출 + **출처 게이트를 매 회차 집행**

### 파이프라인 통합
- `pipeline.js` + `pipeline_kernel.js` + `iter-loop.js` → **`pipeline.js` 하나**
  (`track` 인자 + 목표 사다리)
- 목표 전진을 **관측으로만** 판정 (supervisor 의 주장으로는 사다리가 움직이지 않음)

### 정지 정책 변경
- **회차 수·소요 시간은 더 이상 정지 사유가 아니다.** `max_iterations` 상한 제거
- 정지는 구조상 도달 불가만 — `BLOCKED_*` 5종 + `EXHAUSTED`(무브 소진)
- 사실로 측정된 정지를 LLM 이 우회하려 하면 파이프라인이 **강제 정지**

### 검증 2단화
- 스크립트가 5/5 를 측정하고, LLM 이 재검증
- **방향 비대칭** — 낮추기(REAL→FORCED)는 자유, 올리기는 byte-level 증거 필요

### 지식 / 프로세스 분리
- `fixers/registry.yaml` — 오류 이름 → 담당 fixer
- `knowledge/faults_bootloader.md` · `faults_kernel.md` · `faults_storage.md` ·
  `kernel_gates.md` — 정지점 테이블
- `profiles/generic.yaml` · `exynos.yaml` · `mediatek.yaml` — SoC 탐색 힌트(값 아님)
- 새 정지점 = 테이블 한 줄, 새 fixer = 파일 하나 + 등록부 몇 줄

### 수정한 결함 (전부 재현으로 확정)
- `grep -c` 가 0 매치일 때 `fingerprint.json` 이 깨지던 문제
- `verify.py` 항목 1 이 영구 FAIL 이라 REAL 도달이 불가능하던 문제
  (PC 를 `STATIC.md` 에서 자동 도출하도록 수정)
- 목표 초과 도달 시 사다리가 전진하지 않던 문제
- 사다리가 건너뛴 단 때문에 하위 도달이 가려지던 문제
- 에이전트 자유 텍스트를 통한 **쉘 인젝션** (단일따옴표 이스케이프로 차단)
- 에스컬레이션 임계값이 소진 임계값과 같아 도출이 한 번도 불리지 못하던 문제
- 회차 이중 기록으로 정체를 오탐하던 문제
- 콘솔이 오염돼도 다른 토큰으로 도달을 인정하던 출처 게이트 허점
- `record.py` 가 16진 주소를 정수로 바꿔 지문 비교가 깨지던 문제

### 기타
- `tests/smoke.sh` 신설 — 가짜 QEMU 로 결정론 계층을 검증하는 회귀 하니스 (38 케이스)
- 에이전트 프롬프트를 영어로, 사용자가 읽는 산출물은 한국어로 분리
- 우회 기록 파일명을 `bypasses.md` 로 (기존 워크스페이스의 옛 이름도 계속 인식)

---

## 이전 버전

| 버전 | 내용 |
|---|---|
| 0.8.1 | 슬래시 명령 네임스페이스화 (`/sboot-rehost:rehost-*`) + `disable-model-invocation` |
| 0.8.0 | `/rehost-init` 재도입 (폴더 스캐폴딩), 작업·예제 폴더 전부 gitignore |
| 0.7.0 | `/rehost-export` — 펌웨어·트랙별 "빌드 없이 실행" 키트 |
| 0.6.1 | `/rehost-setup` 이 이름만 받고, 트랙은 마지막에 프롬프트 |
| 0.6.0 | init→setup 통합, 펌웨어별 격리 워크스페이스, `_inbox` 자동 생성 |
| 0.5.0 | init/setup 분리, Windows cwd 문서 + WSL 대용량 쓰기, 자율 실행 |
| 0.4.0 | 두 트랙 분리, 실행 명령 분리, JOURNAL 기록, 자율 실행 |
| 0.2.0 | `/rehost-init` + `/rehost` 분리, 병렬 멀티에이전트용 `pipeline.js` |
