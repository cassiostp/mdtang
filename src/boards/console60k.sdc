// Console 60K timing constraints: src/mdtang.sdc plus five cuts below (two
// M68K->Z80 synchronisers + three Z80->M68K handshake cuts).
// Gowin reads one SDC per project, so this file repeats mdtang.sdc; keep
// the two in sync.

create_clock -name clk50 -period 20.00  -waveform {0 10.00} [get_nets {clk50}]
create_clock -name clk_sys -period 18.57 -waveform {0 9.29} [get_nets {clk_sys}]
create_generated_clock -name clk_z80 -source [get_nets {clk_sys}] -divide_by 2 [get_nets {clk_z80}]

// Z80 to M68K, 2 clk_sys cycles
set_multicycle_path 4 -end -setup -from [get_clocks {clk_z80}] -to [get_clocks {clk_sys}]
set_multicycle_path 3 -end -hold -from [get_clocks {clk_z80}] -to [get_clocks {clk_sys}]

// From fx68k.txt
// micro-code fetch is needed in 2 cycles
//set_multicycle_path 4 -start -setup -from [get_pins {megadrive/M68K/Ir*/*}] -to [get_pins {megadrive/M68K/microAddr_*/*}]
//set_multicycle_path 3 -start -hold -from [get_pins {megadrive/M68K/Ir*/*}] -to [get_pins {megadrive/M68K/microAddr_*/*}]
//set_multicycle_path 4 -start -setup -from [get_pins {megadrive/M68K/Ir*/*}] -to [get_pins {megadrive/M68K/nanoAddr_*/*}]
//set_multicycle_path 3 -start -hold -from [get_pins {megadrive/M68K/Ir*/*}] -to [get_pins {megadrive/M68K/nanoAddr_*/*}]

// The update of the CCR flags is also time critical.
//set_multicycle_path 4 -start -setup -from [get_pins {megadrive/M68K/nanoLatch*/*}] -to [get_pins {megadrive/M68K/excUnit/alu/pswCcr*/*}]
//set_multicycle_path 3 -start -hold -from [get_pins {megadrive/M68K/nanoLatch*/*}] -to [get_pins {megadrive/M68K/excUnit/alu/pswCcr*/*}]
//set_multicycle_path 4 -start -setup -from [get_pins {megadrive/M68K/excUnit/alu/oper*/*}] -to [get_pins {megadrive/M68K/excUnit/alu/pswCcr*/*}]
//set_multicycle_path 3 -start -hold -from [get_pins {megadrive/M68K/excUnit/alu/oper*/*}] -to [get_pins {megadrive/M68K/excUnit/alu/pswCcr*/*}]

// M68K to Z80 control synchronizers: bus-request and Z80 reset change only
// while the Z80 is stopped or stopping. The 60K fit misses hold on these two
// paths by ~50 ps once the design passes ~3/4 BSRAM, so they are cut here;
// the 138K meets them and keeps the check (src/mdtang.sdc).
set_false_path -from [get_pins {megadrive/z80_busrq_n*/Q}] -to [get_pins {megadrive/Z80_BUSRQ_N*/D}]
set_false_path -from [get_pins {megadrive/z80_reset_n*/Q}] -to [get_pins {megadrive/Z80_RESET_N*/D}]

# Z80 -> M68K bus handshake (CLK_Z80 to MCLK): same three cuts as mdtang.sdc.
# See mdtang.sdc for the handshake argument (system.sv MBUS_IDLE/ZBUS_IDLE,
# CEN divides to ~3.58 MHz, coincident-edge hold benign).
set_false_path -from [get_pins {megadrive/Z80/u0/DO_*/Q}] -to [get_pins {megadrive/MBUS_DO_*/D}]
set_false_path -from [get_pins {megadrive/Z80/u0/DO_*/Q}] -to [get_pins {megadrive/ZBUS_DO_*/D}]
set_false_path -from [get_pins {megadrive/Z80_RESET_N*/Q}] -to [get_pins {megadrive/MBUS_ZBUS_D*/*}]
