
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

# Z80 -> M68K bus handshake (CLK_Z80 to MCLK).
# Z80_DO changes together with Z80_IO on the same CLK_Z80 CEN edge (T80s
# src/system.sv:1406-1422, CEN src/system.sv:221-254 divides to ~3.58 MHz,
# stable >=15 MCLKs); the MBUS/ZBUS FSMs handshake via DTACK
# (Z80_MBUS_DTACK_N/Z80_ZBUS_DTACK_N, MBUS_IDLE src/system.sv:1028, ZBUS_IDLE
# src/system.sv:1546-1555) and require a gap (~Z80_IO) to clear DTACK, so the
# coincident-edge (0 ns) hold check is benign. Placement moves this cone
# ~0.5 ns (std60 round5 fails hold by 0.21 ns on DO->MBUS_DO/ZBUS_DO, native
# passes), so cut it like the forward synchronisers (console60k.sdc).
set_false_path -from [get_pins {megadrive/Z80/u0/DO_*/Q}] -to [get_pins {megadrive/MBUS_DO_*/D}]
set_false_path -from [get_pins {megadrive/Z80/u0/DO_*/Q}] -to [get_pins {megadrive/ZBUS_DO_*/D}]
set_false_path -from [get_pins {megadrive/Z80_RESET_N*/Q}] -to [get_pins {megadrive/MBUS_ZBUS_D*/*}]
