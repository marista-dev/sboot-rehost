# 구성 요소

파일 하나가 무엇을 맡고, 무엇을 강제하는지의 목록이다.
운영 규칙의 정본은 [CLAUDE.md](../CLAUDE.md), 개념 설명은 [온보딩 문서](onboarding/README.md) 다.

> 원칙: **측정은 스크립트가, 해석과 제어는 에이전트가, 정지 판정의 입력값은 관측 사실이 맡는다.**

---

## 1. 흐름 제어

### `workflows/pipeline.js`

전체 흐름을 배선한다. 에이전트가 관측에 근거한 정지를 뒤집지 못하도록 강제하는 것이 핵심
역할이다.

```
버전 확인 → 환경 확인 → 도출 → 빌드 → (실행·분류·수정)* → 검증 → 재현 키트
```

| 강제하는 것 | 방법 |
|---|---|
| 최신 버전으로만 실행 | `check_version.sh` 를 첫 게이트로 |
| 실행 가능한 환경에서만 회차 소모 | `check_env.sh` 선행 |
| 목표 단계는 도출값 | `stage_map.json` 의 실행 가능 스테이지로 구성 |
| 정지 판정 우선 | `stop=true` 인데 계속 지시가 오면 강제 정지 + 모순 기록 |
| 정지는 인계 | 정지 직후 `make_resume.py` 호출 |
| 지시 맥락 보존 | 시작 시 사용자 입력 원문 기록 |

---

## 2. 에이전트 (`agents/`)

| 이름 | 역할 | 소스 수정 |
|---|---|---|
| `static-analyzer` | 바이너리·자산에서 사실 도출. 근거 없으면 "미확정" | 불가 |
| `supervisor` | 라우팅·정지·계층 판정·우회 철회 | 불가 |
| `fault-classifier` | 정지점 이름과 담당 지정. 모르면 `unknown` | 불가 |
| `fixer-memory` | 메모리 맵과 주변장치 창 | 가능 |
| `fixer-el3` | EL3·SMC·PSCI·FP 트랩 | 가능 |
| `fixer-bootflow` | 체인 제어 흐름, 핸드오프 슬롯, 콘솔 경로 | 가능 |
| `fixer-secureboot` | 부트로더 자체 서명 검증 (AVB·롤백 인덱스·키 저장소) | 가능 |
| `fixer-storage` | 스토리지 컨트롤러 모델, UPIU, 매체 구성 | 가능 |
| `fixer-kernel` | 커널 `.text` 패치, GIC 배선, rootfs 경로 | 가능 |
| `fixer-general` | 담당이 없을 때만. 범위 무제한 | 가능 |
| `verifier` | 스크립트 측정을 2차 재검증 | 불가 |

**수정 권한은 fixer 에게만 있다.** 분류하는 쪽과 고치는 쪽이 같으면 고칠 대상을 만들기 위해
없는 원인을 지목하게 된다.

`fixer-general` 은 전문가가 전부 반려했을 때만 도달하며 순위로는 선택되지 않는다.
범위가 무제한이라 "시도할 것이 없다"는 답이 잘 나오지 않으므로, 지문을 움직이지 못한 변경은
시도로 세지 않는다.

---

## 3. 도출

| 스크립트 | 역할 |
|---|---|
| `stage_map.py` | 스테이지 지도 도출 → `stage_map.json` |
| `carve_disasm.py` | capstone 래퍼 (디스어셈블·교차참조·엔트리 점수) |
| `derived_facts.py` | 도출표에 늘어난 줄 수 측정 (자기 신고 방지) |
| `static_rotate.py` | 도출 기록이 커지면 근거는 보관하고 표는 유지 |

### `stage_map.py` 의 4단계

| # | 단계 | 방법 |
|---|---|---|
| 1 | 구간 분류 | 엔트로피 격자 (평문 / 암호화 / 제로) |
| 2 | 스테이지 경계 | 아키텍처별 리셋 스텁 시그니처 |
| 3 | 구간 식별 | 문자열 문맥 (`profiles/*.yaml` 의 힌트) |
| 4 | 적재 주소 | basefind + **리터럴 앵커 교차 검증** |

4단계의 교차 검증은 생략할 수 없다. 포인터 포함률만으로 고른 후보는 실제 펌웨어에서 틀렸고,
BSS 포인터를 파일 오프셋으로 환산해 제로 패딩 시작 지점에 착지해야 확정값이 된다.
앵커가 없으면 `candidate` 로 표기되며 확정값으로 쓰지 않는다.

아키텍처의 시그니처가 없으면 종료코드 3 을 반환한다. **"스테이지 없음"이 아니라 "도구 없음"**
이며, 파이프라인은 `BLOCKED_ARCH` 로 정지한다.

---

## 4. 실행

| 스크립트 | 역할 | 강제하는 것 |
|---|---|---|
| `run_round.sh` | 회차 1회 → 관측 문서 1개 | 에이전트가 정지 판정을 조립하지 못하게 |
| `run_full.sh` | QEMU 실행 → 지문 추출 · 출력 출처 검증 · 실행 실패 판정 | 규칙 7 (매 회차) |
| `uart_harness.py` | QEMU 외부에서 콘솔 입력 주입 | 입력은 외부에서만 |
| `fingerprint_lib.sh` | 최초 예외 추출 · 콘솔 고유 줄 수 | 재귀 말미가 아니라 원인을 지문으로 |
| `build_lu.py` | 부팅 매체 합성 (GPT + 파티션) | 파티션 이름은 도출값 |

