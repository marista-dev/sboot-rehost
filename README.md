# sboot-rehost

벤더 펌웨어를 QEMU 위에서 **진짜로 실행**시키고, 실증 가능한 증거로만 도달 여부를
판정하는 리호스팅 하니스. Claude Code 플러그인.

- **트랙 1 (sboot-shell)** — 부트로더 BL3 → 진짜 `S-BOOT #` 셸 + `help`
- **트랙 2 (kernel-storage)** — 커널 직부팅 → rootfs 마운트 → 진짜 벤더 UFS 컨트롤러 → Android

재구현이 아니라 **원본 바이너리를 구동**한다. 모델링하는 것은 환경(페리페럴·SMC·HCI)뿐이고,
값은 전부 대상 펌웨어에서 도출한다.

---

## 1. 설치

**전제**: `hyu-sslab` org 접근 권한 + 로컬 git 인증(HTTPS 토큰 또는 SSH).

### CLI (터미널)
```
/plugin marketplace add hyu-sslab/sboot-rehost
/plugin install sboot-rehost@sboot-rehost-marketplace
/reload-plugins
```

### VS Code 확장
프롬프트 상자에 **`/plugins`** (복수형) 를 입력하면 **Manage plugins** 창이 열린다.

1. **Marketplaces** 탭 → 입력란에 `hyu-sslab/sboot-rehost` 를 넣어 마켓플레이스 추가
2. **Plugins** 탭 → 목록에서 `sboot-rehost` 찾아 **Install**
3. 설치 범위 선택 — *Install for you*(전체 프로젝트) / *Install for this project* / *Install locally*
4. 하단 배너의 안내대로 **Claude Code 재시작**

> 확장의 플러그인 관리는 내부적으로 CLI 와 같은 명령을 쓴다. 확장에서 추가한
> 마켓플레이스·플러그인은 CLI 에서도 그대로 보이고 그 반대도 같다.

---

## 2. 업데이트

### CLI (터미널)
```
/plugin marketplace update sboot-rehost-marketplace   # 카탈로그 갱신
/reload-plugins                                       # 재시작 없이 적용
```

`/plugin` 을 실행하면 4개 탭(**Discover · Installed · Marketplaces · Errors**)이 있는
관리 화면이 열린다. **Marketplaces** 탭에서 갱신·삭제를 GUI 로도 할 수 있다.

### VS Code 확장
1. 프롬프트 상자에 **`/plugins`** 입력
2. **Marketplaces** 탭으로 이동
3. `sboot-rehost-marketplace` 옆의 **새로고침(refresh) 아이콘** 클릭 → 플러그인 목록 갱신
4. 배너가 뜨면 **Claude Code 재시작**

### 자동 업데이트 (기본 꺼짐)

Claude Code 는 세션 시작 후 백그라운드에서 마켓플레이스와 설치된 플러그인을 자동으로
갱신할 수 있다. 다만 **서드파티 마켓플레이스는 자동 업데이트가 기본 비활성**이다
(Anthropic 공식 마켓플레이스만 기본 활성). 이 플러그인도 서드파티이므로 켜려면:

```
/plugin  →  Marketplaces 탭  →  sboot-rehost-marketplace 선택  →  Enable auto-update
```

켜 두면 세션 시작 후 최대 10분 이내 무작위 지연을 두고 확인하며, 갱신되면
`/reload-plugins` 를 실행하라는 알림이 뜬다(또는 다음 실행 때 새 버전이 로드된다).
실행 중인 세션은 시작 시점에 로드한 버전을 계속 쓴다.

### 업데이트가 안 될 때

| 증상 | 조치 |
|---|---|
| 새 명령·스킬이 안 보임 | `/reload-plugins` → 그래도 안 되면 Claude Code 재시작 |
| 마켓플레이스에 플러그인이 없다고 나옴 | 로컬 카탈로그가 낡음 → `/plugin marketplace update sboot-rehost-marketplace` |
| 스킬이 계속 안 나타남 | 캐시 삭제 후 재설치: `rm -rf ~/.claude/plugins/cache` → Claude Code 재시작 |
| `/plugin` 명령 자체가 없음 | Claude Code 가 오래됨. `claude --version` 확인 후 업데이트 (`npm install -g @anthropic-ai/claude-code@latest` 또는 `brew upgrade claude-code`) |

각 버전에 무엇이 들어갔는지는 [CHANGELOG.md](CHANGELOG.md) 에 있다.

