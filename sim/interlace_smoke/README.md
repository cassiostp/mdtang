# Sonic 2 interlace smoke test

This uses the real full machine and framebuffer, with the simulation SDRAM
and HDMI-counter models. `MD_VIDEO_SIM` enables video in the usual Verilator
machine wrapper. The ROM is supplied locally and must never be committed.

Build inside `verilator/verilator:latest` from this directory:

```
VARIANT=standard SMOKE_BUILD=$PWD/build sh build.sh standard ../..
VARIANT=hz120 SMOKE_BUILD=$PWD/build sh build.sh hz120 ../..
```

Copy the CPU microcode files (`../../src/fx68k/*.mem`) into an ignored output
directory before running the built executable there. The executable takes
`ROM FRAMES OUTPUT_TAG INPUT_SCRIPT DUMP_FRAME_LIST`; use 1100 frames and the
bundled `sonic2-2p.txt` script. Set `HZ120=1` when running the hz120 executable; leave it unset for standard (the harness tests presence, so `HZ120=0` also selects hz120).
Keep outputs under `build/`. The script presses Start at frame 630 (ending the SEGA screen if needed), Down at 690, Start at 730 and Start at 830. It holds Right from 970 to 1050. It must reach two-player mode without modifying ROM
or game RAM; `GAMEFIELD` and `GAME_RATE` report the resulting field cadence.
The run captures woven HDMI images after the game selects mode 2.

Check the images and mode/cadence logs after running. The raw game video,
audio, save window and any hashes are local simulation outputs; do not add
them to git or upload them. The separate synthetic `sim/vdplock` suite tags
all reads for bank ownership, epoch, parity and source position.

`VERILATOR_THREADS` is a build-time setting (default 1): the compiled model and runtime thread pool use the same count. Rebuild after changing it; `VERILATOR_THREADS=1` retains the single-thread path.

Run `python3 sim/interlace_smoke/thread-bench.py <Sonic2-ROM> <new-local-output-dir> --variant standard --frames 120` from the repository root to measure 1/2/4/8 model threads. It uses private build directories, checks compiled/runtime thread counts and byte-compares every captured PPM, audio stream, save image and frame log. The 120-frame sample covers startup; use 1100 frames to include the scripted two-player transition. Keep every output local.

`MD_CAPTURE_HDMI=1` captures every progressive/interlaced HDMI frame as `<tag>_hdmi_<frame>.ppm`. It changes capture output only; the default keeps the interlace-only `<tag>_woven_<frame>.ppm` captures. The thread benchmark enables this so its startup sample compares every observed framebuffer/HDMI frame as well as the raw VDP snapshot.
