#!/usr/bin/env bash
. "$(dirname "$0")/wsl_bridge.sh"
# extract_boot_assets.sh — 커널 부팅 자산 추출 (일반, 표준 언팩).
# 펌웨어 tar/img 에서 Image / DTB / initrd / super 를 <workdir>/fw 로.
#
# 사용법:
#   extract_boot_assets.sh <workdir> <boot.img> [super.img.lz4|super.img] [dtb]
#
# 도출 아님 — 표준 Android boot image + super 언팩. 같은 빌드 자산만.
set -e
WORKDIR="$1"; BOOTIMG="$2"; SUPER="$3"; DTBIN="$4"
[ -z "$WORKDIR" -o -z "$BOOTIMG" ] && { echo "Usage: $0 <workdir> <boot.img> [super] [dtb]" >&2; exit 1; }
FW="$WORKDIR/fw"; mkdir -p "$FW"

echo "== boot.img 언팩 =="
if command -v unpack_bootimg >/dev/null 2>&1; then
    unpack_bootimg --boot_img "$BOOTIMG" --out "$FW/_boot" >/dev/null
    cp "$FW/_boot/kernel"  "$FW/Image.gz" 2>/dev/null || cp "$FW/_boot/kernel" "$FW/Image"
    cp "$FW/_boot/ramdisk" "$FW/initramfs.cpio.gz" 2>/dev/null || true
    ls "$FW/_boot"/dtb* >/dev/null 2>&1 && cp "$FW/_boot"/dtb* "$FW/" || true
else
    echo "  unpack_bootimg 없음 — python 헤더 파싱 폴백"
    python3 - "$BOOTIMG" "$FW" <<'PY'
import sys,struct,os
b=open(sys.argv[1],'rb').read(); fw=sys.argv[2]
assert b[:8]==b'ANDROID!', "not an Android boot image"
ps=struct.unpack_from('<I',b,0x28)[0] or 4096   # page size
ks=struct.unpack_from('<I',b,0x08)[0]           # kernel size
rs=struct.unpack_from('<I',b,0x10)[0]           # ramdisk size
def rup(n): return (n+ps-1)//ps*ps
ko=ps; ro=ko+rup(ks)
open(os.path.join(fw,'Image.gz' if b[ko:ko+2]==b'\x1f\x8b' else 'Image'),'wb').write(b[ko:ko+ks])
if rs: open(os.path.join(fw,'initramfs.cpio.gz'),'wb').write(b[ro:ro+rs])
print("  kernel",ks,"ramdisk",rs)
PY
fi

# gzip 커널 해제
if [ -f "$FW/Image.gz" ]; then gunzip -f "$FW/Image.gz" && echo "  gunzip Image"; fi

echo "== DTB =="
if [ -n "$DTBIN" ] && [ -f "$DTBIN" ]; then cp "$DTBIN" "$FW/board.dtb"; echo "  copied $DTBIN"
elif ! ls "$FW"/*.dtb >/dev/null 2>&1; then
    echo "  ★ DTB 미확보 — dtbo.img/별도 파티션에서 확보 필요 (매직 0xd00dfeed)"
fi

echo "== super =="
if [ -n "$SUPER" ]; then
    case "$SUPER" in
      *.lz4) lz4 -d -f "$SUPER" "$FW/super.img"; SUPER="$FW/super.img";;
      *)     cp "$SUPER" "$FW/super.img"; SUPER="$FW/super.img";;
    esac
    # sparse 면 simg2img 필요 (표준 툴 또는 worked example 의 simg2img.py)
    if [ "$(dd if="$FW/super.img" bs=4 count=1 2>/dev/null | xxd -p)" = "3aff26ed" ]; then
        if command -v simg2img >/dev/null 2>&1; then
            simg2img "$FW/super.img" "$FW/super_raw.img" && mv "$FW/super_raw.img" "$FW/super.img" && echo "  simg2img"
        else
            echo "  ★ super 가 sparse 인데 simg2img 없음 — 표준 simg2img 설치 또는 worked example"
            echo "     (10_exynos2400_rehost/scripts/simg2img.py) 포팅 후 raw 변환 필요"
        fi
    fi
    echo "  super -> $FW/super.img (system/vendor 카브는 liblp/lp_tool.py, EROFS 매직 0xe0f5e1e2)"
fi

echo "== 결과 =="; ls -la "$FW"
echo "다음: static-analyzer 가 DTB 로 머신 골격 + 커널 게이트 도출"
