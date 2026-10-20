#!/bin/sh
set -eu
cd "$(dirname "$0")"
ROOT=$(cd ../.. && pwd)
VARIANT=${1:-standard}
mkdir -p build/$VARIANT
if [ "$VARIANT" = hz120 ]; then DEF=-DHZ120; else DEF=; fi
verilator --binary --timing -j "${JOBS:-20}" --top-module tb_vdp_lock --compiler gcc -CFLAGS -O2 \
 -MAKEFLAGS 'CXX=ccache\ g++' -Mdir build/$VARIANT \
 -Wno-fatal $DEF -I../../src/variant/$VARIANT -I../../src/vdp -I../../src/common \
 tb_vdp_lock.v ../../src/vdp/vdp.v ../../src/common/dpram.v ../../src/common/dpram_block.v ../../src/common/dpram32_block.v \
 ../scanlines/hdmi_stub.v ../../src/framebuffer_sync.sv ../../src/scanlines.v ../../src/video_fx.v \
 > build/$VARIANT/compile.log 2>&1 || { tail -n 50 build/$VARIANT/compile.log; exit 1; }
./build/$VARIANT/Vtb_vdp_lock +ILACE=1
./build/$VARIANT/Vtb_vdp_lock +DRES=1
./build/$VARIANT/Vtb_vdp_lock
