#!/bin/sh
set -eu
cd "$(dirname "$0")"
variant=${1:-standard}
mkdir -p build/$variant
git show 58daecb:src/framebuffer_sync.sv | sed -e 's/^module framebuffer #(/module framebuffer_base #(/' \
 -e "s/hdmi( .std_timing(std_timing),/hdmi( .std_timing(std_timing), .interlace(1'b0),/" > build/base.sv
if [ "$variant" = hz120 ]; then def=-DHZ120; else def=; fi
verilator --binary --timing -j "${JOBS:-20}" -Wno-fatal $def --top-module tb_compat -I../../src/variant/$variant \
 --Mdir build/$variant tb_compat.v build/base.sv ../scanlines/hdmi_stub.v ../../src/framebuffer_sync.sv ../../src/scanlines.v ../../src/video_fx.v \
 > build/$variant/compile.log 2>&1 || { tail -n 40 build/$variant/compile.log; exit 1; }
./build/$variant/Vtb_compat
