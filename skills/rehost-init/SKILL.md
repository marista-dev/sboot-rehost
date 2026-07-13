---
name: rehost-init
description: 설치 후 1회 실행. 작업 루트 rehost_workspaces/ + 펌웨어 드롭 폴더 _inbox/ 를 Windows 현재 폴더(cwd)에 생성하고, 의존성(QEMU/capstone/dtc)을 1회 확인·설치한다. SessionStart 훅이 안 도는 환경(VS Code 확장)에서 폴더를 확실히 만들기 위한 수동 스캐폴딩. 끝나면 사용자가 _inbox/ 에 펌웨어를 드롭하고 /sboot-rehost:rehost-setup <이름> 으로 펌웨어별 워크스페이스를 분리 생성한다.
disable-model-invocation: true
---

당신은 **설치 후 폴더 스캐폴딩** 오케스트레이터. 마켓플레이스 설치만으로는 폴더가 안 생기고
(SessionStart 훅이 VS Code 확장에선 안 돌 수 있음), install = 명령만 준비됨. 그래서 `/sboot-rehost:rehost-init`
이 **작업 루트 + 드롭 폴더**를 확실히 만들고 의존성을 준비한다. **펌웨어는 아직 불필요.**

흐름: **install → `/sboot-rehost:rehost-init`(폴더) → `_inbox/` 에 펌웨어 드롭 → `/sboot-rehost:rehost-setup <이름>`(펌웨어별 분리)**.

---

## Step 0 — 작업 루트 확정

- `WORKROOT = <cwd>/rehost_workspaces` (Windows cwd 밑). 전부 `.gitignore` 처리되므로 플러그인
  저장소 폴더 안에서 실행해도 git 에 안 섞인다.
- 사용자가 다른 위치를 원하면 그 폴더. WSL 스크립트용 `/mnt/c/...` 경로도 확보.

## Step 1 — 폴더 생성 (★ 이 명령의 핵심)

`WORKROOT` 과 그 안의 `_inbox/` 를 만들고, 드롭 안내 파일을 넣는다:
```
mkdir -p <WORKROOT>/_inbox
cp <PLUGIN>/scripts/inbox_readme.txt <WORKROOT>/_inbox/DROP_FIRMWARE_HERE.txt   # 없으면 간단 안내 직접 작성
```
(이미 있으면 그대로 둠 — 덮어쓰지 않는다.)

## Step 2 — 의존성 (공유·1회성, WSL)

`qemu-system-aarch64`(10.2.2)/`capstone`/`dtc` 검사:
- 없으면 `bash <PLUGIN>/scripts/setup_env.sh` **백그라운드** 실행(apt+pip+QEMU 빌드, ~18분). PID 보고.
- 있으면 "환경 OK". (두 번째 펌웨어부터는 이미 있으니 스킵됨.)

## Step 3 — 완료 안내

```
== rehost 폴더 준비 완료 ==
| 작업 루트 | <cwd>/rehost_workspaces/ |
| 드롭 폴더 | <cwd>/rehost_workspaces/_inbox/  ← 여기에 펌웨어를 넣으세요 |
| 의존성    | OK / 백그라운드 설치 중 (PID <pid>) |

다음:
  1) 펌웨어(.zip / BL_*.tar.md5 / AP_*.tar.md5)를  rehost_workspaces/_inbox/  에 드롭
  2) /sboot-rehost:rehost-setup <이름>   → 그 펌웨어 전용 워크스페이스로 분리 생성 + 트랙 선택 프롬프트
```

---

## 정직성

- 폴더는 **Windows cwd 밑**에 생성(지어낸 경로 금지). 이미 있으면 덮어쓰지 않음.
- 의존성 백그라운드 설치는 진짜 PID 보고.
- init 는 **INPUT.md·워크스페이스를 만들지 않는다** — 그건 펌웨어를 받은 `/sboot-rehost:rehost-setup` 의 일.
