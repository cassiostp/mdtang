Read the project-wide rules first: https://github.com/cassiostp/tangcore/blob/main/AGENTS.md

# mdtang — Genesis/Mega Drive core

Genesis/Mega Drive for the Tang Console 138K/60K. Mostly verbatim port of `MiSTer-devel/Genesis_MiSTer`; country is Americas/NTSC.

## Layout

- Top: `src/mdtang_top.sv` (`module mdtang_top`), machine `src/system.sv` (`module system`, M68K/Z80/PSG/FM).
- Video: synchronised upscaler `src/framebuffer_sync.sv` (short buffer for progressive 720p; three-field interlace store on 138K) into `src/hdmi/hdmi.sv`; helpers `src/scanlines.v`, `src/video_fx.v`, `src/smooth.v`. `src/iosys/framebuffer.sv` is a legacy fixed-`1650` version, unused by the build.
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

Unset, empty or `standard` is the normal build; `hz120` is the 480p120 build (console138k only, anything else is an error); anything else stops with an error. `build.tcl` prints `TangCore variant: <name>` so it shows in the build log, and sets the include path to `src/variant/<variant>` (a second `set_option -include_path` line with an absolute path derived from the script's location: Gowin resolves the path at synthesis time under `impl/`, so a relative path misses): variant-dependent hardware sources include `variant.vh`, which defines `HZ120` for the hz120 build. The 138K headers define `MD_INTERLACE` for native interlace timing and a three-field weave store; all 120 Hz differences are inside `` `ifdef HZ120 ``. The 60K boards select `src/variant/legacy/variant.vh` and retain the original short-buffer video path. CI:

```sh
gh workflow run cores.yml -R cassiostp/tangcore --ref ci/core-builds \
  -f core=mdtang -f ref=<branch> -f board=console138k -f variant=hz120
```

The hz120 bitstream is saved as `mdtang_120hz.bin` (artifact `mdtang-console138k-hz120);
the standard one stays `mdtang.bin`. Both 138K variants reserve three 320x240 RGB4 field banks for interlace. Progressive 720p uses the original ring addresses within that store; progressive hz120 uses its original two banks. The 60K has 118 BSRAM blocks and keeps its original short buffer; hz120 remains 138K-only.

## Clocks and constraints

- Both SDCs: `clk50` 50 MHz, `clk_sys` ~53.85 MHz (`pll.v`), `clk_z80 = clk_sys/2`, plus a 4/3 `z80 -> sys` multicycle. HDMI `hclk/hclk5` (74.25/371.25 MHz from `pll_74` via 27 MHz `pll_27`) and USB `clk12` (`pll_12`) are generated in `mdtang_top.sv` but have no SDC entries.
- `console60k.sdc` repeats `mdtang.sdc` and adds two `set_false_path` cuts on the M68K->Z80 `z80_busrq_n`/`z80_reset_n` synchronisers (the 60K fit misses hold there by ~50 ps once the design passes ~3/4 BSRAM; 138K keeps the check). Gowin reads one SDC per project, so the two files must stay in sync.

## Native-rate lock

Genesis native rate is a 1652-pixel line (`NATIVE_FRAME_WIDTH = 1652` in `src/framebuffer_sync.sv`; 59.9274 Hz at 74.25 MHz). `std_timing = 1` selects the standard 1650 line; `video_std_timing` is tied `1'b0` in `src/mdtang_top.sv`, so the build is native-only.
Progressive 720p asserts `pause_core` at source line 1, column 0, and clears it at HDMI `hdmi_first_line`; progressive hz120 holds a completed field until its two-refresh release; `mdtang_top.sv` gates `system.PAUSE_EN` (M68K/Z80 clocks, audio held) on it.

On 138K NTSC interlace with 224-line fields, the VDP alternates 262/263 lines. HDMI uses 1,241,460 pixel clocks per 720p refresh or 451,440 per 480p120 refresh (two refreshes per field), giving 59.80861244 fields/s, +0.127 ppm above the NTSC target. Progressive cadence is unchanged. Only line totals change: 1656/1655 in 720p, 860/859 in 480p120; sync start/width and active dimensions stay standard. `std_timing` bypasses the native cadence.

The interlace capture latches VBL at HBL's falling edge: VBL changes at HINT before the final eight active pixels. HDMI owns one completed field per parity; the VDP writes the third bank, halts after the last active pixel, and receives the discarded bank at the next HDMI field boundary. Mode 2 reads alternate rows from the even/odd banks (448 or 480 rows). Integer is 1x vertically, centred; Full fills the existing 4:3 viewport. At 1x scanlines alternate output rows, and thin/thick coincide. The OSD retains its progressive coordinates. Progressive video, rate and audio pitch are unchanged.

## Firmware link

- Core ID 4 (`CORE_ID(4)` in `src/mdtang_top.sv`; firmware maps 4 to `mdtang.bin`).
- Save channel `SAVE_IF=1, SAVE_AW=16, SAVE_SYNC=0` (64 KB): cart SRAM lives in SDRAM at `0x820000-0x83FFFF` as `{8'h41,MBUS_A[16:1]}` words (raw MiSTer `.sav` layout, big-endian byte lanes on port 3); EEPROM mode is steered to BRAM instead.
- `core_config` bits used: `[3:0]` EEPROM type, `[4]` SRAM, `[5]` SRAM00, `[6]` NORAM, `[7]` FM-busy, `[8]` Sega Channel, `[17]` menu pause, `[16]` scanlines, `[19:18]` darkness, `[20]` thick, `[21]` out, `[22]` pads-muted; `video_config` drives `video_fx.v`/`smooth.v`.
- `iosys_bl616.v` is one of six divergent copies (`cassiostp/tangcore#30`): a fix to one usually belongs in the others.

## Simulations (`sim/cosim/README.md` and `sim/video_fx/README.md` say how to run; iverilog)

Sim scripts use `simrun` when it is on PATH (else `docker run --rm`);
set `SIM_PREFIX` to namespace container names when sharing the machine.
`simrun` is an optional local helper (persistent ccache + full-core env),
not part of the repositories.

- `bigrom`: headless full-system >4 MB ROM/SSF2-banking/I2C-EEPROM on the real `mdtang_top` Verilator build.
- `cosim`: Verilator `iosys_bl616` UART engine + `sdram.v` port-3 client for firmware co-sim, no game/video/audio.
- `eeprom`: 68K bit-bang vs `EPPROM_24CXX` wired as `system.sv` (modes 0/1/2, `BRAM_CHANGE`).
- `framelock`: real `framebuffer_sync.sv` (1652) vs the VDP model (3420 clocks/line, 262 lines); locked rate, per-frame wait, re-lock within 2 frames.
- `saveram`: `tb_system_save` (real iosys+sdram port 3 as the top, MD bus on port 0) and `tb_sdram_save` (port-3 map, row-crossing) plus engine-level `tb_saveram_sdram`.
- `scanlines`: `scanlines.v` geometry/darkening plus whole-frame scaler-vs-model with release row.
- `vdplock`: Verilator real-VDP CPU programming, 262/263-line alternation, native interlace lock and per-pixel field/position/ownership checks (`run.sh standard|hz120`).
- `weave`: Verilator 448/480-line geometry, Integer/Full and scanlines, plus the real HDMI counters for native/progressive/standard timing (`run.sh standard|hz120`).
- `compat`: Verilator differential pixels and OSD coordinates against `int/round7` for both progressive variants (`run.sh standard|hz120`; requires git history).
- `tmds`: 2-stage `tmds_channel` vs the pre-split version over HDMI sequences.
- `video_fx`: `0x13`, `video_fx` vs `model.py`, regress-vs-git-history with filters off, FX/smoothing/sync checks.

Each `sim/*` bench with a `run.sh` takes `[standard|hz120]` (default both; `scanlines`, `framelock`, `video_fx`). The video benches compile the scaler with `-DHZ120 -I ../../src/variant/hz120` for the hz120 variant and the standard include without the define for standard. `saveram` and `cosim` always use the standard include.

`MD_VIDEO_SIM` enables the real capture/scaler in the headless machine wrapper for `sim/interlace_smoke`; its build selects a standard/hz120 header explicitly. Ordinary headless builds keep their existing flags and use the corrected VDP field counter without compiling video. `sim/interlace_smoke/README.md` documents the local Sonic 2 script and output handling. The NTSC board uses 224-line fields for interlaced games; 480-row scaler geometry is also tested synthetically. PAL is not selected by this top.

## Traps

- Keep the two SDCs in sync; only `console60k.sdc` has the Z80-synchroniser cuts, and only because 138K meets them.
- `mega*` builds omit `boards/console.v` (which defines USB1/USB2) + `usb_hid_host.v` + `pll_12.v`: no USB HID there.
- `README.md` still says SRAM saves and other features are "not activated yet"; the save channel above is what the tree actually builds.

Run `sh sim/regress.sh quick both` before handing work back; `quick` is the minimum check. Use `full both` for all benches, `--only bench1,bench2` to select, and `--list` for tiers, variants, images and typical times. At most two benches run together; logs and tables are in `sim/.regress/`. `TANGCORE_ROMS` defaults to `~/tangcore-test-bundle/test roms`; missing ROMs and unsupported variants SKIP. Keep ROM-derived output local.
