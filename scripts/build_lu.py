#!/usr/bin/env python3
"""build_lu.py - synthesise the boot medium the bootloader reads from.

The unified flow does not hand the kernel to QEMU. The bootloader loads it the
way it does on the device: it brings the storage controller up, reads a
partition table, finds a partition BY NAME, and pulls the image out of it. That
only works if the medium we model actually has those partitions, under the names
the firmware looks up.

So this writes a real GPT disk - protective MBR, primary and backup headers, a
128-entry array with correct CRC32s - and fills each partition from a file.

★ Partition NAMES are derived, not invented. A name we made up is a partition
  the firmware will never find, and the failure surfaces much later as a
  verification error or a silent fall-through to download mode. Names come from
  <workdir>/lu_manifest.json, which static-analyzer writes from the bootloader's
  own strings. Without a manifest this falls back to documented defaults and
  SAYS SO in the result, the same way the input harness reports a default gate
  pattern rather than pretending it derived one.

Usage:
  build_lu.py <workdir> [--out <img>] [--block-size 4096|512] [--manifest <json>]

Manifest:
  {
    "block_size": 4096,
    "partitions": [
      {"name": "boot",       "source": "fw/boot.img"},
      {"name": "vbmeta",     "source": "fw/vbmeta.img"},
      {"name": "keystorage", "source": "02_unpacked/keystorage.bin"}
    ]
  }

Prints one JSON object describing what was written.
"""
import argparse
import binascii
import hashlib
import json
import os
import struct
import sys

ENTRY_SIZE = 128
ENTRY_COUNT = 128
# "Basic data" - what Android partitions use. The bootloader looks partitions up
# by NAME, not by type GUID, so one generic type is correct here rather than a
# per-partition guess that would be fiction.
TYPE_GUID = b"\xa2\xa0\xd0\xeb\xe5\xb9\x33\x44\x87\xc0\x68\xb6\xb7\x26\x99\xc7"

# Used only when no manifest exists. Reported as defaults, never as derived.
DEFAULT_LAYOUT = [
    ("boot", ["fw/boot.img", "02_unpacked/boot.img"]),
    ("recovery", ["fw/recovery.img"]),
    ("dtbo", ["fw/dtbo.img"]),
    ("vbmeta", ["fw/vbmeta.img", "02_unpacked/vbmeta.img"]),
    ("keystorage", ["02_unpacked/keystorage.bin"]),
    ("param", ["02_unpacked/param.bin"]),
    ("up_param", ["02_unpacked/up_param.bin"]),
    ("system", ["fw/system.img"]),
    ("vendor", ["fw/vendor.img"]),
    ("super", ["fw/super.img"]),
]


def guid_for(name):
    """Deterministic GUID, so two builds of the same medium are byte-identical.

    A random GUID would make every rebuild a different disk, and 'the image
    changed' would become a permanent false lead when a round misbehaves.
    """
    return hashlib.sha256(("sboot-rehost:" + name).encode()).digest()[:16]


def crc32(data):
    return binascii.crc32(data) & 0xFFFFFFFF


def align_up(value, block):
    return (value + block - 1) // block * block


