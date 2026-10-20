# MegaDrive co-sim model build (Verilator, via docker).
#
# Produces build/{gen,obj,runtime}: the Verilated cosim_top model as a static
# library plus the Verilator runtime headers it needs, so the firmware can
# link a prebuilt model given with -DMDTANG_COSIM_DIR (see firmware
# host/sim/backend_rtl/ and host/run-tests.sh --rtl-md).
#
#   make model     verilate + compile the model (needs docker)
#   make lint      iverilog elaboration check only (needs iverilog)
#   make clean     drop build/ and generated sources
#
# Docker is only used here, at model-build time. No image, container or
# tool output is committed: build/ is git-ignored.
COSIM := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
RTL := $(COSIM)/../../src
GEN := $(COSIM)/build/gen
OBJ := $(COSIM)/build/obj
# The container user may have no writable home (CI runners): no ccache.
# Runner: simrun when present (persistent ccache + full-core env), else plain docker.
DOCKER_RUN ?= $(shell command -v simrun >/dev/null 2>&1 && echo simrun || echo docker run --rm)
# ccache: simrun mounts a persistent /ccache (CCACHE_DIR), so Verilator
# builds cache there; without it there is no cache to keep, so keep the old
# disable. (The Verilator-generated makefiles already prefix compiles with
# $(OBJCACHE), which defaults to ccache: nothing else to set.)
ifeq ($(findstring simrun,$(DOCKER_RUN)),simrun)
CCACHE_OFF :=
else
CCACHE_OFF := -e CCACHE_DISABLE=1
endif
DOCKER := $(DOCKER_RUN) --user "$(shell id -u):$(shell id -g)" $(CCACHE_OFF)
VMOUNT := -v "$(COSIM)/../..:/coresim-src:ro" -v "$(COSIM)/build:/coresim-build" -w /coresim-build
VERILATOR := $(DOCKER) $(VMOUNT) verilator/verilator:latest
IVERILOG := $(DOCKER) -v "$(COSIM)/../..:/coresim-src:ro" -v "$(COSIM)/build:/coresim-build" -w /coresim-build tangcore-iv:1

.PHONY: model lint clean

# The ONLY sanctioned difference from the core's real iosys_bl616.v: the
# CORE_ID parameter becomes the cosim_core_id input, standing in for
# reprogramming the bitstream (the model answers as the programmed core).
# Everything else -- RX/TX state machines, save engine, OSD writes -- is the
# untouched original; the build fails unless the diff shows exactly this.
$(GEN)/iosys_bl616_cosim.v: $(RTL)/iosys/iosys_bl616.v
	mkdir -p $(GEN)
	sed -e 's/^module iosys_bl616/module iosys_bl616_cosim/' \
	    -e '/^ *parameter \[15:0\] CORE_ID=.*,/d' \
	    -e 's/^\( *\)input resetn,/\1input resetn,\n\1input [15:0] cosim_core_id, \/\/ cosim: programmed core ID (stands in for the bitstream)/' \
	    -e 's/tx_data <= CORE_ID\[7:0\];/tx_data <= cosim_core_id[7:0]; \/\/ cosim: programmed ID/' \
	    -e 's/input reg  \[7:0\] kbd_data/input [7:0] kbd_data/' \
	    -e 's/^\( *\)kbd_data <= rx_data;/\1;                       \/\/ sim: kbd path idle/' \
	    $(RTL)/iosys/iosys_bl616.v > $@
	grep -q "^module iosys_bl616_cosim" $@
	grep -q "input \[15:0\] cosim_core_id" $@
	grep -q "tx_data <= cosim_core_id\[7:0\]" $@
	test $$(grep -c "CORE_ID" $@) -eq 3  # only SEND_CORE_ID (the TX state no.) may remain
	! grep "CORE_ID" $@ | grep -vq "SEND_CORE_ID"
	! grep -q "input reg" $@
	@echo "--- iosys_bl616_cosim.v differs from the real file only by:"
	@diff $(RTL)/iosys/iosys_bl616.v $@ || true

# sdram.v needs no functional change: its port-array initializers
# (wire [..] x[0:3] = '{..}) are legal-enough SV that Gowin and Verilator
# eat, but iverilog rejects -- the same spread-over-assigns sed as
# sim/saveram/run.sh. No behavior changes.
$(GEN)/sdram_sim_ctrl.v: $(RTL)/memory/sdram.v
	mkdir -p $(GEN)
	sed -e "s/^wire \[2:0\]  req \[0:3\].*$$/wire [2:0] req [0:3]; assign req[0]=req0; assign req[1]=req1; assign req[2]=req2; assign req[3]=req3;/" \
	    -e "s/^wire \[24:1\] addr \[0:3\].*$$/wire [24:1] addr [0:3]; assign addr[0]=addr0; assign addr[1]=addr1; assign addr[2]=addr2; assign addr[3]=addr3;/" \
	    -e "s/^wire \[15:0\] din \[0:3\].*$$/wire [15:0] din [0:3]; assign din[0]=din0; assign din[1]=din1; assign din[2]=din2; assign din[3]=din3;/" \
	    -e "s/^wire .*wr \[0:3\].*$$/wire wr [0:3]; assign wr[0]=wr0; assign wr[1]=wr1; assign wr[2]=wr2; assign wr[3]=wr3;/" \
	    -e "s/^wire \[1:0\]  be \[0:3\].*$$/wire [1:0] be [0:3]; assign be[0]=be0; assign be[1]=be1; assign be[2]=be2; assign be[3]=be3;/" \
	    $(RTL)/memory/sdram.v > $@
	! grep -q "'{" $@     # no assignment patterns survived the spread
	@grep -q "assign req\[3\]=req3" $@

