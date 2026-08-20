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


def resolve(workdir, manifest):
    """Return (partitions, derived_names). Missing sources are skipped, loudly."""
    parts, missing = [], []
    if manifest:
        for p in manifest.get("partitions") or []:
            src = os.path.join(workdir, p.get("source", ""))
            if os.path.isfile(src):
                parts.append({"name": p["name"], "path": src,
                              "source": p.get("source")})
            else:
                missing.append(f'{p.get("name")} <- {p.get("source")}')
        return parts, True, missing

    for name, candidates in DEFAULT_LAYOUT:
        for rel in candidates:
            src = os.path.join(workdir, rel)
            if os.path.isfile(src):
                parts.append({"name": name, "path": src, "source": rel})
                break
    return parts, False, missing


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

    parts, derived, missing = resolve(wd, manifest)
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

        backup_array_lba = total_lbas - 1 - array_lbas
        fh.seek(backup_array_lba * block)
        fh.write(entries)
        fh.seek((total_lbas - 1) * block)
        fh.write(header(block, total_lbas - 1, 1, first_usable, last_usable,
                        backup_array_lba, ecrc))

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
    }
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
