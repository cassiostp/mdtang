# >4 MB / SSF2 / EEPROM full-system sim (Verilator, headless, via docker).
#
#   make run       generate ROMs, verilate mdtang_top, run the checks
#   make clean     drop build/
#
# Same source list as verilator/Makefile (keep in sync), with tb_main.cpp in
# place of the SDL sim_main.cpp and --public-flat-rw so the harness can read
# the SDRAM model and the save-channel wires. Build output stays in build/
# (git-ignored); docker is used only at build/run time.
BIGROM := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
D := $(BIGROM)/../../src
DOCKER := docker run --rm --name mdbig_bigrom --user "$(shell id -u):$(shell id -g)" -e CCACHE_DISABLE=1
VMNT := -v "$(BIGROM)/../..:/coresim-src:ro" -v "$(BIGROM)/build:/build" -w /build

SRCS := $D/mdtang_top.sv \
	$D/fx68k/verilator/fx68k.sv $D/fx68k/verilator/fx68kAlu.sv $D/fx68k/verilator/uaddrPla.sv \
	$D/vdp/vdp.v $D/vdp/vdp_common.v $D/common/dpram_block.v $D/common/dpram.v \
	$D/common/dpram32_block.v \
	$D/system.sv $D/memory/sdram_sim.v $D/peripherals/multitap.sv $D/peripherals/gen_io.sv \
	$D/peripherals/fourway.v $D/peripherals/lightgun.sv $D/peripherals/teamplayer.sv $D/peripherals/EEPROM_24CXX.sv \
	$D/jt89/jt89_mixer.v $D/jt89/jt89_noise.v $D/jt89/jt89_tone.v $D/jt89/jt89_vol.v $D/jt89/jt89.v \
	$D/jt12/jt12.v $D/jt12/jt12_top.v $D/jt12/jt12_acc.v $D/jt12/jt12_single_acc.v $D/jt12/jt12_eg.v \
	$D/jt12/jt12_eg_cnt.v $D/jt12/jt12_eg_comb.v $D/jt12/jt12_eg_step.v $D/jt12/jt12_eg_pure.v \
	$D/jt12/jt12_eg_final.v $D/jt12/jt12_eg_ctrl.v $D/jt12/jt12_exprom.v $D/jt12/jt12_kon.v \
	$D/jt12/jt12_lfo.v $D/jt12/jt12_div.v $D/jt12/jt12_mod.v $D/jt12/jt12_op.v $D/jt12/jt12_csr.v \
	$D/jt12/jt12_pg.v $D/jt12/jt12_pg_inc.v $D/jt12/jt12_pg_dt.v $D/jt12/jt12_pg_sum.v $D/jt12/jt12_pg_comb.v \
	$D/jt12/jt12_pm.v $D/jt12/jt12_logsin.v $D/jt12/jt12_reg.v $D/jt12/jt12_sh.v $D/jt12/jt12_sh_rst.v \
	$D/jt12/jt12_sh24.v $D/jt12/jt12_sumch.v $D/jt12/jt12_timers.v $D/jt12/jt12_pcm_interpol.v \
	$D/jt12/jt12_mmr.v $D/jt12/jt12_dout.v $D/jt12/jt12_rst.v $D/jt12/adpcm/jt10_adpcm_div.v \
	$D/jt12/mixer/jt12_genmix.v $D/jt12/mixer/jt12_decim.v $D/jt12/mixer/jt12_interpol.v \
	$D/jt12/mixer/jt12_comb.v $D/jt12/mixer/jt12_fm_uprate.v \
	$D/peripherals/genesis_lpf.v $D/peripherals/audio_iir_filter.v \
	$D/t80/t80_alu.v $D/t80/t80.v $D/t80/t80_mcode.v $D/t80/t80_reg.v $D/t80/t80s.v
# The container sees the repo at /coresim-src, so build the same list there.
CSRCS := $(subst $(D),/coresim-src/src,$(SRCS))

.PHONY: run roms clean
run: build/tb_bigrom roms
	cp $(D)/fx68k/microrom.mem $(D)/fx68k/nanorom.mem build/	# fx68k $readmemb, CWD-relative
	cd build && ./tb_bigrom .

roms: build/expected.h
build/expected.h: make_roms.py
	mkdir -p build
	python3 make_roms.py build

# -Wno-*: pre-existing style warnings in the core's own RTL (as in
# verilator/Makefile); the waiver for the simulation-only flat public
# access lives here, not in the sources.
build/tb_bigrom: tb_main.cpp build/expected.h
	mkdir -p build
	cp tb_main.cpp build/
	$(DOCKER) $(VMNT) verilator/verilator:latest --top-module mdtang_top +1800-2023ext+sv --cc --exe --public-flat-rw \
	    -Wno-PINMISSING -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-CASEINCOMPLETE -Wno-IMPLICIT \
	    -Wno-CASEX -Wno-MULTIDRIVEN -Wno-UNOPTFLAT \
	    -I/coresim-src/src -I/coresim-src/src/fx68k -I/coresim-src/src/vdp -I/build \
	    -Mdir obj -o tb_bigrom $(CSRCS) tb_main.cpp
	$(DOCKER) $(VMNT) --entrypoint make verilator/verilator:latest -C obj -f Vmdtang_top.mk -j20
	cp build/obj/tb_bigrom build/tb_bigrom

clean:
	rm -rf build
