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

## 4. 과정

- **`/sboot-rehost:rehost-init`** — 작업 루트 + `_inbox/` 생성, 의존성(QEMU 10.2.2 / capstone / dtc) 확인·설치.
- **`/sboot-rehost:rehost-setup`** — 펌웨어 언팩 → 실행 사본 WSL 이동 → 자산 검증 → 트랙/등급 프롬프트 → `INPUT.md` + `.active`.
- **`/sboot-rehost:rehost-sboot`** — Static(bl3-analyzer + stub-locator) → Machine(machine.c + ninja) → 회차 루프(fault-fixer) → 5/5 검증 → 재현 키트.
- **`/sboot-rehost:rehost-kernel`** — Static(DTB + 커널 게이트) → Machine(+ 코어/커널 패치) → K1 유저스페이스 → K2 rootfs → K3 벤더 UFS 컨트롤러(파티션 + super 마운트) → 5/5 검증.
- **`/sboot-rehost:rehost-export`** — 완료 확인 → 프리빌트 QEMU + 펌웨어 + machine + docs + evidence + `run.sh` 조립(받는 사람은 `bash run.sh`).

---

## 5. 검증

성공은 **실제 트레이스·콘솔·커널 메시지**로만 판정(regex 매칭 단독 불인정). `reality-verifier` 5/5 통과 = REAL, 미달 = FORCED(성공 표기 금지). 우회는 전부 `[대상/이유/방법/부작용]` 기록.

---

## 6. 환경 / 기록 / 한계

- **환경**: WSL2(Ubuntu 22.04+). 첫 `/sboot-rehost:rehost-init` 이 QEMU 10.2.2(aarch64) 등 의존성을 자동 설치.
- **기록 위치**: 문서·기록(JOURNAL / PROGRESS / INPUT / console)은 로컬 작업 폴더, 대용량(펌웨어 실행 사본·트레이스)은 WSL. 펌웨어·작업 폴더는 전부 `.gitignore`.
- **한계**: 트랙 1 은 등급 A 안정. 트랙 2 K3 은 벤더 `.ko` 필요. 공통 프론티어 = `/data` 암호화 → TEE(TEEGRIS, 범위 밖).