def build_entries(parts, block):
    """Lay partitions out back to back and return (entry_array, total_lbas)."""
    entries = bytearray(ENTRY_SIZE * ENTRY_COUNT)
    array_lbas = align_up(ENTRY_SIZE * ENTRY_COUNT, block) // block
    first_usable = 2 + array_lbas
    lba = first_usable
    placed = []
    for i, p in enumerate(parts):
        size = os.path.getsize(p["path"])
        n = max(1, align_up(size, block) // block)
        start, end = lba, lba + n - 1
        off = i * ENTRY_SIZE
        entries[off:off + 16] = TYPE_GUID
        entries[off + 16:off + 32] = guid_for(p["name"])
        struct.pack_into("<QQQ", entries, off + 32, start, end, 0)
        nm = p["name"].encode("utf-16-le")[:70]
        entries[off + 56:off + 56 + len(nm)] = nm
        placed.append({**p, "start_lba": start, "end_lba": end,
                       "size": size, "lbas": n})
        lba = end + 1
    return bytes(entries), placed, first_usable, lba


def header(block, current, backup, first_usable, last_usable, entry_lba, entries_crc):
    h = bytearray(92)
    h[0:8] = b"EFI PART"
    struct.pack_into("<III", h, 8, 0x00010000, 92, 0)      # revision, size, crc=0
    struct.pack_into("<I", h, 20, 0)                        # reserved
    struct.pack_into("<QQQQ", h, 24, current, backup, first_usable, last_usable)
    h[56:72] = guid_for("disk")
    struct.pack_into("<QIII", h, 72, entry_lba, ENTRY_COUNT, ENTRY_SIZE, entries_crc)
    struct.pack_into("<I", h, 16, crc32(bytes(h)))          # header CRC last
    return bytes(h)


def protective_mbr(block, total_lbas):
    mbr = bytearray(512)
    mbr[446] = 0x00
    mbr[450] = 0xEE                                          # GPT protective
    struct.pack_into("<I", mbr, 454, 1)
    struct.pack_into("<I", mbr, 458, min(total_lbas - 1, 0xFFFFFFFF))
    mbr[510:512] = b"\x55\xaa"
    return bytes(mbr)


def load_manifest(workdir, explicit):
    path = explicit or os.path.join(workdir, "lu_manifest.json")
    if not os.path.exists(path):
        return None, path
    try:
        with open(path, encoding="utf-8") as fh:
            return json.load(fh), path
    except (OSError, json.JSONDecodeError) as exc:
        print(f"build_lu: 매니페스트를 읽지 못했습니다 ({exc})", file=sys.stderr)
        return None, path


# Android sparse images (AP tar ships system/vendor/super this way) are a
# container format, not the filesystem. Copying one byte-for-byte onto the medium
# produces a disk the bootloader cannot parse, and the damage only surfaces much
# later as an AVB failure - so refuse to build rather than write it silently.
SPARSE_MAGIC = b"\x3a\xff\x26\xed"


def is_sparse(path):
    try:
        with open(path, "rb") as fh:
            return fh.read(4) == SPARSE_MAGIC
    except OSError:
        return False


def load_cmdline_plan(workdir):
    """The UART command line derived by static-analyzer, if it found one.

    A bootloader that selects `console=ram` sends kernel output to a RAM buffer,
    so a kernel that boots perfectly prints nothing on the serial console. Writing
    the UART variant into PARAM uses the bootloader's own path
    (setup_param_info -> sbl_set_bootargs); it is a boot option, not a patch.
    """
    path = os.path.join(workdir, "cmdline_plan.json")
    if not os.path.isfile(path):
        return None, None
    try:
        with open(path, encoding="utf-8") as fh:
            plan = json.load(fh)
    except (OSError, ValueError):
        return None, None
    return plan.get("uart"), path


def resolve(workdir, manifest):
    """Return (partitions, derived, missing, sparse).

    Missing sources are skipped loudly; sparse ones stop the build outright."""
    parts, missing, sparse = [], [], []
    if manifest:
        for p in manifest.get("partitions") or []:
            src = os.path.join(workdir, p.get("source", ""))
            if os.path.isfile(src):
                if is_sparse(src):
                    sparse.append(f'{p.get("name")} <- {p.get("source")}')
                    continue
                parts.append({"name": p["name"], "path": src,
                              "source": p.get("source")})
            else:
                missing.append(f'{p.get("name")} <- {p.get("source")}')
        return parts, True, missing, sparse

    for name, candidates in DEFAULT_LAYOUT:
        for rel in candidates:
            src = os.path.join(workdir, rel)
            if os.path.isfile(src):
                if is_sparse(src):
                    sparse.append(f"{name} <- {rel}")
                    break
                parts.append({"name": name, "path": src, "source": rel})
                break
    return parts, False, missing, sparse


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("workdir")
    ap.add_argument("--out", default=None)
    ap.add_argument("--block-size", type=int, default=None, choices=(512, 4096))
    ap.add_argument("--manifest", default=None)
    args = ap.parse_args()

    wd = args.workdir
    manifest, manifest_path = load_manifest(wd, args.manifest)
    block = args.block_size or (manifest or {}).get("block_size") or 4096
    out = args.out or os.path.join(wd, "fw", "lu0.img")

    parts, derived, missing, sparse = resolve(wd, manifest)
    if sparse:
        print(json.dumps({
            "ok": False,
            "reason": "sparse 이미지를 raw 로 풀지 않았습니다",
            "sparse": sparse,
            "hint": ("simg2img <in> <out> 으로 먼저 푸십시오. sparse 를 그대로 쓰면 "
                     "부트로더가 파티션을 파싱하지 못하고, 그 결함은 한참 뒤 AVB 실패로 "
                     "나타나 원인을 찾기 어렵습니다."),
        }, ensure_ascii=False, indent=2))
        return 1
    if not parts:
        print(json.dumps({
            "ok": False,
            "reason": "채울 파티션이 하나도 없습니다",
            "manifest": manifest_path,
            "hint": ("펌웨어 자산을 먼저 배치하거나, static-analyzer 가 도출한 파티션 이름으로 "
                     "lu_manifest.json 을 쓰십시오. 이름을 지어내면 펌웨어가 못 찾습니다."),
        }, ensure_ascii=False, indent=2))
        return 1

    entries, placed, first_usable, next_lba = build_entries(parts, block)
    array_lbas = align_up(ENTRY_SIZE * ENTRY_COUNT, block) // block
    last_usable = next_lba - 1
    total_lbas = next_lba + array_lbas + 1          # backup array + backup header

    cmdline, cmdline_src = load_cmdline_plan(wd)
    param_lba = next((p["start_lba"] for p in placed
                      if p["name"].lower() == "param"), None)
    if cmdline and param_lba is None:
        cmdline = None                       # no PARAM partition to write it into

    # The bootloader rewrites the GPT and treats the device as newly provisioned
    # when the medium's total size changes - measured on Exynos 2400, where
    # adding 30 MiB was enough to trigger a full re-init and a power-down. Pin
    # the size in the manifest so swapping a partition cannot change it.
    pinned = (manifest or {}).get("total_bytes")

    os.makedirs(os.path.dirname(os.path.abspath(out)), exist_ok=True)
    ecrc = crc32(entries)
    with open(out, "wb") as fh:
        fh.truncate(total_lbas * block)
        fh.seek(0)
        mbr = protective_mbr(block, total_lbas)
        fh.write(mbr + bytes(block - len(mbr)) if block > 512 else mbr)

        fh.seek(1 * block)
        fh.write(header(block, 1, total_lbas - 1, first_usable, last_usable,
                        2, ecrc))
        fh.seek(2 * block)
        fh.write(entries)

        for p in placed:
            fh.seek(p["start_lba"] * block)
            with open(p["path"], "rb") as src:
                while True:
                    chunk = src.read(1 << 20)
                    if not chunk:
                        break
                    fh.write(chunk)

        # The UART command line, appended to PARAM so the kernel prints where we
        # can see it. Written after the partition image so it does not disturb a
        # PARAM the firmware supplied; the bootloader scans this area for the
        # bootargs string.
        if cmdline and param_lba is not None:
            payload = cmdline.encode() + b"\x00"
            fh.seek(param_lba * block)
            fh.write(payload)

        backup_array_lba = total_lbas - 1 - array_lbas
        fh.seek(backup_array_lba * block)
        fh.write(entries)
        fh.seek((total_lbas - 1) * block)
        fh.write(header(block, total_lbas - 1, 1, first_usable, last_usable,
                        backup_array_lba, ecrc))

    actual = os.path.getsize(out)
    size_warning = None
    if pinned and actual != pinned:
        size_warning = (f"매체 총 크기가 고정값과 다릅니다: {actual:,} != {pinned:,} — "
                        "부트로더가 GPT 를 재작성하고 신규 프로비저닝으로 간주해 "
                        "전원을 내릴 수 있습니다 (파티션을 바꿔도 총량은 유지하십시오)")

    result = {
        "ok": True,
        "image": os.path.abspath(out),
        "block_size": block,
        "total_bytes": total_lbas * block,
        "names_derived": derived,
        "manifest": manifest_path if derived else None,
        "partitions": [{"name": p["name"], "source": p["source"],
                        "start_lba": p["start_lba"], "lbas": p["lbas"],
                        "bytes": p["size"]} for p in placed],
        "missing_sources": missing,
        "cmdline_written": bool(cmdline),
        "cmdline": cmdline,
        "cmdline_source": cmdline_src if cmdline else None,
    }
    if size_warning:
        result["warning_size"] = size_warning
    if cmdline is None and cmdline_src:
        result["warning_cmdline"] = (
            "cmdline_plan.json 은 있으나 PARAM 파티션이 없어 커맨드라인을 기록하지 "
            "못했습니다 — 부트로더가 console=ram 을 고르면 커널이 떠도 시리얼에 "
            "아무것도 안 나옵니다")
    if not derived:
        result["warning"] = (
            "파티션 이름을 도출하지 않고 **문서화된 기본값**을 썼습니다. 펌웨어가 다른 "
            "이름으로 찾으면 그 파티션은 없는 것과 같습니다 — static-analyzer 가 "
            "부트로더 문자열에서 이름을 도출해 lu_manifest.json 을 쓰게 하십시오.")
    if missing:
        result["warning_missing"] = (
            f"매니페스트가 지정한 원본 {len(missing)} 개가 없어 건너뛰었습니다: {missing}")

    print(json.dumps(result, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
