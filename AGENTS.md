Read the project-wide rules first: https://github.com/cassiostp/tangcore/blob/main/AGENTS.md

# mdtang — Genesis/Mega Drive core

Genesis/Mega Drive for the Tang Console 138K/60K. Mostly verbatim port of `MiSTer-devel/Genesis_MiSTer`; country is Americas/NTSC.

## Layout

- Top: `src/mdtang_top.sv` (`module mdtang_top`), machine `src/system.sv` (`module system`, M68K/Z80/PSG/FM).
- Video: synchronised upscaler `src/framebuffer_sync.sv` (double-buffered 320x240 BSRAM) into `src/hdmi/hdmi.sv`; helpers `src/scanlines.v`, `src/video_fx.v`, `src/smooth.v`. `src/iosys/framebuffer.sv` is a legacy fixed-`1650` version, unused by the build.
- Memory: `src/memory/sdram.v` (32 MB CL2 SDRAM) + `src/memory/rv_sdram_adapter.v`; `src/memory/sdram_sim.v` under Verilator.
- iosys: `src/iosys/iosys_bl616.v` is the build's copy (plus `textdisp.v`, `uart_fixed.v`, `gowin_dpb_menu.v`). `iosys_picorv32.v` exists but is not in `build.tcl`.
- PLLs: `src/pll/` (138K `PLL`: `pll/pll_27/pll_74/pll_12.v`), `src/plla/` (60K `PLLA`); board glue `src/boards/console.v` (console USB) vs `mega.cst`.
- Constraints: `src/mdtang.sdc` (all but console60k), `src/boards/console60k.sdc` (console60k only); one shared `console.cst`/`mega.cst`/`mega138kpro.cst`.

## Building

```tcl
gw_sh build.tcl <device>   # mega60k mega138k mega138kpro console60k console138k
```

No controller or memory option; `build.tcl` picks the CST/SDC/PLL family per device (`console60k` gets the extra SDC cuts, `mega*` omit USB). CI:

```sh
gh workflow run cores.yml -R cassiostp/tangcore --ref ci/core-builds -f core=mdtang -f ref=<branch> -f board=console138k
```

Fails on any setup/hold violation. `place_option 2` (slower but timing-optimised) is set in `build.tcl`.

## Clocks and constraints

- Both SDCs: `clk50` 50 MHz, `clk_sys` ~53.85 MHz (`pll.v`), `clk_z80 = clk_sys/2`, plus a 4/3 `z80 -> sys` multicycle. HDMI `hclk/hclk5` (54/270 MHz from `pll_74` via 27 MHz `pll_27`, VCO 1080 MHz) and USB `clk12` (`pll_12`) are generated in `mdtang_top.sv` but have no SDC entries.
- `console60k.sdc` repeats `mdtang.sdc` and adds two `set_false_path` cuts on the M68K->Z80 `z80_busrq_n`/`z80_reset_n` synchronisers (the 60K fit misses hold there by ~50 ps once the design passes ~3/4 BSRAM; 138K keeps the check). Gowin reads one SDC per project, so the two files must stay in sync.

## Native-rate lock

This branch is the 480p120 bitstream (VIC 48). Pixel clock is 54 MHz (`pll_74` MDIV 40, ODIV 20 and 4). The line is 858 pixels (`NATIVE_FRAME_WIDTH = 858`); `std_timing` 858 and native 858 are the same length, so `video_std_timing` tied `1'b0` in `src/mdtang_top.sv` does not change the rate. HDMI is 54e6/(858×525) = 119.8801 Hz. The game runs at half of that, 59.9401 Hz, which is 0.021% faster than the 60 Hz build (74.25 MHz / (1652×750) = 59.9274 Hz). 859 would be slower than that build.
The picture is integer 2× and centred in 720×480 (320→640, 256→512, 240 lines fill the height, 224 lines start at row 16). Each field is stored in one bank of the double buffer and shown for two HDMI refreshes. The core pauses when `y` reaches `height` and is released on the even HDMI frame; `mdtang_top.sv` gates `system.PAUSE_EN` (M68K/Z80 clocks, audio held) on `pause_core`.
`video_config[21:20]` is BFI inside this bitstream: 0 off (each field twice), 1 black, 2 dim (half brightness), 3 rolling which this core treats as black. The overlay is lit on every refresh. Modes 1–3 swap which refresh is dark every 1800 releases (~30 s). The 60 Hz bitstream ignores these bits. `[19:18]` is still smoothing.

## Firmware link

- Core ID 4 (`CORE_ID(4)` in `src/mdtang_top.sv`; firmware maps 4 to `mdtang.bin`).
- Save channel `SAVE_IF=1, SAVE_AW=16, SAVE_SYNC=0` (64 KB): cart SRAM lives in SDRAM at `0x820000-0x83FFFF` as `{8'h41,MBUS_A[16:1]}` words (raw MiSTer `.sav` layout, big-endian byte lanes on port 3); EEPROM mode is steered to BRAM instead.
- `core_config` bits used: `[3:0]` EEPROM type, `[4]` SRAM, `[5]` SRAM00, `[6]` NORAM, `[7]` FM-busy, `[8]` Sega Channel, `[17]` menu pause, `[16]` scanlines, `[19:18]` darkness, `[20]` thick, `[21]` out, `[22]` pads-muted; `video_config` drives `video_fx.v`/`smooth.v`.
- `iosys_bl616.v` is one of six divergent copies (`cassiostp/tangcore#30`): a fix to one usually belongs in the others.

## Simulations (`sim/cosim/README.md` and `sim/video_fx/README.md` say how to run; iverilog)

- `bigrom`: headless full-system >4 MB ROM/SSF2-banking/I2C-EEPROM on the real `mdtang_top` Verilator build.
- `cosim`: Verilator `iosys_bl616` UART engine + `sdram.v` port-3 client for firmware co-sim, no game/video/audio.
- `eeprom`: 68K bit-bang vs `EPPROM_24CXX` wired as `system.sv` (modes 0/1/2, `BRAM_CHANGE`).
- `framelock`: real `framebuffer_sync.sv` (858×525) vs the VDP model (3420 clocks/line, 262 lines); locked rate, per-field wait, re-lock within 2 frames.
- `saveram`: `tb_system_save` (real iosys+sdram port 3 as the top, MD bus on port 0) and `tb_sdram_save` (port-3 map, row-crossing) plus engine-level `tb_saveram_sdram`.
- `scanlines`: `scanlines.v` geometry/darkening plus whole-frame 480p scaler-vs-model, BFI modes, and the OSD font bit (`tb_font_xoff`).
- `tmds`: 2-stage `tmds_channel` vs the pre-split version over HDMI sequences.
- `video_fx`: `0x13`, `video_fx` vs `model.py`, and the scaler read-during-write sync at 480p. The 720p git-history regress is not run on this branch.

## Traps

- Keep the two SDCs in sync; only `console60k.sdc` has the Z80-synchroniser cuts, and only because 138K meets them.
- `mega*` builds omit `boards/console.v` (which defines USB1/USB2) + `usb_hid_host.v` + `pll_12.v`: no USB HID there.
- `README.md` still says SRAM saves and other features are "not activated yet"; the save channel above is what the tree actually builds.
