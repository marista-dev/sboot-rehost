# sboot-rehost

Claude Code 플러그인.

- **트랙 1 (sboot-shell)** — 부트로더 BL3 → 진짜 `S-BOOT #` 셸 + `help`
- **트랙 2 (kernel-storage)** — 커널 직부팅 → rootfs 마운트 → 진짜 벤더 UFS 컨트롤러 → Android

---

## 1. 설치 (마켓플레이스)

**전제**: `hyu-sslab` org 접근 권한 + 로컬 git 인증(HTTPS 토큰 또는 SSH).


```
/plugin marketplace add hyu-sslab/sboot-rehost
```
```
/plugin install sboot-rehost@sboot-rehost-marketplace
```

**VS Code 확장**은 `/plugin` 대신 `/plugins` 로 관리창을 연 뒤 **Add marketplace** `hyu-sslab/sboot-rehost` → **Install** `sboot-rehost`.

새 버전 받기:

```
/plugin marketplace update sboot-rehost-marketplace
```

---

## 2. 사용

**① 폴더 준비 (설치 후 1회)** — 작업 폴더에 `rehost_workspaces/_inbox/` 생성:

```
/sboot-rehost:rehost-init
```

**② 펌웨어 드롭** — `rehost_workspaces/_inbox/` 에 펌웨어(`.zip` / `BL_*.tar.md5` / `AP_*.tar.md5`)를 넣는다.

**③ 펌웨어 세팅** — 이름만 주면 자동 인식 + 격리 워크스페이스 생성 + 끝에 "트랙(1 sboot / 2 kernel)·등급" 프롬프트:

```
/sboot-rehost:rehost-setup a166b
```

**④ 실행** — 프롬프트에서 고른 트랙 하나:

```
/sboot-rehost:rehost-sboot
```
```
/sboot-rehost:rehost-kernel
```

**⑤ 상태 / 내보내기**:

```
/sboot-rehost:rehost-status
```
```
/sboot-rehost:rehost-export
```

- 다른 펌웨어: `_inbox/` 에 드롭 후 `/sboot-rehost:rehost-setup <다른이름>` → 새 워크스페이스(기존 안 덮어씀).
- 특정 워크스페이스 실행: `/sboot-rehost:rehost-sboot workdir=<이름>`.

---

## 3. 명령어

| 명령 | 역할 |
|---|---|
| `/sboot-rehost:rehost-init` | 작업 루트 `rehost_workspaces/` + 드롭 폴더 `_inbox/` 생성 + 의존성 설치(1회) |
| `/sboot-rehost:rehost-setup <이름>` | `_inbox/` 펌웨어 자동 인식 → 격리 워크스페이스 + 트랙/등급 프롬프트 → `INPUT.md` |
| `/sboot-rehost:rehost-sboot` | 트랙 1 실행 — S-Boot BL3 → 셸 + `help` |
| `/sboot-rehost:rehost-kernel` | 트랙 2 실행 — 커널 + 진짜 UFS 컨트롤러 → rootfs·Android |
| `/sboot-rehost:rehost-status` | 워크스페이스 목록 + 진행/검증 요약 |
| `/sboot-rehost:rehost-export` | 완료 후 "빌드 없이 실행" 키트 → `rehost_exports/<fw>/track<N>/` |

- 펌웨어당 워크스페이스 1개(격리, 서로 안 덮어씀). 실행 대상 = `.active` 또는 `workdir=<이름>`.
- 등급: 트랙 1 = A/B/C, 트랙 2 = K1/K2/K3(진짜 파티션 + super 마운트까지).
- 실행 명령은 자율 진행(하드 블로커 전까지 안 멈춤).

---

## 4. 구조

**측정은 스크립트, 해석·제어는 LLM, 정지의 입력값은 사실.**
트랙은 정체성이 아니라 인자이며, `workflows/pipeline.js` 하나가 둘 다 돈다.

```
[static-analyzer] 도출 → (Build) machine + ninja
   → { (run) 지문·출처게이트 → [supervisor] 라우팅
        → [fault-classifier] 분류·fixer 순위 → [fixer] 한 변경 → (검문) }*
   → (verify.py 측정) → [verifier 재검증] → REAL | FORCED → 키트
```

| 구성 | 이름 |
|---|---|
| **LLM** | `static-analyzer`(도출) · `supervisor`(라우팅·정지) · `fault-classifier`(분류) · `fixer-memory`/`el3`/`bootflow`/`kernel`/`storage`(수정) · `verifier`(재검증) |
| **스크립트** | `run_qemu.sh`/`run_kernel.sh`(실행+지문+출처게이트) · `check_change.sh`(한 변경 검문) · `stop_conditions.py`(정지) · `verify.py`(5/5 측정) · `record.py`(측정 기록) |
| **데이터** | `fixers/registry.yaml`(오류→fixer) · `knowledge/*.md`(정지점 테이블) · `profiles/*.yaml`(SoC 힌트) |

**fixer 만 코드를 고친다.** 새 정지점 = 테이블 한 줄, 새 fixer = 파일 하나 + 등록부 몇 줄.

---

## 5. 검증 (2 단, 방향 비대칭)

성공은 **실제 트레이스·콘솔·커널 메시지**로만 판정(regex 단독 불인정).

1. `verify.py` 가 5 항목을 **코드로 측정** → `verdict_script.json`
2. `verifier`(LLM) 가 원시 로그·바이트로 **재검증** → `VERIFICATION.md`
   - 낮추는 방향(REAL→FORCED)은 LLM 우선
   - **올리는 방향(FORCED→REAL)은 byte-level 증거가 있을 때만**

**5/5 = REAL, 4/5 이하 = FORCED**(성공 표기 금지). 우회는 전부 `[대상/이유/방법/부작용]` 기록.

---

## 6. 멈추는 조건

**회차 수·소요 시간은 멈출 이유가 아니다.** 시도할 수(手)가 남아 있는 한 계속한다.
멈추는 경우는 **구조상 목표에 도달할 수 없을 때뿐**이다:

`BLOCKED_CARVE`(BL3 carve) · `BLOCKED_ASSET`(자산 없음) · `BLOCKED_KO`(K3 인데 벤더 `.ko` 부재) ·
`BLOCKED_BUILD`(빌드 실패) · `BLOCKED_TEE`(시큐어월드, 범위 밖) ·
`EXHAUSTED`(**무브 소진** — 지문 정체·진동 + 새 사실 0 + 새 시도 0)

정지는 `success=false` 인 **정직한 미완**이며 재실행하면 이어서 진행된다.
이 판정은 스크립트가 소유하며 LLM 이 뒤집을 수 없다.

---

## 7. 환경 / 기록 / 한계

- **환경**: WSL2(Ubuntu 22.04+). 첫 `/sboot-rehost:rehost-init` 이 QEMU 10.2.2(aarch64) 등 의존성을 자동 설치.
- **기록**: 사람이 읽는 `JOURNAL.md`/`PROGRESS.md`/`VERIFICATION.md` + 기계가 읽는
  `metrics.jsonl`(시간·토큰) · `rounds.jsonl`(회차 지문/분류/fixer/효과) · `blockers.jsonl`(정지 사유).
  문서·기록은 로컬 작업 폴더, 대용량(실행 사본·트레이스)은 WSL. 펌웨어·작업 폴더는 전부 `.gitignore`.
- **한계**: 트랙 1 은 등급 A 안정. 트랙 2 K3 은 벤더 `.ko` 필요. 공통 프론티어 = `/data` 암호화 → TEE(TEEGRIS, 범위 밖).
