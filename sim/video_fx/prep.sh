#!/bin/sh
# Host-side preparation for run.sh: needs python3 and git.
#   vec_*.hex           test vectors from the golden model (model.py gen)
#   build/*_base.*      the scaler before video_fx, from git history ($BASE), with the module
#                       names suffixed _base so that both can be in one simulation
#   build/framebuffer_sync_fx.sv  the scaler with video_fx and without smoothing ($FXBASE), as framebuffer_fx
set -e
cd "$(dirname "$0")"
BASE=${BASE:-c53e2a4}       # the last commit without video_fx
FXBASE=${FXBASE:-a6f0363}   # the last commit without smoothing
python3 -I model.py selfcheck
python3 -I model.py gen
mkdir -p build
git show $BASE:src/framebuffer_sync.sv | sed \
    -e 's/^module framebuffer #(/module framebuffer_base #(/' \
    -e 's/^sl_rows sl (/sl_rows_base sl (/' \
    -e 's/^sl_dim dim (/sl_dim_base dim (/' > build/framebuffer_sync_base.sv
git show $BASE:src/scanlines.v | sed \
    -e 's/^module sl_rows (/module sl_rows_base (/' \
    -e 's/^module sl_dim (/module sl_dim_base (/' > build/scanlines_base.v
git show $FXBASE:src/framebuffer_sync.sv | sed -e 's/^module framebuffer #(/module framebuffer_fx #(/' > build/framebuffer_sync_fx.sv
# Native rate: the differential benches (tb_md_regress, tb_md_smooth_regress)
# compare the new scaler against these baselines clock for clock, so both
# sides must run the shipped 1652-clock line. The old sources predate
# std_timing/NATIVE_FRAME_WIDTH; give their hdmi instance both explicitly
# (an unconnected std_timing is X with the shared hdmi.sv select).
sed -i -e 's/\.START_Y(0) )/.START_Y(0), .NATIVE_FRAME_WIDTH(1652) )/' \
    -e "s/hdmi( \.clk_pixel_x5/hdmi( .std_timing(1'b0), .clk_pixel_x5/" \
    build/framebuffer_sync_base.sv build/framebuffer_sync_fx.sv
grep -q "hdmi( .std_timing(1'b0)" build/framebuffer_sync_base.sv
grep -q "hdmi( .std_timing(1'b0)" build/framebuffer_sync_fx.sv
grep -q '^module framebuffer_fx #(' build/framebuffer_sync_fx.sv
grep -q '^module framebuffer_base #(' build/framebuffer_sync_base.sv
grep -q '^sl_rows_base sl (' build/framebuffer_sync_base.sv
grep -q '^sl_dim_base dim (' build/framebuffer_sync_base.sv
grep -q '^module sl_rows_base (' build/scanlines_base.v
grep -q '^module sl_dim_base (' build/scanlines_base.v
echo "prep: vectors and baselines from $BASE and $FXBASE ready"
