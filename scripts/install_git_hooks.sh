#!/usr/bin/env bash
# install_git_hooks.sh — 이 저장소의 git 훅을 켠다 (pre-push 릴리스 검문).
# 훅은 .git/ 안에 있어 커밋되지 않으므로, 클론한 사람이 한 번 실행해야 한다.
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
git config core.hooksPath scripts/git-hooks
chmod +x scripts/git-hooks/* 2>/dev/null || true
echo "git 훅 활성화: core.hooksPath=scripts/git-hooks"
echo "  pre-push — 버전을 올리지 않은 배포를 막습니다"
echo "  해제하려면: git config --unset core.hooksPath"
