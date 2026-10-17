#!/bin/sh
# Frame-lock sim at the native Genesis rate (iverilog). From this directory: ./run.sh
#   tb_frame_lock   real framebuffer_sync.sv (858-clock 480p120 HDMI line) against the
#                   VDP-side model with the real 3420x262 timing: locked HDMI period,
#                   steady halt per frame, re-lock after a menu pause and a core
#                   reset, no stale line-buffer reads, audio holds while paused;
#                   then interlace mode 1, double-res mode 2 (one halt per field,
#                   current-field reads only) and 256/320 + 224/240 mode switches.
set -e
cd "$(dirname "$0")"
RTL=../../src
HDMI=../scanlines/hdmi_stub.v
SIZES="320x224 256x224 320x240 256x240"
iverilog -g2012 -o tb_frame_lock.out tb_frame_lock.v $HDMI $RTL/framebuffer_sync.sv $RTL/scanlines.v $RTL/video_fx.v $RTL/smooth.v
for s in $SIZES; do
    vvp tb_frame_lock.out +W=${s%x*} +H=${s#*x}
done
vvp tb_frame_lock.out +W=320 +H=224 +ILACE=1
vvp tb_frame_lock.out +W=320 +H=224 +DRES=1
vvp tb_frame_lock.out +W=256 +H=224 +DRES=1
vvp tb_frame_lock.out +W=320 +H=224 +WSWITCH=1
vvp tb_frame_lock.out +W=320 +H=224 +HSWITCH=1