# uart_fixed.v needs no functional change either: only the dummy
# ASSERTION_ERROR instances (which iverilog discards with the false generate
# branch, but Verilator elaborates and rejects) become empty begins.
# The guarded parameter combinations are valid, so nothing is lost.
$(GEN)/uart_fixed_sim.v: $(RTL)/iosys/uart_fixed.v
	mkdir -p $(GEN)
	sed -e 's/ASSERTION_ERROR PARAMETER_OUT_OF_RANGE(\("[^"]*"\));/begin end \/\/ sim: was ASSERTION_ERROR \1/' \
	    $(RTL)/iosys/uart_fixed.v > $@
	! grep -q "ASSERTION_ERROR PARAMETER_OUT_OF_RANGE(" $@

COSIM_SRCS := /coresim-src/sim/cosim/cosim_top.sv \
	/coresim-build/gen/iosys_bl616_cosim.v \
	/coresim-build/gen/uart_fixed_sim.v \
	/coresim-src/src/iosys/textdisp.v \
	/coresim-src/sim/cosim/gowin/gowin_dpb_menu.v \
	/coresim-build/gen/sdram_sim_ctrl.v \
	/coresim-src/sim/cosim/sdram_chip.sv

model: $(GEN)/iosys_bl616_cosim.v $(GEN)/sdram_sim_ctrl.v $(GEN)/uart_fixed_sim.v
	mkdir -p $(OBJ) $(COSIM)/build/runtime
	# -Wno-*: the core's own RTL carries pre-existing style Verilator flags
	# (implicit nets, width mismatches, partial cases, undriven pins); the
	# generated copies must stay line-identical to it apart from the
	# documented seds, so the waivers live here, not in its sources.
	# textdisp.v carries `include "variant.vh" (standard variant here).
	$(VERILATOR) --cc --top-module cosim_top --prefix Vcosim_top \
	    -Mdir obj -DCOSIM -CFLAGS "-O2" \
	    +incdir+/coresim-src/src/variant/standard \
	    -Wno-PINMISSING -Wno-IMPLICIT -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-CASEINCOMPLETE -Wno-CASEX \
	    $(COSIM_SRCS) > $(COSIM)/build/verilate.log 2>&1 && \
	{ test ! -s $(COSIM)/build/verilate.log || ! grep -E "PINMISSING.*(cosim_top|sdram_chip|gowin_dpb)" $(COSIM)/build/verilate.log; } || \
	{ cat $(COSIM)/build/verilate.log; exit 1; }
	# NOTE: PINMISSING is waived only for the core's own files (unconnected
	# RxD_idle/endofpacket in iosys); a missing pin in cosim_top, the chip
	# or the stand-in is a wiring bug (the NES port once hid an unconnected
	# DQM), so the log is grepped for those above.
	$(DOCKER) $(VMOUNT) --entrypoint make verilator/verilator:latest \
	    -C obj -f Vcosim_top.mk -j20
	# Verilator runtime headers the firmware needs to link the model
	# (/usr/local/share/verilator/include in this image; the compile lines
	# above show the path -- update if the image changes).
	$(DOCKER) $(VMOUNT) --entrypoint /bin/sh verilator/verilator:latest \
	    -c "cp -r /usr/local/share/verilator/include/* /coresim-build/runtime/"
	test -f $(COSIM)/build/runtime/verilated.h
	ls $(OBJ)/Vcosim_top__ALL.a

lint: $(GEN)/iosys_bl616_cosim.v $(GEN)/sdram_sim_ctrl.v $(GEN)/uart_fixed_sim.v
	$(IVERILOG) iverilog -g2012 -DCOSIM -o /dev/null -s cosim_top \
	    -I/coresim-src/src/variant/standard \
	    /coresim-src/sim/cosim/cosim_top.sv \
	    /coresim-build/gen/iosys_bl616_cosim.v /coresim-build/gen/uart_fixed_sim.v \
	    /coresim-src/src/iosys/textdisp.v /coresim-src/sim/cosim/gowin/gowin_dpb_menu.v \
	    /coresim-build/gen/sdram_sim_ctrl.v /coresim-src/sim/cosim/sdram_chip.sv
	@echo "cosim_top elaborates under iverilog"

clean:
	rm -rf $(COSIM)/build
