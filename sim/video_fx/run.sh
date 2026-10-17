#!/bin/sh
# video_fx sims (iverilog). From this directory:  ./run.sh [standard|hz120]
# With no argument both variants run. The 720p history regress benches
# (tb_md_regress, tb_md_fx, tb_md_smooth_regress, model.py check) compare the
# scaler against the 720p git-history baselines, so they run for the standard
# variant only; the hz120 variant runs the filter block itself (tb_video_fx),
# whose behaviour is the same in both variants. Geometry and sync at 480p are
# sim/scanlines and sim/framelock.
#   tb_iosys_video_config  iosys command 0x13
#   tb_video_fx     video_fx against the golden model (model.py)
#   tb_md_regress   the scaler against the scaler before video_fx: identical with no filter on,
#                   for the four frame sizes (256 / 320 x 224 / 240)
#   tb_md_fx        the filters inside the scaler, for the four frame sizes, checked against the model
#   tb_md_smooth_regress  the scaler against the scaler before smoothing: identical with the
#                   removed smoothing bits (video_config[19:18]) clear or set
# prep.sh (python3, git) makes the vectors and the baselines; with a simulator image that has
# neither, run prep.sh on the host first and `python3 -I model.py check md_fx.log` after.
set -e
cd "$(dirname "$0")"
RTL=../../src
HDMI=../scanlines/hdmi_stub.v
SIZES="256x224 320x224 256x240 320x240"
VARIANTS=${1:-both}
# The scaler sources carry `include "variant.vh" (standard here; the hz120
# variant never runs these 720p benches).
VINC="-I $RTL/variant/standard"
run_variant() {
    variant=$1
    echo "--- video_fx variant: $variant"
    if [ "$variant" = standard ]; then
        if command -v python3 >/dev/null 2>&1 && command -v git >/dev/null 2>&1; then
            sh prep.sh
        fi
        test -f vec_case.hex -a -f build/framebuffer_sync_base.sv -a -f build/framebuffer_sync_fx.sv
    else
        # 480p120 does not rebuild the 720p git baselines (prep.sh). tb_video_fx
        # still needs the model vectors; generate them here when python3 is available.
        if command -v python3 >/dev/null 2>&1; then
            python3 -I model.py gen
        fi
        test -f vec_case.hex -a -f vec_in.hex -a -f vec_exp.hex
        mkdir -p build
    fi

    # iosys command 0x13 (a sim copy with the "input reg" port Gowin tolerates softened, like sim/saveram)
    sed -e 's/input reg  \[7:0\] kbd_data/input [7:0] kbd_data/' \
        -e 's/^\( *\)kbd_data <= rx_data;/\1;                       \/\/ sim: kbd path idle/' \
        $RTL/iosys/iosys_bl616.v > build/iosys_sim.v
    iverilog -g2012 -DSIM $VINC -o tb_iosys_video_config.out tb_iosys_video_config.v build/iosys_sim.v $RTL/iosys/uart_fixed.v
    vvp tb_iosys_video_config.out

    iverilog -g2012 $VINC -o tb_video_fx.out tb_video_fx.v $RTL/video_fx.v $RTL/scanlines.v
    vvp tb_video_fx.out

    if [ "$variant" = hz120 ]; then
        # The 720p git-history regress and the model.py geometry checks compare a
        # 1280x720 picture. The 480p picture geometry is tb_md_scaler (sim/scanlines)
        # and the read-during-write sync is sim/framelock.
        echo "480p: skipping 720p regress/model geometry (tb_md_regress, tb_md_fx, tb_md_smooth_regress)"
        return 0
    fi

    # a testbench for each frame size, in parallel
    sizes() {
        tb=$1
        pids=
        for s in $SIZES; do
            vvp $tb.out +W=${s%x*} +H=${s#*x} > out_${tb}_$s.txt 2>&1 &
            pids="$pids $!"
        done
        rc=0
        for p in $pids; do wait $p || rc=1; done
        for s in $SIZES; do cat out_${tb}_$s.txt; done
        return $rc
    }

    iverilog -g2012 $VINC -o tb_md_regress.out tb_md_regress.v $HDMI $RTL/framebuffer_sync.sv $RTL/scanlines.v \
        $RTL/video_fx.v build/framebuffer_sync_base.sv build/scanlines_base.v
    sizes tb_md_regress

    iverilog -g2012 $VINC -o tb_md_fx.out tb_md_fx.v $HDMI $RTL/framebuffer_sync.sv $RTL/scanlines.v $RTL/video_fx.v
    sizes tb_md_fx
    cat $(for s in $SIZES; do echo md_fx_$s.log; done) > md_fx.log
    if command -v python3 >/dev/null 2>&1; then
        python3 -I model.py check md_fx.log
    else
        echo "NOTE: python3 not found, run: python3 -I model.py check md_fx.log"
    fi

    iverilog -g2012 $VINC -o tb_md_smooth_regress.out tb_md_smooth_regress.v $HDMI $RTL/framebuffer_sync.sv $RTL/scanlines.v \
        $RTL/video_fx.v build/framebuffer_sync_fx.sv
    sizes tb_md_smooth_regress
}
case $VARIANTS in
    standard) run_variant standard ;;
    hz120) run_variant hz120 ;;
    both) run_variant standard; run_variant hz120 ;;
    *) echo "usage: $0 [standard|hz120]" >&2; exit 1 ;;
esac
