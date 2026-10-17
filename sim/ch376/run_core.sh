#!/bin/sh
# Runs tb_ch376_core (T65 + firmware + FatFs on a FAT test image) with nvc,
# then lists the image written back by the simulation with mtools.
# Usage: sim/ch376/run_core.sh [12|16|32] [size in MB]   (default FAT12, 2 MB)
# Rebuild the firmware first: make -C firmware/ch376
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
WORK=${TMPDIR:-/tmp}/orix_nvc_ch376_core
rm -rf "$WORK" && mkdir -p "$WORK"
FAT=${1:-12}
SIZE_MB=${2:-2}
"$HERE/mkimage.sh" "$WORK/fat.img" "$FAT" "$SIZE_MB" > /dev/null
cd "$WORK"
nvc --std=2008 --work=work:"$WORK/work" -H 1g \
    -a "$ROOT/rtl/T65/T65_Pack.vhd" "$ROOT/rtl/T65/T65_ALU.vhd" "$ROOT/rtl/T65/T65_MCode.vhd" "$ROOT/rtl/T65/T65.vhd" \
       "$ROOT/rtl/ch376_fw_rom.vhd" "$ROOT/rtl/ch376_host.vhd" "$ROOT/rtl/ch376_core.vhd" \
       "$HERE/tb_ch376_core.vhd" \
    -e tb_ch376_core -gIMAGE_IN="$WORK/fat.img" -gIMAGE_OUT="$WORK/fat_out.img" -gIMAGE_SIZE=$((SIZE_MB * 1048576)) \
    -r 2>&1 | tee "$WORK/sim.log"
grep -q "ALL TESTS PASSED" "$WORK/sim.log"
echo "--- image after the simulation"
FREE=$(mdir -i "$WORK/fat_out.img" :: | awk '/bytes free/ {gsub(/[^0-9]/, "", $0); print $0}')
SIM_FREE=$(sed -n 's/.*free sectors: \([0-9]*\).*/\1/p' "$WORK/sim.log")
if [ "$SIM_FREE" = "$((FREE / 512))" ]; then
	echo "free sectors: DISK_QUERY $SIM_FREE, mtools $((FREE / 512)): match"
else
	echo "free sectors: DISK_QUERY $SIM_FREE, mtools $((FREE / 512)): MISMATCH"
	exit 1
fi
mdir -i "$WORK/fat_out.img" ::
mdir -i "$WORK/fat_out.img" ::ORIX
mtype -i "$WORK/fat_out.img" ::NEW.BIN | python3 -c "import sys; d=sys.stdin.buffer.read(); print('NEW.BIN', len(d), 'bytes,', 'content ok' if d == bytes((i*3+7)%256 for i in range(700)) else 'content WRONG')"
