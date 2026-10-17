#!/bin/sh
# Video output tests.
#   tb_video_window: geometry of the VGA and HDMI windows (iverilog)
#   tb_chain: syncs at the VGA and HDMI pins through mist_video (Verilator;
#             a copy of mist-modules with scandoubler_scaledepth.v made legal
#             for Verilator, where an unused branch has a zero width select)
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
WORK=${TMPDIR:-/tmp}/orix_video_sim
rm -rf "$WORK" && mkdir -p "$WORK"
cd "$WORK"
iverilog -g2012 -o vw.vvp "$HERE/tb_video_window.sv" "$ROOT/rtl/video_window.sv"
vvp -n vw.vvp
cp -R "$ROOT/mist-modules" mm
python3 - mm/scandoubler/scandoubler_scaledepth.v <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
s = s.replace("localparam o = OUT_DEPTH < IN_DEPTH ? OUT_DEPTH : IN_DEPTH; ",
              "localparam o = OUT_DEPTH < IN_DEPTH ? OUT_DEPTH : IN_DEPTH; \nlocalparam ns = n > 0 ? n : 1;")
s = s.replace("d[IN_DEPTH-1 -:n] };", "d[IN_DEPTH-1 -:ns] };")
open(p, "w").write(s)
PY
verilator --binary --timing -Wno-fatal -Wno-lint -Wno-style -Wno-WIDTH -Wno-MULTIDRIVEN --top-module tb \
    -Mdir obj -o chain -Imm "$HERE/tb_chain.sv" "$ROOT/rtl/video_window.sv" mm/mist_video.v mm/osd.v \
    mm/cofi.sv mm/video_cleaner.v mm/rgb2ypbpr.v mm/scandoubler/*.v 2>&1 | grep "%Error" || true
obj/chain | grep -v "^- "
