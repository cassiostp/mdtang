#!/bin/sh
# Frame-lock sim at the native Genesis rate (iverilog). From this directory: ./run.sh
#   tb_frame_lock   real framebuffer_sync.sv (1652-clock native HDMI line) against the
#                   VDP-side model with the real 3420x262 timing: locked HDMI period,
#                   steady halt per frame, re-lock after a menu pause and a core
#                   reset, no stale line-buffer reads, audio holds while paused.
set -e
cd "$(dirname "$0")"
RTL=../../src
HDMI=../scanlines/hdmi_stub.v
SIZES="320x224 256x224 320x240 256x240"
iverilog -g2012 -o tb_frame_lock.out tb_frame_lock.v $HDMI $RTL/framebuffer_sync.sv $RTL/scanlines.v $RTL/video_fx.v $RTL/smooth.v
for s in $SIZES; do
    vvp tb_frame_lock.out +W=${s%x*} +H=${s#*x}
done
