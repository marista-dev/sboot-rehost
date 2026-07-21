#!/usr/bin/env python3
"""
verify_byte_match.py — 검증 #2 (출력 byte-match) + #3 (소스 negative) 단독 실행용.
scripts/verify.py 가 같은 판정을 내장하고 있으며, 이 스크립트는 개별 확인용이다.

사용법:
  verify_byte_match.py <bl3.bin> <console.txt> <machine.c>

출력: JSON
  {
    "tokens": N,
    "missing_in_bl3": [...],   # 출력에는 있는데 BL3 에 없는 토큰 (실패면 #2 FAIL)
    "leak_in_src": [...],      # 출력 토큰이 머신 C 소스에 누출됨 (실패면 #3 FAIL)
    "byte_match_pass": bool,
    "source_neg_pass": bool
  }
"""
import sys
import re
import json


def check(bl3_path, console_path, source_path):
    bl3 = open(bl3_path, "rb").read()
    out = open(console_path, "rb").read()
    src = open(source_path, "r", errors="replace").read()

    # 3 글자 이상 alnum 토큰 추출
    tokens = set(re.findall(rb"[\w\-]{3,}", out))

    # 너무 짧거나 흔한 영어 단어는 흔히 변수명과 충돌하므로 5 글자 이상만 소스 누출 검사
    long_tokens = {t for t in tokens if len(t) >= 5}

    missing_in_bl3 = sorted(
        [t.decode("latin-1") for t in tokens if bl3.find(t) < 0]
    )
    leak_in_src = sorted(
        [t.decode("latin-1") for t in long_tokens
         if t.decode("latin-1") in src]
    )

    return {
        "tokens": len(tokens),
        "long_tokens_checked": len(long_tokens),
        "missing_in_bl3": missing_in_bl3,
        "leak_in_src": leak_in_src,
        "byte_match_pass": len(missing_in_bl3) == 0,
        "source_neg_pass": len(leak_in_src) == 0,
    }


def main():
    if len(sys.argv) < 4:
        print(__doc__)
        sys.exit(1)
    result = check(sys.argv[1], sys.argv[2], sys.argv[3])
    print(json.dumps(result, indent=2, ensure_ascii=False))


if __name__ == "__main__":
    main()
