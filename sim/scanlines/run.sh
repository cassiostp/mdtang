#!/bin/sh
# Scanline sims (iverilog). From this directory:  ./run.sh [standard|hz120]
# With no argument both variants run.
#   tb_scanlines    the row generator and the darkening (src/scanlines.v, same in both variants)
#   tb_md_scaler    framebuffer_sync.sv whole frames, with a stub for the HDMI part
#   tb_font_xoff    the OSD glyph bit select at 480p (hz120 only; needs the SIM model
#                   of the menu RAM in src/iosys/textdisp.v)
set -e
cd "$(dirname "$0")"
RTL=../../src
VARIANTS=${1:-both}
run_variant() {
    variant=$1
    if [ "$variant" = hz120 ]; then
        DEF=-DHZ120
    else
        DEF=
    fi
    VINC="-I $RTL/variant/$variant"
    echo "--- scanlines variant: $variant"
    iverilog -g2012 $DEF $VINC -o tb_scanlines.out tb_scanlines.v $RTL/scanlines.v
    vvp tb_scanlines.out
    iverilog -g2012 $DEF $VINC -o tb_md_scaler.out tb_md_scaler.v hdmi_stub.v $RTL/framebuffer_sync.sv $RTL/scanlines.v $RTL/video_fx.v
    if [ "$variant" = hz120 ]; then
        mkdir -p frames
        # the Lottes table the modes-2/3 checks read: committed, verified
        # fresh here when python3 exists (else verify on the host:
        # python3 ../../tools/bfi_lottes.py --hex | cmp -s bfi_lottes.hex -)
        if command -v python3 >/dev/null 2>&1; then
            python3 ../../tools/bfi_lottes.py --hex | cmp -s bfi_lottes.hex - || { echo "bfi_lottes.hex is stale: regenerate with tools/bfi_lottes.py --hex"; exit 1; }
        else
            echo "note: no python3 here, skipping bfi_lottes.hex freshness check"
        fi
    fi
    vvp tb_md_scaler.out
    if [ "$variant" = hz120 ]; then
        # negative control: the same binary with one corrupted table entry
        # (code 0x70) must fail the exact pair check
        mkdir -p negative/frames
        cp tb_md_scaler.out negative/
        cp bfi_lottes.hex negative/
        sed -i '113s/^../ff/' negative/bfi_lottes.hex
        if (cd negative && vvp tb_md_scaler.out > neg.log 2>&1); then
            echo "FAIL: negative control passed with a corrupted table"; exit 1;
        else
            grep -q "not a table pair" negative/neg.log || { echo "FAIL: negative control failed without the pair check"; cat negative/neg.log; exit 1; }
            echo "negative control: corrupted table fails as expected"
        fi
    fi
    if [ "$variant" = hz120 ]; then
        iverilog -g2012 -DSIM $DEF $VINC -o tb_font_xoff.out tb_font_xoff.v $RTL/iosys/textdisp.v
        vvp tb_font_xoff.out
    fi
}
case $VARIANTS in
    standard) run_variant standard ;;
    hz120) run_variant hz120 ;;
    both) run_variant standard; run_variant hz120 ;;
    *) echo "usage: $0 [standard|hz120]" >&2; exit 1 ;;
esac
