#!/bin/sh
# Builds the FAT test image used by tb_ch376_core.vhd (needs mtools).
# Usage: mkimage.sh <image file> [12|16|32] [size in MB]
#   default: FAT12, 2 MB (FAT16 needs at least 16 MB, FAT32 at least 64 MB)
#
# Contents:
#   TEST.BIN          600 bytes, byte n = n mod 256
#   README.TXT        short text
#   ORIX/             directory
#   ORIX/INSIDE.TXT   short text
set -e
IMG=${1:?image file}
FAT=${2:-12}
SIZE_MB=${3:-2}
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

python3 -c "import sys; sys.stdout.buffer.write(bytes(i % 256 for i in range(600)))" > "$TMP/TEST.BIN"
printf 'Hello from the CH376 test image.\r\n' > "$TMP/README.TXT"
printf 'File inside a directory.\r\n' > "$TMP/INSIDE.TXT"

rm -f "$IMG"
dd if=/dev/zero of="$IMG" bs=1048576 count=0 seek="$SIZE_MB" 2>/dev/null
case "$FAT" in
	12) mformat -i "$IMG" -v ORIXTEST :: ;;
	16) mformat -i "$IMG" -v ORIXTEST -T $((SIZE_MB * 2048)) :: ;;
	32) mformat -i "$IMG" -v ORIXTEST -F :: ;;
	*)  echo "FAT type must be 12, 16 or 32" >&2; exit 1 ;;
esac
mcopy -i "$IMG" "$TMP/TEST.BIN" ::TEST.BIN
mcopy -i "$IMG" "$TMP/README.TXT" ::README.TXT
mmd -i "$IMG" ::ORIX
mcopy -i "$IMG" "$TMP/INSIDE.TXT" ::ORIX/INSIDE.TXT
mdir -i "$IMG" ::
