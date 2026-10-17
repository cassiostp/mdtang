#!/bin/sh
# VDP field lengths and the halt lock (issue #47). From this directory: ./run.sh
#   tb_vdp_lock the real src/vdp/vdp.v (register-programmed) plus the real
#               src/framebuffer_sync.sv, with the mdtang_top.sv pause gate
#               (pause passes unless interlaced): lines per field, halts per
#               field and game rate for +PAL +ILACE +DRES +V30 +NOGATE.
#               USE_BASE=1 builds the bench against the BASE ref RTL (no
#               INTERLACE_ANY: the old top behaviour) for before/after.
# Verilator (iverilog rejects the '{default:} register reset in vdp.v).
set -e
cd "$(dirname "$0")"
ROOT=$(cd ../.. && pwd)
RTL=../../src
BASE=${BASE:-origin/int/round6}
VLT="docker run --rm --name r6smsmd_vdplock --user $(id -u):$(id -g) -v $PWD:/w -v $ROOT:/r -w /w verilator/verilator:latest"
VSRC=/r/src
VSCN=/r/sim/scanlines
mkdir -p build
if [ "$USE_BASE" = 1 ]; then
    mkdir -p build/base
    git -C "$ROOT" show "$BASE:src/vdp/vdp.v" > build/base/vdp.v
    git -C "$ROOT" show "$BASE:src/vdp/vdp_common.v" > build/base/vdp_common.v
    VDP=/w/build/base/vdp.v
    DEFS="+define+BASE_VDP"
else
    VDP=$VSRC/vdp/vdp.v
    DEFS=""
fi
# shellcheck disable=SC2086
$VLT --binary --timing -j 4 --top-module tb_vdp_lock -Mdir build/obj \
    -Wno-PINMISSING -Wno-IMPLICIT -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-CASEINCOMPLETE -Wno-UNDRIVEN -Wno-COMBDLY -Wno-ALWCOMBORDER \
    $DEFS \
    /w/tb_vdp_lock.v $VDP \
    $VSRC/common/dpram.v $VSRC/common/dpram_block.v $VSRC/common/dpram32_block.v \
    $VSCN/hdmi_stub.v $VSRC/framebuffer_sync.sv $VSRC/scanlines.v $VSRC/video_fx.v \
    -I$VSRC/vdp -I$VSRC/common \
    > build/verilate.log 2>&1 || { tail -40 build/verilate.log; exit 1; }
run() {
    docker run --rm --name r6smsmd_vdplock_run --user "$(id -u):$(id -g)" -v "$PWD:/w" -w /w --entrypoint ./build/obj/Vtb_vdp_lock verilator/verilator:latest \
        +PAL="$1" +ILACE="$2" +DRES="$3" +V30="$4" +NOGATE="$5"
}
if [ "$USE_BASE" = 1 ]; then
    run 0 0 0 0 1
    run 0 1 0 0 1
else
    run 0 0 0 0 0
    run 0 1 0 0 0
    run 0 0 1 0 0
    run 0 0 0 1 0
    run 0 1 0 0 1
    run 1 0 0 0 0
    run 1 1 0 0 0
    run 1 0 1 0 0
    run 1 0 0 1 0
fi
