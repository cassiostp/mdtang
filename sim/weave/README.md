# Interlace scaler checks

Run inside `verilator/verilator:latest`, with `sh run.sh standard` or `sh run.sh hz120`.
On the arm64 development host use `SIM_PREFIX=r6mdilace simrun` with a unique container
name, the repository mounted read/write and the matching UID/GID.

`tb_weave` stores a unique synthetic RGB4 colour for every woven source row, then
checks each output row at 256/320 widths, 224/240 field heights, Full/Integer scale,
scanlines off and all four darkness settings, both thicknesses, and the menu.
`tb_hdmi_rate` runs the real HDMI counter RTL and checks the number of pixel clocks
in progressive/native interlace/standard frames and on return to progressive.
The actual producer/consumer ownership and alternating VDP field lengths are
checked by `sim/vdplock`; progressive equality against the base is `sim/compat`.
