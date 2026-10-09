#!/bin/sh
# Scanline sims (iverilog). From this directory:  ./run.sh
#   tb_scanlines    the row generator and the darkening (src/scanlines.v)
#   tb_md_scaler    framebuffer_sync.sv whole frames, with a stub for the HDMI part
set -e
RTL=../../src
iverilog -g2012 -o tb_scanlines.out tb_scanlines.v $RTL/scanlines.v
vvp tb_scanlines.out
iverilog -g2012 -o tb_md_scaler.out tb_md_scaler.v hdmi_stub.v $RTL/framebuffer_sync.sv $RTL/scanlines.v
vvp tb_md_scaler.out
