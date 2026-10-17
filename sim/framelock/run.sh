#!/bin/sh
# Frame-lock sim at the native Genesis rate (iverilog). From this directory: ./run.sh [standard|hz120]
# With no argument both variants run.
#   tb_frame_lock   the real framebuffer_sync.sv against the VDP-side model with the
#                   real 3420x262 timing: locked HDMI period, steady halt per frame,
#                   re-lock after a menu pause and a core reset, no stale reads, audio
#                   holds while paused; then interlace mode 1, double-res mode 2
#                   (one halt per field, current-field reads only) and 256/320 +
#                   224/240 mode switches.
#                   Standard: the 1652-clock native HDMI line. HZ120 (-DHZ120): the
#                   858-clock 480p120 line, the full-frame-buffer release protocol,
#                   and (progressive runs) both Integer (+SL_OUT=0) and Full (+SL_OUT=1).
set -e
cd "$(dirname "$0")"
RTL=../../src
HDMI=../scanlines/hdmi_stub.v
SIZES="320x224 256x224 320x240 256x240"
VARIANTS=${1:-both}
run_variant() {
    variant=$1
    if [ "$variant" = hz120 ]; then
        DEF=-DHZ120
    else
        DEF=
    fi
    VINC="-I $RTL/variant/$variant"
    echo "--- framelock variant: $variant"
    iverilog -g2012 $DEF $VINC -o tb_frame_lock_$variant.out tb_frame_lock.v $HDMI $RTL/framebuffer_sync.sv $RTL/scanlines.v $RTL/video_fx.v
    BENCH=./tb_frame_lock_$variant.out
    if [ "$variant" = hz120 ]; then
        for s in $SIZES; do
            $BENCH +W=${s%x*} +H=${s#*x} +SL_OUT=0
        done
        # Full scale moves the picture but not the pause point: one height is enough
        $BENCH +W=320 +H=224 +SL_OUT=1
        $BENCH +W=320 +H=240 +SL_OUT=1
    else
        for s in $SIZES; do
            $BENCH +W=${s%x*} +H=${s#*x}
        done
    fi
    $BENCH +W=320 +H=224 +ILACE=1
    $BENCH +W=320 +H=224 +DRES=1
    $BENCH +W=256 +H=224 +DRES=1
    $BENCH +W=320 +H=224 +WSWITCH=1
    $BENCH +W=320 +H=224 +HSWITCH=1
}
case $VARIANTS in
    standard) run_variant standard ;;
    hz120) run_variant hz120 ;;
    both) run_variant standard; run_variant hz120 ;;
    *) echo "usage: $0 [standard|hz120]" >&2; exit 1 ;;
esac
