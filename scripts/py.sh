#!/usr/bin/env bash
# py.sh - run a scripts/*.py through the same WSL bridge the shell scripts use.
#
# Python is the one thing the guard cannot cover on its own: a Windows shell has
# no python3 to run the guard in, so `python3 record.py` dies before any of our
# code executes. Routing python through a shell entry point puts it back under
# the guard.
#
# Usage: bash py.sh <script.py> [args...]

. "$(dirname "$0")/wsl_bridge.sh"

set -u
SCRIPTS="$(cd "$(dirname "$0")" && pwd)"
PY="${1:?usage: py.sh <script.py> [args...]}"; shift
exec python3 "$SCRIPTS/$PY" "$@"
