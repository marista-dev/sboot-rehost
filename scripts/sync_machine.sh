#!/usr/bin/env bash
. "$(dirname "$0")/wsl_bridge.sh"
# sync_machine.sh - copy the workspace machine sources into the QEMU source tree.
#
# Usage:
#   sync_machine.sh <workdir> <machine_name> [qemu_root]
#
# Why this exists
# ---------------
# A fixer edits <workdir>/06_machine/machine.c - that is the file the one-change
# gate snapshots and diffs. What ninja compiles is the COPY that lives in the
# QEMU tree under hw/arm/. Nothing carried the edit from one to the other, so a
# round could pass its gate, rebuild cleanly, and run the previous binary. The
# fingerprint then did not move, the diagnosis was recorded as futile, and the
# run eventually declared itself out of moves - on a fix that was never in the
# binary. Five rounds of the S921N log burned exactly this way, byte-identical
# traces and all.
#
# Mapping, in order:
#   1. <workdir>/06_machine/qemu_targets.txt  (lines "<basename>\t<abs dest>")
#      written here on first success, so an unusual layout only needs solving once
#   2. hw/arm/<machine with '-' replaced by '_'>.c   - the name Build is told to use
#   3. hw/arm/<same basename>                        - a file already there
#
# Exit: 0 synced (or nothing to do), 3 a source could not be mapped.
# stdout: one JSON object.

set -u

WD="${1:?workdir required}"
MACHINE="${2:?machine name required}"
QEMU_ROOT="${3:-${QEMU_ROOT:-$HOME/qemu-build/qemu-10.2.2}}"

SRC="$WD/06_machine"
HW="$QEMU_ROOT/hw/arm"
MAP="$SRC/qemu_targets.txt"
TAB="$(printf '\t')"

json_escape() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g' | tr -d '\n\r\t'; }

if [ ! -d "$SRC" ]; then
    printf '{"synced":0,"skipped":true,"reason":"%s 가 없습니다"}\n' "$(json_escape "$SRC")"
    exit 0
fi
if [ ! -d "$HW" ]; then
    printf '{"synced":0,"error":true,"reason":"QEMU 소스 트리를 찾을 수 없습니다: %s (QEMU_ROOT 로 지정하세요)"}\n' \
        "$(json_escape "$HW")"
    exit 3
fi

MACHINE_FILE="$(printf '%s' "$MACHINE" | tr '-' '_').c"

mapped_dest() {   # $1 = basename -> echoes dest path or empty
    local base="$1" line
    if [ -f "$MAP" ]; then
        line=$(grep -F "${base}${TAB}" "$MAP" 2>/dev/null | tail -1)
        if [ -n "$line" ]; then printf '%s' "${line#*$TAB}"; return 0; fi
    fi
    case "$base" in
        machine.c|machine_kernel.c)
            [ -f "$HW/$MACHINE_FILE" ] && { printf '%s' "$HW/$MACHINE_FILE"; return 0; }
            ;;
    esac
    [ -f "$HW/$base" ] && { printf '%s' "$HW/$base"; return 0; }
    printf ''
}

SYNCED=0; UNMAPPED=""; TARGETS=""
for cur in "$SRC"/*.c "$SRC"/*.h; do
    [ -f "$cur" ] || continue
    base="$(basename "$cur")"
    dest="$(mapped_dest "$base")"
    if [ -z "$dest" ]; then
        UNMAPPED="${UNMAPPED:+$UNMAPPED, }$base"
        continue
    fi
    if ! cmp -s "$cur" "$dest"; then
        cp "$cur" "$dest" || {
            UNMAPPED="${UNMAPPED:+$UNMAPPED, }$base(복사 실패)"
            continue
        }
        SYNCED=$((SYNCED + 1))
    fi
    TARGETS="${TARGETS:+$TARGETS, }$base -> $dest"
    # Remember the mapping so the next round does not have to rediscover it.
    if ! grep -qF "${base}${TAB}${dest}" "$MAP" 2>/dev/null; then
        printf '%s\t%s\n' "$base" "$dest" >> "$MAP"
    fi
done

if [ -n "$UNMAPPED" ]; then
    printf '{"synced":%d,"unmapped":"%s","targets":"%s","reason":"QEMU 트리에서 대상 파일을 찾지 못했습니다 — hw/arm/%s 로 복사하고 meson.build 에 등록했는지 확인하세요"}\n' \
        "$SYNCED" "$(json_escape "$UNMAPPED")" "$(json_escape "$TARGETS")" "$(json_escape "$MACHINE_FILE")"
    exit 3
fi

printf '{"synced":%d,"unmapped":"","targets":"%s"}\n' "$SYNCED" "$(json_escape "$TARGETS")"
exit 0
