#!/bin/sh
# Whole machine simulation (tb_telestrat) with nvc.
# Usage: sim/system/run.sh <cartridge> <mode 00|01|10> <trace file> [max fetches] [time limit ms]
# The Verilog parts (psg, keyboard) are replaced by sim/system/stubs.vhd.
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
CART=$(cd "$(dirname "$1")" && pwd)/$(basename "$1")
MODE=${2:-00}
TRACE=$3
case "$TRACE" in /*) ;; *) TRACE=$(pwd)/$TRACE ;; esac
MAX=${4:-2000000}
TIME_MS=${5:-2000}
WORK=${TMPDIR:-/tmp}/orix_nvc_system_$MODE
rm -rf "$WORK" && mkdir -p "$WORK/rtl"
# rtl/65C816/MCode.vhd line 456 has a 3 bit literal in a 4 bit field, which
# Quartus accepts and nvc rejects (task orix-fpga-dqd); pad it in the copy only.
sed -E '456s/\("011","000",/("011","0000",/' "$ROOT/rtl/65C816/MCode.vhd" > "$WORK/rtl/MCode.vhd"
R="$ROOT/rtl"
cd "$WORK"
nvc --std=2008 --work=work:"$WORK/work" -H 2g -a --relaxed \
    "$R/T65/T65_Pack.vhd" "$R/T65/T65_ALU.vhd" "$R/T65/T65_MCode.vhd" "$R/T65/T65.vhd" \
    "$R/65C816/P65816_pkg.vhd" "$R/65C816/AddrGen.vhd" "$R/65C816/BCDAdder.vhd" "$R/65C816/AddSubBCD.vhd" \
    "$R/65C816/ALU.vhd" "$WORK/rtl/MCode.vhd" "$R/65C816/P65C816.vhd" \
    "$R/VHDL-6551-ACIA/ACIA_BRGEN.vhd" "$R/VHDL-6551-ACIA/ACIA_RX.vhd" "$R/VHDL-6551-ACIA/ACIA_TX.vhd" "$R/VHDL-6551-ACIA/ACIA.vhd" \
    "$R/HCS3120.vhd" "$R/HCS3119.vhd" "$R/HCS10017.vhd" "$R/via6522.vhd" "$R/ds1501.vhd" "$R/Twilighte.vhd" \
    "$R/ch376.vhd" "$R/ch376_fw_rom.vhd" "$R/ch376_host.vhd" "$R/ch376_core.vhd" \
    "$HERE/stubs.vhd" "$R/telestrat.vhd" "$HERE/tb_telestrat.vhd"
nvc --std=2008 --work=work:"$WORK/work" -H 2g -e tb_telestrat \
    -gCART="$CART" -gCART_SIZE=$(wc -c < "$CART" | tr -d ' ') -gTRACE="$TRACE" \
    -gMODE="$MODE" -gMAX_FETCHES="$MAX" -gSIM_TIME_MS="$TIME_MS" -r