### `run_full.sh` 가 하는 일

```
① uart_harness.py 로 QEMU 실행 (종료코드 보존)
② 실행 성공 판정
③ 최초 예외 블록 추출
④ 요약 로그 생성
⑤ 지문 추출 (콘솔 고유 줄 수 포함)
⑥ 마일스톤 판정 + 출력 출처 검증
⑦ 타임아웃 프로브 (정체된 정지 상태일 때만 1회)
```

QEMU 에 **커널·DTB·initrd 를 넘기지 않는다.** 부트로더 컨테이너와 합성 매체만 붙인다.

---

## 5. 검문과 정지

| 스크립트 | 역할 |
|---|---|
| `check_version.sh` | 로드된 플러그인 버전 확인 (첫 게이트) |
| `check_env.sh` | QEMU·ninja·capstone·dtc·WSL 확인 |
| `check_change.sh` | 변경 1건 검문 (diff + 우회 기록) + 회차별 스냅샷 |
| `revert_change.sh` | 반증된 우회를 해당 회차 변경만 역패치 |
| `sync_machine.sh` | 워크스페이스 소스를 QEMU 트리에 반영 |
| `stop_conditions.py` | 정지 조건 계산 |
| `patch_kernel.py` | 커널 패치 (사전 이미지 불일치면 적용 거부) |
| `patch_qemu_core.py` | QEMU 코어 SMC 패치 (멱등) |

`sync_machine.sh` 가 없으면 검문을 통과하고 빌드도 성공하는데 이전 바이너리를 측정하게 된다.
회차 적용·재생성·general fixer 모두 ninja 앞에 이것을 호출한다.

---

## 6. 검증

| 스크립트 | 역할 |
|---|---|
| `verify.py` | 6항목 측정 → `verdict_script.json` |
| `verify_byte_match.py` | 콘솔 토큰의 파일 오프셋 대조 |

| # | 항목 |
|---|---|
| 1 | 체인 실행 트레이스 (스테이지 진입 PC 가 순서대로 + 커널 진입) |
| 2 | 출력 바이트 대조 |
| 3 | 소스 반증 |
| 4 | 검증 양방향 (정상 통과 + 훼손 실패) |
| 5 | 스토리지 이중 구동 |
| 6 | 우회 기록 |

**6/6 만 REAL.** 2단계에서 verifier 가 재검증하며, 낮추는 것은 자유롭고 올리는 것은
바이트 수준 증거가 있을 때만이다.

---

## 7. 기록

| 스크립트 | 산출 |
|---|---|
| `journal.sh` | `JOURNAL.md` — 세션·회차·판단·사용자 입력·가설·해결 경위 |
| `record.py` | `metrics` · `rounds` · `blockers` · `prompts` · `resolutions` (JSONL) |
| `make_resume.py` | `RESUME.md` — 정지 시 인계 문서 |
| `analyze_run.py` | `ANALYSIS.md` · `analysis.json` — 소요·비용·정체·해결 경위 |
| `make_export.sh` | 재현 키트 |

- 시각은 반드시 실제 `date` 출력을 쓴다.
- 사용자 입력은 요약하지 않고 원문 그대로 남긴다.
- fixer 를 지정한 회차는 변경 사유가 필수이며, 없으면 그렇게 표시된다.

---

## 8. 데이터

| 파일 | 내용 |
|---|---|
| `fixers/registry.yaml` | 정지점 → 담당 fixer. `not_firmware` 와 `build_layer` 목록 포함 |
| `knowledge/faults_unified.md` | 정지점 분류표 (체인 위치별) |
| `knowledge/faults_storage.md` | 스토리지 컨트롤러 상세 |
| `knowledge/kernel_gates.md` | 커널 보안 게이트 패치 지점 도출 절차 |
| `profiles/*.yaml` | SoC 탐색 힌트 — **값이 아니라 어디를 볼지** |
| `templates/machine_full.c.tmpl` | 통합 머신 템플릿 |
| `templates/storage_hci.c.tmpl` | 스토리지 컨트롤러 템플릿 |

**새 정지점은 분류표 한 줄, 새 fixer 는 파일 하나와 등록 몇 줄이다.** 프롬프트는 고치지 않는다.

### `registry.yaml` 의 세 분류

| 분류 | 뜻 |
|---|---|
| `fixers` | 담당이 있는 정지점 |
| `not_firmware` | 펌웨어에 대한 사실이 아닌 것 (예: 하네스 입력 실패). fixer 를 배정하면 없는 결함을 고치게 된다 |
| `build_layer` | 회차로 고칠 수 없는 전제. supervisor 가 머신 재생성으로 라우팅 |

---

## 9. 워크스페이스 산출물

| 파일 | 내용 |
|---|---|
| `INPUT.md` | 입력 슬롯 |
| `STATIC.md` | 도출 기록 (추가 전용) |
| `stage_map.json` | 스테이지 지도 |
| `lu_manifest.json` | 매체 파티션 구성 |
| `milestone_tokens.txt` | 목표 단계별 관측 문자열 |
| `input_plan.json` | 입력 게이트 패턴 |
| `fingerprint.json` | 마지막 회차 지문 |
| `observation.json` | 마지막 회차 관측 문서 |
| `verdict_script.json` | 6항목 측정 |
| `VERIFICATION.md` | verifier 최종 판정 |
| `06_machine/bypasses.md` | 우회 기록 |
| `RESUME.md` | 정지 시 인계 문서 |
