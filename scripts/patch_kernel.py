#!/usr/bin/env python3
"""
patch_kernel.py — 트랙 2 §5.1 커널 보안게이트 우회 패처 (일반).
static-analyzer 가 도출한 사이트 테이블로 <Image> -> <Image.patched> 생성.
멱등 + pre-image 검증 (틀린 오프셋은 fail-loud, silent 패치 금지).

사용법:
  patch_kernel.py <Image> <Image.patched> <sites.json>

sites.json:  [ {"off":"0x...", "expected":"0x........", "new":"0x........", "why":"..."} , ... ]
  off/expected/new 은 hex 문자열. new 은 4B little-endian 워드 (NOP=0xd503201f).
  각 사이트는 대상 Image 에서 심볼/문자열 xref 로 도출 — 다른 커널 오프셋 박제 금지.
"""
import sys, json, struct, shutil

NOP = 0xd503201f  # 참고 상수

def main():
    if len(sys.argv) != 4:
        print(__doc__); sys.exit(1)
    src, dst, sites_path = sys.argv[1], sys.argv[2], sys.argv[3]
    sites = json.load(open(sites_path))

    shutil.copyfile(src, dst)
    buf = bytearray(open(dst, "rb").read())
    for s in sites:
        off = int(s["off"], 0); exp = int(s["expected"], 0); new = int(s["new"], 0)
        cur = struct.unpack_from("<I", buf, off)[0]
        if cur == new:
            print("  [skip] 0x%x already 0x%08x" % (off, new)); continue
        if cur != exp:
            print("  [FAIL] 0x%x expected 0x%08x got 0x%08x -- ABORT (오프셋 재도출)"
                  % (off, exp, cur))
            sys.exit(1)
        struct.pack_into("<I", buf, off, new)
        print("  [ok]   0x%x: 0x%08x -> 0x%08x  (%s)" % (off, exp, new, s.get("why", "")))
    open(dst, "wb").write(buf)
    print("wrote", dst, len(buf), "bytes,", len(sites), "sites")

if __name__ == "__main__":
    main()
