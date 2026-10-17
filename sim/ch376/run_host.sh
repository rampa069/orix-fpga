#!/bin/sh
# Runs the ch376_host testbench with nvc (https://www.nickg.me.uk/nvc/).
# Usage: sim/ch376/run_host.sh   (from any directory)
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
WORK=${TMPDIR:-/tmp}/orix_nvc_ch376_host
rm -rf "$WORK" && mkdir -p "$WORK"
nvc --std=2008 --work=work:"$WORK/work" \
    -a "$ROOT/rtl/ch376_host.vhd" "$HERE/tb_ch376_host.vhd" \
    -e tb_ch376_host -r
