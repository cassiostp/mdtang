#!/bin/sh
# Battery-save sims (iverilog). From this directory:
#   ./run.sh              compile and run all three testbenches
# On this machine iverilog lives in docker:
#   docker run --rm -v <repo>:/w -w /w/sim/saveram tangcore-iv:1 ./run.sh
# Gowin tolerates the "input reg" port declaration in iosys; iverilog does not,
# so run.sh compiles a sim-only copy with that softened (and the kbd write
# stubbed, which needs an input port).
set -e
RTL=../../src
# textdisp.v carries `include "variant.vh"; these are standard-variant sims.
VINC="-I $RTL/variant/standard"
sed -e 's/input reg  \[7:0\] kbd_data/input [7:0] kbd_data/' \
    -e 's/^\( *\)kbd_data <= rx_data;/\1;                       \/\/ sim: kbd path idle/' \
    $RTL/iosys/iosys_bl616.v > iosys_sim.v
# sdram.v initializes its port arrays with `wire [..] x [0:3] = '{..}`, which
# iverilog rejects (it is not legal SV either; Gowin accepts it). The sim copy
# spreads the same nets over per-element assigns.
sed -e "s/^wire \[2:0\]  req \[0:3\].*$/wire [2:0] req [0:3]; assign req[0]=req0; assign req[1]=req1; assign req[2]=req2; assign req[3]=req3;/" \
    -e "s/^wire \[24:1\] addr \[0:3\].*$/wire [24:1] addr [0:3]; assign addr[0]=addr0; assign addr[1]=addr1; assign addr[2]=addr2; assign addr[3]=addr3;/" \
    -e "s/^wire \[15:0\] din \[0:3\].*$/wire [15:0] din [0:3]; assign din[0]=din0; assign din[1]=din1; assign din[2]=din2; assign din[3]=din3;/" \
    -e "s/^wire .*wr \[0:3\].*$/wire wr [0:3]; assign wr[0]=wr0; assign wr[1]=wr1; assign wr[2]=wr2; assign wr[3]=wr3;/" \
    -e "s/^wire \[1:0\]  be \[0:3\].*$/wire [1:0] be [0:3]; assign be[0]=be0; assign be[1]=be1; assign be[2]=be2; assign be[3]=be3;/" \
    $RTL/memory/sdram.v > sdram_sim_ctrl.v
iverilog -g2012 -DSIM $VINC -o tb_saveram_sdram.out \
    tb_saveram_sdram.v iosys_sim.v $RTL/iosys/uart_fixed.v $RTL/iosys/textdisp.v gowin_dpb_menu_sim.v
vvp tb_saveram_sdram.out
iverilog -g2012 -DSIM -o tb_sdram_save.out \
    tb_sdram_save.v sdram_sim_ctrl.v
vvp tb_sdram_save.out
# System test: real iosys + real sdram.v port 3 + MD-bus-like port-0 traffic +
# an MCU model. The sim copy shortens iosys's 20 ms joypad rate limit so pad
# changes are due within ~0.2 ms of sim time.
sed -e 's|localparam JOY_UPDATE_INTERVAL = 50_000_000 / 50;|localparam JOY_UPDATE_INTERVAL = 10_000;|' \
    iosys_sim.v > iosys_sys_sim.v
grep -q "JOY_UPDATE_INTERVAL = 10_000" iosys_sys_sim.v
iverilog -g2012 -DSIM $VINC -o tb_system_save.out \
    tb_system_save.v iosys_sys_sim.v sdram_sim_ctrl.v $RTL/iosys/uart_fixed.v $RTL/iosys/textdisp.v gowin_dpb_menu_sim.v
vvp tb_system_save.out
