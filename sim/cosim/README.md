# MegaDrive co-simulation (`sim/cosim`)

A Verilator model of mdtang's real firmware-facing interface logic — the
`iosys_bl616` UART protocol engine (with OSD text) and the `sdram.v`
controller (with the battery-save client on its port 3) — for the TangCore
firmware co-simulation (see firmware `host/README.md`, "RTL backend"). No
game, no video, no audio: it exercises firmware↔core interactions (combos
and pad frames during play, battery-save dumps/restores, reset, MODE,
core_config bits) without hardware.

## Layout

- `cosim_top.sv` — the small top: real `iosys_bl616` (as
  `iosys_bl616_cosim`, generated, see below) + real `sdram.v` wired exactly
  as `mdtang_top` wires them, plus sim-only surroundings: behavioral SDRAM
  chip (`sdram_chip.sv`), MD-bus-like port-0 traffic with a game SRAM-write
  hook (`poke_*`, `churn_en`), the port-1 ROM loader path with a byte sink,
  MODE silencing, and a `tx_pending` output so the bridge never jumps over a
  reply owed by the model. Clocks and reset come from C++ — ONE clock:
  mdtang_top runs iosys and sdram.v on the same clk_sys, so there is no
  fclk/clkref split like the NES port. `clk` = 21.492 MHz sim ticks, `hclk`
  tied to `clk` (the render pipeline is unobserved; OSD text is snapshotted
  straight out of the DPB array).
- `sdram_chip.sv` — behavioral 16-bit SDRAM: the exact command subset
  `sdram.v` issues (ACT, single-word READ/WRITE with auto-precharge,
  DQM-masked writes, CL2 reads; refresh/mode-set/precharge ignored).
  Powers up all-`0xFF`, retains contents across reset (external chip).
- `gowin/` — behavioural stand-ins for Gowin primitives, shared by every
  testbench and cosim target in this core: currently only the DPB behind
  `gowin_dpb_menu` (OSD text buffer; zero-init, render side unmodelled).
- `Makefile` — `make model` (docker Verilator) builds
  `build/obj/Vcosim_top__ALL.a` + `build/runtime/` (Verilator headers) for
  the firmware to link with `-DMDTANG_COSIM_DIR`; `make lint` elaborates
  under iverilog (docker); `make clean`. `build/` is git-ignored.

## Generated sources (build-time, never committed)

`build/gen/` holds mechanical copies of real sources, each verified by the
build (grep checks + printed diff):

- `iosys_bl616_cosim.v` — from `src/iosys/iosys_bl616.v`, with exactly
  three changes: module renamed, the `CORE_ID` parameter deleted and added
  as the `cosim_core_id` input (programming the model answers as the
  programmed core; every reply byte stays DUT-generated), the `tx_data <=
  CORE_ID[7:0]` use pointed at it — plus the two `sim/saveram/run.sh`-style
  softeners (`input reg` kbd port, idle kbd path) that non-Gowin tools
  need.
- `sdram_sim_ctrl.v`, `uart_fixed_sim.v` — from the same-named sources:
  the port-array initializers spread over assigns (iverilog rejects
  `'{}`), and the dummy `ASSERTION_ERROR` instances replaced by empty
  begins. No functional change.
- The verilate line waives five style warnings (`-Wno-PINMISSING` etc.)
  that the core's own RTL carries; the log is then grepped for any waived
  warning naming `cosim_top`, `sdram_chip` or `gowin_dpb` — the waivers
  must never cover our files.

## Tests

- `../saveram/run.sh` (iverilog, docker): the battery-save unit testbenches
  plus `tb_system_save.v` — real iosys + real sdram.v with MD-like traffic
  and an MCU model dumping while polling core ID, sending HID and pressing
  pads. It proves the port-3 save channel and the SDRAM model used here.
- The firmware `m-*.script` suite (`bash host/run-tests.sh --rtl-md` over
  in the firmware worktree): menu combo and reset combo during a dump with
  the game writing SRAM, save round trip, core_config bits (including bit
  22, whose pad mute is checked inside `cosim_top.sv` against the pads the
  bridge drives), MODE — all through the real serial link at the real baud.

## MD-specific facts (the port's deltas from the NES template)

- Save window: cart SRAM at SDRAM words `{8'h41, 1'b0, X[15:1]}` = byte
  `0x820000` up, `SAVE_AW=16` (64 KB), `SAVE_SYNC=0` (sdram.v port 3,
  lowest priority). Big-endian lane: EVEN save byte = the word's UPPER
  half (`sv_q` mux and `be3` in `mdtang_top`) — the C++ `save_byte` mirrors
  that, the NES one is the opposite.
- Traffic: one shared game bus (port 0) with req/ack TOGGLES held until
  acked (sdram_nes needed multi-clk pulses instead), the ROM loader rides
  port 1 like `mdtang_top`, and the game is held off while `rom_loading !=
  0`.
- sdram.v gotchas from `tb_system_save`: its `resetn` must be the real
  reset (not `1'b1`), and its ack0..3 toggles have no reset — power-on 0,
  which Verilator's init provides.
- uart_fixed at `FREQ=21_492_000` produces exactly 10.746 clk bits, so the
  bridge's 2 Mbaud sampling is bit-exact at the sim tick; iosys's pad
  throttle localparam stays 1M clk (≈46 ms sim instead of ≈20 ms hardware
  — harmless, the firmware polls).
