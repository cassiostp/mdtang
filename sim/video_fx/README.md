# video_fx sims (`sim/video_fx`)

Testbenches for `src/video_fx.v` (colour controls, CRT mask, LCD grid), `src/smooth.v`
(picture smoothing) and their integration in the scaler (`framebuffer_sync.sv`). iverilog;
`./run.sh` runs everything.

| test | what it checks |
| --- | --- |
| `tb_iosys_video_config.v` | iosys command `0x13` through the real UART receiver: sets `video_config` big-endian, leaves `core_config` alone (and the other way round), ignores other commands, reset clears it |
| `tb_video_fx.v` | the module alone, against `model.py`: every brightness / contrast / saturation / gamma, every mask type and strength with the LCD grid off and at its four strengths, and 300 random settings with random pictures, borders, scanline darkening and grid flags |
| `tb_md_regress.v` | the scaler against the scaler before `video_fx` (built from git history by `prep.sh`), for each of the four frame sizes (256 / 320 x 224 / 240): with a `video_config` that enables nothing (`0`, the firmware's all-off `0x00012000`, and `0x0003A000` with the grid bit the Mega Drive ignores) the rgb stream into the hdmi module, and the row where the core is released, are identical clock for clock, two whole frames per scanline mode, with the menu overlay up or not |
| `tb_md_fx.v` + `model.py check` | the filters running inside the scaler, for the four frame sizes: the pixels going in and coming out of `video_fx` are logged with their output position and compared with the model, so the mask lands on the right columns and rows, the scanline darkening follows the colour stage, and the border and the overlay stay untouched |
| `tb_md_smooth_regress.v` | the scaler against the scaler before smoothing (`framebuffer_fx`, built from git history by `prep.sh`), for each of the four frame sizes: with `video_config[19:18]` clear (`0`, or the reserved `3`) and the other filters on or off, the rgb stream into the hdmi module and the row where the core is released are identical clock for clock, two whole frames per scanline mode; with the menu overlay up it is identical in every smoothing mode |
| `tb_md_smooth.v` + `model.py check_smooth` | the smoothing running inside the scaler, for the four frame sizes, both modes, both geometries (960x720, and with scanlines 896x672 for 224 lines, 960x720 for 240), scanlines and the other filters on or off, overlay up or not: the line buffer holds a random picture (dumped to `md_src_WxH.hex`), the pixels going into and coming out of `video_fx` are logged with their output position on the top and bottom rows and every 13th, and compared with the model: the blend of the source pixels, the picture window, the border, the scanline flags and the filters acting on the smoothed picture |
| `tb_md_smooth_sync.v` | the smoothing against the VDP's timing: the VDP is played with its line timing (3420 clk per line, 262 lines, 8 or 10 clk per pixel), the `x` / `y` write logic of `mdtang_top.sv` and the scaler's real frame sync (`pause_core`); every read of the line buffer that the picture uses, the line to show and the neighbour line, must find its pixel written in this frame and not overwritten, with the core released on time and 19 us late (the end of the `hdmi_first_line` window); prints how long before the read the pixel was written and how many lines the core is ahead (the ring holds 32) |

`model.py` is the golden model, written from the spec (the `video_config` table in the header of
`video_fx.v`, the definition of the smoothing in the header of `smooth.v`), not from the Verilog; `model.py selfcheck` also compares it with
real-number arithmetic and a few hand-computed values. `tools/video_fx_gamma.py`
generates the gamma tables inside `video_fx.v` (`--check` tells whether the file
is up to date); the model computes the tables itself.

`prep.sh` needs python3 and git (vectors from the model, the baseline scalers
from `$BASE`, the last commit without `video_fx`, and `$FXBASE`, the last without smoothing). The simulator image used on
arm64 (`tangcore-iv:1`) has neither: run `sh prep.sh` on the host, then
`docker run --rm --user $(id -u):$(id -g) -v $PWD/../..:/w -w /w/sim/video_fx tangcore-iv:1 sh run.sh`
and `python3 -I model.py check md_fx.log` and
`python3 -I model.py check_smooth md_smooth_256x224.log md_src_256x224.hex md_smooth_320x224.log md_src_320x224.hex md_smooth_256x240.log md_src_256x240.hex md_smooth_320x240.log md_src_320x240.hex`
on the host.
