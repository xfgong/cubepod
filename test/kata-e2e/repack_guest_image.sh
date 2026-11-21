#!/usr/bin/env bash
set -Eeuo pipefail

VMM=${1:?Usage: repack_guest_image.sh <fc|clh>}
OVERRIDE_BIN=/tmp/kata-agent-override
[[ -x "$OVERRIDE_BIN" ]] || { echo "Missing executable override binary at $OVERRIDE_BIN" >&2; exit 1; }

IMG=$(python3 - "$VMM" <<'PY'
import os, sys, tomllib
from pathlib import Path
vmm = sys.argv[1]
cfg = tomllib.loads(Path(f"/opt/kata/share/defaults/kata-containers/configuration-{vmm}.toml").read_text())
hv = next(iter(cfg["hypervisor"].values()))
print(os.path.realpath(hv["image"]))
PY
)
[[ -f "$IMG" && "$IMG" == /opt/kata/* ]] || { echo "Unexpected guest image path: $IMG" >&2; exit 1; }

read -r START SIZE < <(parted -s -m "$IMG" unit B print | awk -F: '$1 == "1" { gsub("B", "", $2); gsub("B", "", $4); print $2, $4 }')
[[ -n "${START:-}" && -n "${SIZE:-}" ]] || { echo "Failed to locate partition 1 in $IMG" >&2; exit 1; }
(( START > 0 && START % 512 == 0 && SIZE > 0 )) || { echo "Invalid partition geometry start=$START size=$SIZE" >&2; exit 1; }

WORK=$(mktemp -d /tmp/repack-kata-img.XXXXXX)
trap 'rm -rf "$WORK"' EXIT

dd if="$IMG" of="$WORK/orig_p1.erofs" bs=4M iflag=skip_bytes,count_bytes skip="$START" count="$SIZE" status=none
mkdir -p "$WORK/rootfs"
fsck.erofs --preserve --extract="$WORK/rootfs" "$WORK/orig_p1.erofs" >/dev/null
chmod 0755 "$WORK/rootfs"

TARGET_AGENT="$WORK/rootfs/usr/bin/kata-agent"
[[ -f "$TARGET_AGENT" ]] || { echo "Expected $TARGET_AGENT in extracted guest rootfs" >&2; exit 1; }

OLD_SHA=$(sha256sum "$TARGET_AGENT" | awk '{print $1}')
NEW_SHA=$(sha256sum "$OVERRIDE_BIN" | awk '{print $1}')
OLD_BYTES=$(stat -c %s "$TARGET_AGENT")
NEW_BYTES=$(stat -c %s "$OVERRIDE_BIN")
[[ "$OLD_SHA" != "$NEW_SHA" ]] || { echo "Override kata-agent matches existing binary ($OLD_SHA)" >&2; exit 1; }

install -o 0 -g 0 -m 0755 "$OVERRIDE_BIN" "$TARGET_AGENT"
mkfs.erofs -zlz4hc -Enoinline_data "$WORK/new_p1.erofs" "$WORK/rootfs" >/dev/null

NEW_P1_SIZE=$(stat -c %s "$WORK/new_p1.erofs")
TOTAL_BYTES=$(( ((START + NEW_P1_SIZE + 2 * 1048576 - 1) / 1048576) * 1048576 ))
NEW_IMG="$IMG.repacked"
rm -f "$NEW_IMG"
truncate -s "$TOTAL_BYTES" "$NEW_IMG"
dd if="$IMG" of="$NEW_IMG" bs=1M iflag=count_bytes count="$START" conv=notrunc status=none

START_SECTORS=$(( START / 512 ))
SIZE_SECTORS=$(( (NEW_P1_SIZE + 511) / 512 ))
sfdisk --quiet "$NEW_IMG" <<EOF
label: dos
unit: sectors
start=${START_SECTORS}, size=${SIZE_SECTORS}, type=83
EOF

dd if="$WORK/new_p1.erofs" of="$NEW_IMG" bs=1M oflag=seek_bytes seek="$START" conv=notrunc,fsync status=none
cmp -s -n "$NEW_P1_SIZE" -i "0:$START" "$WORK/new_p1.erofs" "$NEW_IMG"
mv "$NEW_IMG" "$IMG"

python3 - "$IMG" "$OLD_SHA" "$NEW_SHA" "$OLD_BYTES" "$NEW_BYTES" "$START" "$NEW_P1_SIZE" <<'PY'
import json, struct, sys
img, old_sha, new_sha, old_b, new_b, start, p1_size = sys.argv[1:]
with open(img, "rb") as f:
    f.seek(int(start) + 1024)
    magic, = struct.unpack("<I", f.read(4))
assert magic == 0xE0F5E1E2, f"Unexpected EROFS superblock magic: {hex(magic)}"
print(json.dumps({
    "image": img,
    "old_kata_agent_sha256": old_sha,
    "new_kata_agent_sha256": new_sha,
    "old_kata_agent_bytes": int(old_b),
    "new_kata_agent_bytes": int(new_b),
    "partition1_start_bytes": int(start),
    "partition1_erofs_bytes": int(p1_size),
    "erofs_magic_verified": hex(magic),
}, indent=2))
PY
