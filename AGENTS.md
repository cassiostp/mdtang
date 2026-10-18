Read the project-wide rules first: https://github.com/cassiostp/tangcore/blob/main/AGENTS.md

# mdtang — Genesis/Mega Drive core

Genesis/Mega Drive for the Tang Console 138K/60K. Mostly verbatim port of `MiSTer-devel/Genesis_MiSTer`; country is Americas/NTSC.

## Layout

- Top: `src/mdtang_top.sv` (`module mdtang_top`), machine `src/system.sv` (`module system`, M68K/Z80/PSG/FM).
- Video: synchronised upscaler `src/framebuffer_sync.sv` (16-line BRAM) into `src/hdmi/hdmi.sv`; helpers `src/scanlines.v`, `src/video_fx.v`, `src/smooth.v`. `src/iosys/framebuffer.sv` is a legacy fixed-`1650` version, unused by the build.
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

## Build variants (standard / hz120)

One source tree builds both bitstreams, picked at build time by `TANGCORE_VARIANT`:

```sh
gw_sh build.tcl console138k                        # standard 720p build (also when unset/empty)
TANGCORE_VARIANT=hz120 gw_sh build.tcl console138k # 480p 120 Hz build
```

Unset, empty or `standard` is the normal build; `hz120` is the 480p120 build (console138k only, anything else is an error); anything else stops with an error. `build.tcl` prints `TangCore variant: <name>` so it shows in the build log, and sets the include path to `src/variant/<variant>` (a second `set_option -include_path` line with an absolute path derived from the script's location: Gowin resolves the path at synthesis time under `impl/`, so a relative path misses): the files that differ (`framebuffer_sync.sv`, `hdmi.sv`, `textdisp.v`, the two `pll_74.v`) do `` `include "variant.vh" ``, which defines `HZ120` for hz120 and nothing for standard. The standard variant is the unmodified build; every 120 Hz difference is inside `` `ifdef HZ120 ``. CI:

```sh
gh workflow run cores.yml -R cassiostp/tangcore --ref ci/core-builds \
  -f core=mdtang -f ref=<branch> -f board=console138k -f variant=hz120
```

The hz120 bitstream is saved as `mdtang_120hz.bin` (artifact `mdtang-console138k-hz120);
the standard one stays `mdtang.bin`. The 120 Hz double frame buffer costs ~108 BSRAM
blocks over the standard build (feature/hz120 measured 89 to 197 on 138K), so hz120
is 138K-only: the 60K has 118 blocks.

## Clocks and constraints

- Both SDCs: `clk50` 50 MHz, `clk_sys` ~53.85 MHz (`pll.v`), `clk_z80 = clk_sys/2`, plus a 4/3 `z80 -> sys` multicycle. HDMI `hclk/hclk5` (74.25/371.25 MHz from `pll_74` via 27 MHz `pll_27`) and USB `clk12` (`pll_12`) are generated in `mdtang_top.sv` but have no SDC entries.
- `console60k.sdc` repeats `mdtang.sdc` and adds two `set_false_path` cuts on the M68K->Z80 `z80_busrq_n`/`z80_reset_n` synchronisers (the 60K fit misses hold there by ~50 ps once the design passes ~3/4 BSRAM; 138K keeps the check). Gowin reads one SDC per project, so the two files must stay in sync.

## Native-rate lock

Genesis native rate is a 1652-pixel line (`NATIVE_FRAME_WIDTH = 1652` in `src/framebuffer_sync.sv`; 59.9274 Hz at 74.25 MHz). `std_timing = 1` selects the standard 1650 line; `video_std_timing` is tied `1'b0` in `src/mdtang_top.sv`, so the build is native-only.
The scaler asserts `pause_core` when input reaches line 0 (`sync_y` 1/2, +1 with smoothing) and clears it at HDMI `hdmi_first_line`; `mdtang_top.sv` gates `system.PAUSE_EN` (M68K/Z80 clocks, audio held) on it.

## Firmware link

- Core ID 4 (`CORE_ID(4)` in `src/mdtang_top.sv`; firmware maps 4 to `mdtang.bin`).
- Save channel `SAVE_IF=1, SAVE_AW=16, SAVE_SYNC=0` (64 KB): cart SRAM lives in SDRAM at `0x820000-0x83FFFF` as `{8'h41,MBUS_A[16:1]}` words (raw MiSTer `.sav` layout, big-endian byte lanes on port 3); EEPROM mode is steered to BRAM instead.
- `core_config` bits used: `[3:0]` EEPROM type, `[4]` SRAM, `[5]` SRAM00, `[6]` NORAM, `[7]` FM-busy, `[8]` Sega Channel, `[17]` menu pause, `[16]` scanlines, `[19:18]` darkness, `[20]` thick, `[21]` out, `[22]` pads-muted; `video_config` drives `video_fx.v`/`smooth.v`.
- `iosys_bl616.v` is one of six divergent copies (`cassiostp/tangcore#30`): a fix to one usually belongs in the others.

## Simulations (`sim/cosim/README.md` and `sim/video_fx/README.md` say how to run; iverilog)

- `bigrom`: headless full-system >4 MB ROM/SSF2-banking/I2C-EEPROM on the real `mdtang_top` Verilator build.
- `cosim`: Verilator `iosys_bl616` UART engine + `sdram.v` port-3 client for firmware co-sim, no game/video/audio.
- `eeprom`: 68K bit-bang vs `EPPROM_24CXX` wired as `system.sv` (modes 0/1/2, `BRAM_CHANGE`).
- `framelock`: real `framebuffer_sync.sv` (1652) vs the VDP model (3420 clocks/line, 262 lines); locked rate, per-frame wait, re-lock within 2 frames.
- `saveram`: `tb_system_save` (real iosys+sdram port 3 as the top, MD bus on port 0) and `tb_sdram_save` (port-3 map, row-crossing) plus engine-level `tb_saveram_sdram`.
- `scanlines`: `scanlines.v` geometry/darkening plus whole-frame scaler-vs-model with release row.
- `tmds`: 2-stage `tmds_channel` vs the pre-split version over HDMI sequences.
- `video_fx`: `0x13`, `video_fx` vs `model.py`, regress-vs-git-history with filters off, FX/smoothing/sync checks.

Each `sim/*` bench with a `run.sh` takes `[standard|hz120]` (default both; `scanlines`, `framelock`, `video_fx`). The video benches compile the scaler with `-DHZ120 -I ../../src/variant/hz120` for the hz120 variant and the standard include without the define for standard. `saveram` and `cosim` always use the standard include.

## Traps

- Keep the two SDCs in sync; only `console60k.sdc` has the Z80-synchroniser cuts, and only because 138K meets them.
- `mega*` builds omit `boards/console.v` (which defines USB1/USB2) + `usb_hid_host.v` + `pll_12.v`: no USB HID there.
- `README.md` still says SRAM saves and other features are "not activated yet"; the save channel above is what the tree actually builds.
