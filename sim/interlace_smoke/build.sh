#!/bin/sh
# Build one Genesis smoke model at a given ref.
# Usage: build.sh <TAG> <SRCDIR>
# Env: SMOKE_BUILD (model root, default ./build), JOBS (default 8).
# Run inside the verilator docker image. Source list from
# verilator/Makefile (upstream), sim_main.cpp replaced by tb_smoke_md.cpp.
set -e
SDIR=$(cd "$(dirname "$0")" && pwd)
TAG=$1; SRC=$(cd "$2" && pwd)
BLD=${SMOKE_BUILD:-$SDIR/build}
JOBS=${JOBS:-$(nproc)}
THREADS=${VERILATOR_THREADS:-1}
case $THREADS in ''|*[!0-9]*|0) echo "VERILATOR_THREADS must be positive" >&2; exit 2;; esac
B=$BLD/md/$TAG
R=$SRC
mkdir -p "$B/obj"
cp -f "$SDIR/tb_smoke_md.cpp" "$B/obj/"
D=$R/src
SRCS="$D/mdtang_top.sv \
 $D/fx68k/verilator/fx68k.sv $D/fx68k/verilator/fx68kAlu.sv $D/fx68k/verilator/uaddrPla.sv \
 $D/vdp/vdp.v $D/vdp/vdp_common.v $D/common/dpram_block.v $D/common/dpram.v \
 $D/common/dpram32_block.v \
 $D/system.sv $D/memory/sdram_sim.v $D/peripherals/multitap.sv $D/peripherals/gen_io.sv \
 $D/peripherals/fourway.v $D/peripherals/lightgun.sv $D/peripherals/teamplayer.sv $D/peripherals/EEPROM_24CXX.sv \
 $D/jt89/jt89_mixer.v $D/jt89/jt89_noise.v $D/jt89/jt89_tone.v $D/jt89/jt89_vol.v $D/jt89/jt89.v \
 $D/jt12/jt12.v $D/jt12/jt12_top.v $D/jt12/jt12_acc.v $D/jt12/jt12_single_acc.v $D/jt12/jt12_eg.v $D/jt12/jt12_eg_cnt.v $D/jt12/jt12_eg_comb.v $D/jt12/jt12_eg_step.v $D/jt12/jt12_eg_pure.v $D/jt12/jt12_eg_final.v $D/jt12/jt12_eg_ctrl.v $D/jt12/jt12_exprom.v $D/jt12/jt12_kon.v \
 $D/jt12/jt12_lfo.v $D/jt12/jt12_div.v $D/jt12/jt12_mod.v $D/jt12/jt12_op.v $D/jt12/jt12_csr.v \
 $D/jt12/jt12_pg.v $D/jt12/jt12_pg_inc.v $D/jt12/jt12_pg_dt.v $D/jt12/jt12_pg_sum.v $D/jt12/jt12_pg_comb.v \
 $D/jt12/jt12_pm.v $D/jt12/jt12_logsin.v $D/jt12/jt12_reg.v $D/jt12/jt12_sh.v $D/jt12/jt12_sh_rst.v \
 $D/jt12/jt12_sh24.v $D/jt12/jt12_sumch.v $D/jt12/jt12_timers.v $D/jt12/jt12_pcm_interpol.v \
 $D/jt12/jt12_mmr.v $D/jt12/jt12_dout.v $D/jt12/jt12_rst.v $D/jt12/adpcm/jt10_adpcm_div.v \
 $D/jt12/mixer/jt12_genmix.v $D/jt12/mixer/jt12_decim.v $D/jt12/mixer/jt12_interpol.v \
 $D/jt12/mixer/jt12_comb.v $D/jt12/mixer/jt12_fm_uprate.v \
 $D/peripherals/genesis_lpf.v $D/peripherals/audio_iir_filter.v \
 $D/t80/t80_alu.v $D/t80/t80.v $D/t80/t80_mcode.v $D/t80/t80_reg.v $D/t80/t80s.v $D/framebuffer_sync.sv $D/scanlines.v $D/video_fx.v $SDIR/../scanlines/hdmi_stub.v"
verilator --threads "$THREADS" --top-module mdtang_top +1800-2023ext+sv \
 -Wno-PINMISSING -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-CASEINCOMPLETE -Wno-CASEX \
 -DMD_VIDEO_SIM -I$D/variant/${VARIANT:-standard} -Wno-fatal -cc --exe -o Vmdtang_smoke -CFLAGS "-O3 -DTANGCORE_SIM_THREADS=$THREADS" -I$D -I$D/fx68k -I$D/vdp $SRCS "$B/obj/tb_smoke_md.cpp" \
 --Mdir "$B/obj/obj" >"$B/obj/last-step.log" 2>&1; rc=$?; tail -5 "$B/obj/last-step.log"; test $rc -eq 0
make CXX="ccache g++" -j"$JOBS" -C "$B/obj/obj" -f Vmdtang_top.mk Vmdtang_smoke >"$B/obj/last-step.log" 2>&1; rc=$?; tail -5 "$B/obj/last-step.log"; test $rc -eq 0
test -x "$B/obj/obj/Vmdtang_smoke"
echo BUILD_OK
