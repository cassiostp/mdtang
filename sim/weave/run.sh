#!/bin/sh
set -eu
cd "$(dirname "$0")"
variant=${1:-standard}
mkdir -p build/$variant
if [ "$variant" = hz120 ]; then def=-DHZ120; else def=; fi
verilator --binary --timing -j "${JOBS:-20}" -Wno-fatal $def --top-module tb_weave -I../../src/variant/$variant \
 --Mdir build/$variant tb_weave.v ../scanlines/hdmi_stub.v ../../src/framebuffer_sync.sv ../../src/scanlines.v ../../src/video_fx.v \
 > build/$variant/compile.log 2>&1 || { tail -n 40 build/$variant/compile.log; exit 1; }
./build/$variant/Vtb_weave
verilator --binary --timing -j "${JOBS:-20}" -Wno-fatal $def --top-module tb_hdmi_rate -I../../src/variant/$variant \
 --Mdir build/rate-$variant tb_hdmi_rate.v ../../src/hdmi/hdmi.sv ../../src/hdmi/tmds_channel.sv ../../src/hdmi/serializer.sv \
 > build/rate-$variant.log 2>&1 || { tail -n 40 build/rate-$variant.log; exit 1; }
./build/rate-$variant/Vtb_hdmi_rate