> **★ 메인테이너 주의 — `version` 을 올려야 배포된다**
>
> `plugin.json` 에 `version` 이 **설정돼 있으면 사용자는 그 값을 올렸을 때만 업데이트를
> 받는다.** 커밋만 푸시하고 버전을 그대로 두면 사용자 쪽에서는 아무 일도 일어나지 않는다.
> 새 버전을 낼 때는 다음 셋을 **함께** 갱신해 푸시한다:
> `.claude-plugin/plugin.json` · `.claude-plugin/marketplace.json` · `CHANGELOG.md`.
> (`version` 을 아예 비우면 git 커밋 SHA 가 버전이 되어 매 커밋이 새 버전이 된다.)

출처: [Discover and install plugins](https://code.claude.com/docs/en/discover-plugins) ·
[Use Claude Code in VS Code](https://code.claude.com/docs/en/vs-code) ·
[Create plugins](https://code.claude.com/docs/en/plugins)

---

## 3. 사용

**① 폴더 준비 (설치 후 1회)**
```
/sboot-rehost:rehost-init
```

**② 펌웨어 드롭** — `rehost_workspaces/_inbox/` 에 `.zip` / `BL_*.tar.md5` / `AP_*.tar.md5` 를 넣는다.

**③ 펌웨어 세팅** — 이름만 주면 자동 인식 + 격리 워크스페이스 생성 + 트랙·등급 프롬프트:
```
/sboot-rehost:rehost-setup a166b
```

**④ 실행** — 프롬프트에서 고른 트랙 하나. 시작하면 **끝까지 자율**로 진행한다.
```
/sboot-rehost:rehost-sboot     (트랙 1)
/sboot-rehost:rehost-kernel    (트랙 2)
```

**⑤ 상태 / 내보내기**
```
/sboot-rehost:rehost-status
/sboot-rehost:rehost-export
```

- 다른 펌웨어: `_inbox/` 에 드롭 후 `/sboot-rehost:rehost-setup <다른이름>` → 새 워크스페이스(기존 안 덮어씀).
- 특정 워크스페이스 실행: `/sboot-rehost:rehost-sboot workdir=<이름>`.

---

## 4. 명령어

| 명령 | 역할 |
|---|---|
| `rehost-init` | 작업 루트 + `_inbox/` 생성, 의존성 설치 (1회) |
| `rehost-setup <이름>` | 펌웨어 인식 → 격리 워크스페이스 + 트랙·등급 → `INPUT.md` |
| `rehost-sboot` | 트랙 1 실행 — BL3 → 셸 + `help` |
| `rehost-kernel` | 트랙 2 실행 — 커널 + 진짜 UFS 컨트롤러 → rootfs·Android |
| `rehost-status` | 워크스페이스 목록 + 진행·검증·정지·소요 요약 |
| `rehost-export` | 완료 후 "빌드 없이 실행" 키트 → `rehost_exports/<fw>/track<N>/` |

전부 `/sboot-rehost:` 접두사를 붙인다.
자세한 동작은 [docs/components.md](docs/components.md#슬래시-명령).

---

## 5. 구조

**측정은 스크립트, 해석·제어는 LLM, 정지의 입력값은 사실.**

```
[static-analyzer] 도출 → (Build) machine 소스 + ninja
   → { (run_round) 실행·지문·출처게이트·정지조건 → [supervisor] 라우팅
        → [fault-classifier] 분류 → [fixer] 한 변경 → (check_change) → ninja }*
   → (verify.py 측정) → [verifier 재검증] → REAL | FORCED → 재현 키트
```

| 구분 | 컴포넌트 |
|---|---|
| **LLM** | `static-analyzer`(도출) · `supervisor`(라우팅·정지) · `fault-classifier`(분류) · `fixer-memory`/`el3`/`bootflow`/`kernel`/`storage`(수정) · `verifier`(재검증) |
| **결정론** | `pipeline.js` · `run_round.sh` · `check_change.sh` · `stop_conditions.py` · `verify.py` · `record.py` |
| **데이터** | `fixers/registry.yaml` · `knowledge/*.md` · `profiles/*.yaml` |

**LLM 중 코드를 고치는 것은 `fixer-*` 뿐이다.** 분류하는 쪽에 수리 권한이 없어야
없는 병명을 지어내지 않는다.

**새 정지점 = 테이블 한 줄. 새 fixer = 파일 하나 + 등록부 몇 줄.**
프롬프트도 오케스트레이션 코드도 건드리지 않는다.

각 컴포넌트의 역할·입출력·동작 과정은 [docs/components.md](docs/components.md) 에
실행 순서대로(Analysis → Build → Run → Manage → Diagnosis → Fix → Verify → Package)
정리돼 있다.

---

## 6. 검증 (2단, 방향 비대칭)

성공은 **실제 트레이스·콘솔·커널 메시지**로만 판정한다(regex 단독 불인정).

1. `verify.py` 가 5 항목을 **코드로 측정** → `verdict_script.json`
2. `verifier`(LLM)가 원시 로그·바이트로 **재검증** → `VERIFICATION.md`
   - 낮추는 방향(REAL→FORCED)은 LLM 우선
   - **올리는 방향(FORCED→REAL)은 byte-level 증거가 있을 때만**

**5/5 = REAL, 4/5 이하 = FORCED**(성공 표기 금지). 우회는 전부
`[대상/이유/방법/부작용]` 4항목으로 기록한다.

또 하나의 층으로, **매 회차 출처 게이트**가 도달 문구를 우리 머신이 찍은 것인지
검사한다(자가주입 금지).
→ [docs/components.md](docs/components.md#7-verify) · [정직성 규칙과 집행 주체](docs/components.md#정직성-규칙-7항과-집행-주체)

---

## 7. 멈추는 조건

**회차 수·소요 시간은 멈출 이유가 아니다.** 시도할 수(手)가 남아 있는 한 계속한다.
멈추는 경우는 **구조상 목표에 도달할 수 없을 때뿐**이다:

`BLOCKED_CARVE` · `BLOCKED_ASSET` · `BLOCKED_KO` · `BLOCKED_BUILD` · `BLOCKED_TEE` ·
`EXHAUSTED`(**무브 소진** — 지문 정체·진동 + 새 사실 0 + 새 시도 0)

정지는 `success=false` 인 **정직한 미완**이며 재실행하면 이어서 진행된다.
이 판정은 스크립트가 소유하며 **LLM 이 뒤집을 수 없다** — 뒤집으려 하면 파이프라인이
강제 정지하고 모순을 기록한다.

---

## 8. 환경 / 기록 / 한계

- **환경**: WSL2(Ubuntu 22.04+). 첫 `rehost-init` 이 QEMU 10.2.2(aarch64) 등을 자동 설치.
- **기록**: 사람이 읽는 `JOURNAL.md`/`PROGRESS.md`/`VERIFICATION.md` +
  기계가 읽는 `metrics.jsonl`(시간·토큰) · `rounds.jsonl`(회차 지문·분류·효과) ·
  `blockers.jsonl`(정지 사유). 문서는 로컬 작업 폴더, 대용량(실행 사본·트레이스)은 WSL.
  펌웨어·작업 폴더는 전부 `.gitignore`. → [docs/components.md](docs/components.md#기록-사람용--기계용)
- **한계**: 트랙 1 은 등급 A 안정. 트랙 2 K3 은 벤더 `.ko` 필요.
  공통 프론티어 = `/data` 암호화 → TEE(TEEGRIS, 범위 밖).

---

## 9. 문서

**[docs/components.md](docs/components.md)** — 아키텍처의 각 컴포넌트를 실행 순서대로
정리한 문서. 컴포넌트마다 역할 · 정체 · 입력/출력 · 동작 과정 · 규칙을 항목화했다.

| 절 | 내용 |
|---|---|
| [1. Analysis](docs/components.md#1-analysis) | 바이너리·자산 → 근거 있는 사실 (도출 12항목) |
| [2. Build](docs/components.md#2-build) | 사실 → 머신 소스 → ninja |
| [3. Run](docs/components.md#3-run) | 실행 → 지문 + **출처 게이트** |
| [4. Manage](docs/components.md#4-manage) | 라우팅 · 정지 조건 · 목표 사다리 |
| [5. Diagnosis](docs/components.md#5-diagnosis) | 정지점 이름 + 담당 fixer 순위 |
| [6. Fix](docs/components.md#6-fix) | fixer 5종 · 한 변경 검문 |
| [7. Verify](docs/components.md#7-verify) | 5/5 측정 → 재검증 (방향 비대칭) |
| [8. Package](docs/components.md#8-package) | 재현 키트 · export |
| [데이터](docs/components.md#데이터-지식--프로세스-분리) | 등록부 · 지식 테이블 · SoC 프로필 |
| [기록](docs/components.md#기록-사람용--기계용) | JOURNAL · JSONL 측정치 |
| [정직성](docs/components.md#정직성-규칙-7항과-집행-주체) | 규칙 7항과 집행 주체 |

방법론 원본(도출 절차와 Table A~M)은 [methodology/](methodology/) 에 있다.

회귀 검증: `bash tests/smoke.sh` (결정론 계층 38 케이스).
