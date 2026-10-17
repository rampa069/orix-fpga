#!/bin/sh
# WD1793 with the MFM_DISK backend (rtl/wd1793.sv), Verilator.
# Usage: sim/fdc/run.sh <image.dsk> [more images...]
# Each image is read through the FDC and compared with the file; a sector
# write is checked on a copy, the original image is never modified.
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
WORK=${TMPDIR:-/tmp}/orix_fdc_sim
mkdir -p "$WORK"
verilator --cc --exe --build -j 0 -O2 -Wno-fatal -Wno-WIDTH -Wno-PROCASSINIT \
	--top-module wd1793 --Mdir "$WORK/obj" \
	"$ROOT/rtl/wd1793.sv" "$HERE/tb_wd1793.cpp" > "$WORK/build.log"
status=0
for img in "$@"; do
	"$WORK/obj/Vwd1793" "$img" "$WORK/$(basename "$img").out" || status=1
done
exit $status
