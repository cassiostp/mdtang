#!/bin/sh
# video_fx sims (iverilog). From this directory:  ./run.sh
#   tb_iosys_video_config  iosys command 0x13
#   tb_video_fx     video_fx against the golden model (model.py)
#   tb_md_regress   the scaler against the scaler before video_fx: identical with no filter on,
#                   for the four frame sizes (256 / 320 x 224 / 240)
#   tb_md_fx        the filters inside the scaler, for the four frame sizes, checked against the model
#   tb_md_smooth_regress  the scaler against the scaler before smoothing: identical with smoothing off
#   tb_md_smooth    the smoothing inside the scaler, for the four frame sizes, checked against the model
#   tb_md_smooth_sync  the smoothing against the VDP's timing: every line buffer read finds its pixel
# prep.sh (python3, git) makes the vectors and the baselines; with a simulator image that has
# neither, run prep.sh on the host first and `python3 -I model.py check md_fx.log` and
# `python3 -I model.py check_smooth md_smooth_256x224.log md_src_256x224.hex ...` after.
set -e
cd "$(dirname "$0")"
RTL=../../src
HDMI=../scanlines/hdmi_stub.v
SIZES="256x224 320x224 256x240 320x240"
# 480p120 does not rebuild the 720p git baselines (prep.sh). tb_video_fx still
# needs the model vectors; generate them here when python3 is available.
if command -v python3 >/dev/null 2>&1; then
    python3 -I model.py gen
fi
test -f vec_case.hex -a -f vec_in.hex -a -f vec_exp.hex
mkdir -p build

# iosys command 0x13 (a sim copy with the "input reg" port Gowin tolerates softened, like sim/saveram)
sed -e 's/input reg  \[7:0\] kbd_data/input [7:0] kbd_data/' \
    -e 's/^\( *\)kbd_data <= rx_data;/\1;                       \/\/ sim: kbd path idle/' \
    $RTL/iosys/iosys_bl616.v > build/iosys_sim.v
iverilog -g2012 -DSIM -o tb_iosys_video_config.out tb_iosys_video_config.v build/iosys_sim.v $RTL/iosys/uart_fixed.v
vvp tb_iosys_video_config.out

iverilog -g2012 -o tb_video_fx.out tb_video_fx.v $RTL/video_fx.v $RTL/scanlines.v
vvp tb_video_fx.out

# a testbench for each frame size, in parallel; $2 are more plusargs
sizes() {
    tb=$1
    pids=
    for s in $SIZES; do
        vvp $tb.out +W=${s%x*} +H=${s#*x} $2 > out_${tb}_$s.txt 2>&1 &
        pids="$pids $!"
    done
    rc=0
    for p in $pids; do wait $p || rc=1; done
    for s in $SIZES; do cat out_${tb}_$s.txt; done
    return $rc
}

# The 720p git-history regress and the model.py geometry checks compare a
# 1280x720 picture. This build is 480p120; picture geometry is tb_md_scaler
# and the frame lock is sim/framelock. What remains here is the filter block
# itself (above) and the scaler's read-during-write sync at 480p.
echo "480p: skipping 720p regress/model geometry (tb_md_regress, tb_md_fx, tb_md_smooth)"

iverilog -g2012 -o tb_md_smooth_sync.out tb_md_smooth_sync.v $HDMI $RTL/framebuffer_sync.sv $RTL/scanlines.v $RTL/video_fx.v $RTL/smooth.v
# one size at a time: the machine is shared
for s in $SIZES; do
    vvp tb_md_smooth_sync.out +W=${s%x*} +H=${s#*x} +LATE=0
done
for s in $SIZES; do
    vvp tb_md_smooth_sync.out +W=${s%x*} +H=${s#*x} +LATE=19
done
