// Sychronized upscaler to HDMI
// nand2mario, 2024.10
//
// This module takes RGB pixel input, buffers the video in BRAM,
// then upscales and output the video over HDMI.
// The video aspect ratio is 4:3, with the video centered on the screen.
//
// Standard variant: 16 lines of the video are buffered and the picture is
// shown in 720p, scaled 256/320 x 224/240 to 960x720 (4:3); see the Video
// comment below for the scanline geometry. Nearest neighbour.
//
// HZ120 variant (480p120 build): the Mega Drive picture is stored in a
// double-buffered full frame (320 x 240, 12-bit) and each console frame is
// read out twice, once per HDMI refresh. Black-frame insertion is
// video_config[21:20]:
//   0 off (both refreshes lit), 1 the second refresh black, 2 the second
//   refresh at half brightness, 3 same as 1 (the rolling-scan prototype is
//   NES-only). The menu overlay is lit on every refresh. Modes 1-3 swap
//   which refresh is the dark one every ~30 s so an LCD's frame polarity
//   does not see a DC bias.
// Integer 2x, centred in the 720x480 frame: H32 is 512 wide, H40 is 640;
// 224 lines sit on rows 16..463 and 240 lines fill the frame. Full scale
// fills the 4:3 frame (640x480), the same aspect as the 60 Hz Full scale.
//
// This is different from framebuffer.sv in that it requires the input video
// to be synchronized to HDMI. This allows the module use much less BRAM space
// compared to a full framebuffer (standard variant; the hz120 variant keeps
// a full double frame instead, in BSRAM).
`include "variant.vh"
module framebuffer #(
    parameter WIDTH = 320,          // max frame width (<=1280)
    parameter HEIGHT = 240,         // max frame height (<=720)
    parameter COLOR_BITS = 4        // bits per RGB color channel
)(
	input clk,                      // megadrive clock
	input resetn,
	input clk_pixel,                // pixel clock (74.25 MHz standard, 54 MHz hz120)
	input clk_5x_pixel,             // 5x pixel clock

    // video signals
    input ce_pix,                   // pixel strobe
    input [COLOR_BITS-1:0] r,       // pixel color
    input [COLOR_BITS-1:0] g,
    input [COLOR_BITS-1:0] b,
    input [$clog2(WIDTH)-1:0] x,    // pixel position
    input [$clog2(HEIGHT)-1:0] y,
    input [10:0] width,             // frame width
    input [9:0] height,             // frame height

    output reg pause_core,          // sync mechanism: input video should be a bit faster (e.g. 0.x%)
                                    // than HDMI. It should wait after line 0 is rendered
                                    // and wait for sync_line1 to continue rendering.

    // overlay from iosys
    input overlay,
    output [7:0] overlay_x,
    output [7:0] overlay_y,
    input [14:0] overlay_color,     // BGR5

    input scanlines,                // core_config[16]: scanlines on
    input [1:0] sl_darkness,        // core_config[19:18]: 25, 50, 75, 100 % dark
    input sl_thick,                 // core_config[20]: thick lines
    input sl_out,                   // core_config[21]: scale, 0 = integer, 1 = full
    input [31:0] video_config,      // colour controls and the CRT mask, see video_fx.v (the LCD grid is unused;
                                    // the hz120 variant also reads BFI from video_config[21:20], see below)

    input std_timing,               // 1: standard timing (60.00 Hz 720p / 120 Hz 480p120), 0: native console rate (see hdmi.sv)

    input [15:0] audio_left,        // audio sample
    input [15:0] audio_right,

	// HDMI output signals
	output       tmds_clk_n,
	output       tmds_clk_p,
	output [2:0] tmds_d_n,
	output [2:0] tmds_d_p
);

`ifdef HZ120
localparam CLKFRQ = 54000;
`else
localparam CLKFRQ = 74250;
`endif

// video stuff
wire [10:0] cx /* xsynthesis syn_keep=1 */;
wire [9:0] cy  /* xsynthesis syn_keep=1 */;

`ifdef HZ120
//
// Full-frame buffer, two banks. A field is at most 320 x 240 (H40, V30);
// interlace stays one field per bank, the same presentation as the 60 Hz
// core. 12-bit pixels, synchronous read so this maps to BSRAM.
//
localparam FB_W = 320;
localparam FB_H = 240;
localparam FB_FRAME = FB_W * FB_H;          // 76800
localparam COLOR_WIDTH = COLOR_BITS * 3;
reg [COLOR_WIDTH-1:0] mem [0:2*FB_FRAME-1];
reg mem_portA_we;
reg wr_bank = 1'b0;
reg rd_bank = 1'b0;
reg rel_tgl = 1'b0;
// Address of the pixel being written. Combinational so a bench that samples
// it on the write clock sees this pixel, not the previous one.
wire [17:0] mem_portA_addr = (wr_bank ? FB_FRAME[17:0] : 18'd0) + y * 18'd320 + {9'd0, x};

wire [17:0] mem_portB_addr;
reg [COLOR_WIDTH-1:0] mem_portB_rdata;

// BRAM port A: the core writes the bank it owns
reg ce_pix_r;
reg [7:0] y_r = 8'd0;
always @(posedge clk) begin
    ce_pix_r <= ce_pix;
    if (ce_pix & ~ce_pix_r && y < FB_H && {1'b0, x} < FB_W) begin
        mem[mem_portA_addr] <= {r, g, b};
        mem_portA_we <= 1'b1;
    end else
        mem_portA_we <= 1'b0;
end
`else
//
// BRAM frame buffer
//
localparam FB_DEPTH = WIDTH * 32;           // buffer 16 lines
localparam COLOR_WIDTH = COLOR_BITS * 3;
localparam FB_AWIDTH = $clog2(FB_DEPTH);
reg [COLOR_WIDTH-1:0] mem [0:FB_DEPTH-1];
reg [FB_AWIDTH-1:0] mem_portA_addr;
reg mem_portA_we;

wire [FB_AWIDTH-1:0] mem_portB_addr;
reg [COLOR_WIDTH-1:0] mem_portB_rdata;

// BRAM port A read/write
reg ce_pix_r, hblank_r;
assign mem_portA_addr = y[4:0] * WIDTH + x;
always @(posedge clk) begin
    ce_pix_r <= ce_pix;
    if (ce_pix & ~ce_pix_r) 
        mem[mem_portA_addr] <= {r, g, b};
end
`endif

// BRAM port B read
reg [$clog2(WIDTH)-1:0] xx  /* xsynthesis syn_keep=1 */; // scaled-down pixel position
reg [$clog2(HEIGHT)-1:0] yy /* xsynthesis syn_keep=1 */;
reg [7:0] yy_s;             // source line to show (scanlines.v picks it for the integer scale)
always @(posedge clk_pixel) begin
    mem_portB_rdata <= mem[mem_portB_addr];
end

`ifdef HZ120
// The core runs a field into wr_bank, then waits. HDMI latches that bank and
// shows it for two refreshes, then releases the core to fill the other bank.
// Free-run is 60.0935 Hz and two 480p120 frames are 59.9401 Hz, so the wait
// is about 43 us once locked. Release stays on even HDMI frames, so the
// BFI phase swap below does not move the game.
wire [9:0] sl_pic_top;          // first row of the picture, from scanlines.v
reg hdmi_first_line;
reg [2:0] rel_sync = 3'b0;
reg rel_lvl = 1'b0;
wire rel_pulse = rel_sync[2] ^ rel_lvl;
always @(posedge clk) begin
    y_r <= y;
    rel_sync <= {rel_sync[1:0], rel_tgl};
    rel_lvl <= rel_sync[2];
    if (~resetn) begin
        pause_core <= 1'b0;
        wr_bank <= 1'b0;
        rel_sync <= 3'b0;
        rel_lvl <= 1'b0;
    end else if (pause_core && rel_pulse) begin
        pause_core <= 1'b0;
        wr_bank <= ~wr_bank;
    end else if (!pause_core && y == height[7:0] && y_r != height[7:0])
        pause_core <= 1'b1;                 // picture just finished: hold it for HDMI
end

// BFI. bfi_ins toggles every HDMI frame; the dark refresh is bfi_ins ^ phase.
// Phase flips every BFI_SWAP_FRAMES game frames (~30 s) for modes 1-3, armed
// at a release and applied at the next frame start, so one boundary shows
// two lit or two dark refreshes and the release cadence never moves.
localparam BFI_SWAP_FRAMES = 1800;
reg bfi_ins = 1'b1;
reg bfi_phase = 1'b0;
reg bfi_swap_pending = 1'b0;
reg [10:0] bfi_swap_cnt = 11'd0;
reg at_f0 = 1'b0;
reg [1:0] bfi_cfg_s = 2'd0, bfi_cfg = 2'd0;
reg pause_s1 = 1'b0, pause_s2 = 1'b0;
reg wr_bank_s1 = 1'b0, wr_bank_s2 = 1'b0;
always @(posedge clk_pixel) begin
    bfi_cfg_s <= video_config[21:20];
    bfi_cfg <= bfi_cfg_s;
    pause_s1 <= pause_core;
    pause_s2 <= pause_s1;
    wr_bank_s1 <= wr_bank;
    wr_bank_s2 <= wr_bank_s1;
    at_f0 <= (cy == 10'd0);
    if (cy == 10'd0 && !at_f0) begin
        bfi_ins <= ~bfi_ins;
        if (bfi_swap_pending) begin
            bfi_phase <= ~bfi_phase;
            bfi_swap_pending <= 1'b0;
        end
        // bfi_ins still holds the pre-toggle value: 1 means this frame is the
        // even one (the release slot). Apply-pending above is the odd frame,
        // so the two never assign bfi_swap_pending in the same cycle.
        if (bfi_ins && pause_s2) begin
            rd_bank <= wr_bank_s2;
            rel_tgl <= ~rel_tgl;
            if (bfi_cfg != 2'd0) begin
                if (bfi_swap_cnt == BFI_SWAP_FRAMES - 1) begin
                    bfi_swap_cnt <= 11'd0;
                    bfi_swap_pending <= 1'b1;
                end else
                    bfi_swap_cnt <= bfi_swap_cnt + 11'd1;
            end
        end
    end
end
always @(posedge clk_pixel) begin
    if (cy == sl_pic_top && cx >= 11'd160)
        hdmi_first_line <= 1;
    else
        hdmi_first_line <= 0;
end
`else
// Video synchronization
reg sync_done = 1'b0;
reg hdmi_first_line, hdmi_first_line_r, hdmi_first_line_rr;
wire [9:0] sl_pic_top;          // first row of the picture, from scanlines.v
always @(posedge clk) begin
    hdmi_first_line_r <= hdmi_first_line;
    hdmi_first_line_rr <= hdmi_first_line_r;
    if (~sync_done) begin
        if (~pause_core) begin
            if (y == 8'd1 && x == 0)                       // halt on the core starting line 1
                pause_core <= 1'b1;
        end else if (hdmi_first_line_rr && pause_core) begin     // resume when HDMI start line 0
            pause_core <= 1'b0;
            sync_done <= 1'b1;
        end
    end
    if (y == 100) sync_done <= 1'b0;                    // reset sync_done for next frame
end
always @(posedge clk_pixel) begin
    if (cy == sl_pic_top && cx >= 160)                  // first row of the picture, start position of 4:3 frame
        hdmi_first_line <= 1;
    else
        hdmi_first_line <= 0;
end
`endif

// audio stuff
localparam AUDIO_RATE=48000;
localparam AUDIO_CLK_DELAY = CLKFRQ * 1000 / AUDIO_RATE / 2;
logic [$clog2(AUDIO_CLK_DELAY)-1:0] audio_divider;
logic clk_audio;

always @(posedge clk_pixel) begin
    if (audio_divider != AUDIO_CLK_DELAY - 1) 
        audio_divider++;
    else begin 
        clk_audio <= ~clk_audio; 
        audio_divider <= 0; 
    end
end

reg [15:0] audio_sample_word [1:0];
always @(posedge clk) begin
    audio_sample_word[0] <= audio_left;
    audio_sample_word[1] <= audio_right;
end

//
// Video
// Scale 256/320 x 224/240 to 960x720 (4:3), see scanlines.v for the scanline geometry:
// with scanlines on, 3 output rows per source line, 896x672 (224 lines) or 960x720 (240 lines).
// Nearest neighbour.
//
// HZ120 variant: 256/320 x 224/240 to 720x480, integer 2x centred, or the
// full 4:3 frame (640x480) at Full scale. See scanlines.v for the geometry.
wire [23:0] rgb;            // actual RGB output
reg [23:0] rgb_pre;         // before video_fx
reg pic_pre;                // rgb_pre is a pixel of the picture, not the border or the overlay
reg dark_pre;
reg active                  /* xsynthesis syn_keep=1 */;
reg [10:0] xcnt             /* xsynthesis syn_keep=1 */;
reg [10:0] ycnt             /* xsynthesis syn_keep=1 */;                  // fractional scaling counters
reg [9:0] cy_r;

// scanlines: sl_geom frames are scaled 3 rows per source line (standard;
// 2 rows per source line in the hz120 variant)
// The LCD grid (video_config[15]) is not offered on the Mega Drive: 960 or 896 output columns
// for 256 or 320 source pixels is not a whole number of columns per pixel. Bit 15 is cleared
// for video_fx and cfg_grid is tied low, so the picture geometry never depends on it, and
// the grid flags are tied low.
wire sl_geom, sl_show, sl_dark;
wire [7:0] sl_yy;
wire [1:0] sl_dk;
wire [7:0] lines = height >= 10'd232 ? 8'd240 : 8'd224;     // lines of the picture
sl_rows sl (
    .clk(clk_pixel), .cy(cy),
    .cfg_on(scanlines), .cfg_dark(sl_darkness), .cfg_thick(sl_thick), .cfg_out(sl_out),
    .cfg_grid(1'b0), .hide(overlay),
`ifdef HZ120
    .rows(3'd2), .dark_thin(3'd1), .dark_thick(3'd1),
    .lines(lines), .top(height >= 10'd232 ? 10'd0 : 10'd16),
`else
    .rows(3'd3), .dark_thin(3'd1), .dark_thick(3'd2),
    .lines(lines), .top(height >= 10'd232 ? 10'd0 : 10'd24),
`endif
    .geom(sl_geom), .pic_top(sl_pic_top), .yy(sl_yy), .show(sl_show), .dark(sl_dark), .last(), .darkness(sl_dk)
);
always @(posedge clk_pixel) yy_s <= sl_geom ? sl_yy : yy;

assign overlay_x = xx[7:0];
assign overlay_y = yy_s;
`ifdef HZ120
// Integer 2x, centred in the 720-wide frame (H32 -> 512, H40 -> 640);
// Full scale fills the 4:3 frame (640 wide), the same aspect as the 60 Hz Full.
wire [11:0] XSIZE  = sl_geom ? {width, 1'b0} : 12'd640;
wire [11:0] XSTART = (12'd720 - XSIZE) >> 1;
wire [11:0] XSTOP  = (12'd720 + XSIZE) >> 1;

// the shown line comes from the bank HDMI is showing
assign mem_portB_addr = (rd_bank ? FB_FRAME[17:0] : 18'd0) + yy_s * 18'd320 + {9'd0, xx};
`else
// 4:3 on 720 rows, 4:3 on 672 rows
wire [11:0] XSIZE  = (sl_geom && sl_pic_top != 10'd0) ? 12'd896 : 12'd960;
wire [11:0] XSTART = (12'd1280 - XSIZE) >> 1;
wire [11:0] XSTOP  = (12'd1280 + XSIZE) >> 1;

// the line buffer is read once per source column: the line to show
assign mem_portB_addr = yy_s[4:0] * WIDTH + xx;
`endif

// address calculation
// Assume the video occupies fully on the Y direction, we are upscaling the video by `720/height`
// (hz120: `480/height`).
// xcnt and ycnt are fractional scaling counters.
// video_fx follows rgb_pre with FX_LAT register stages. Its first stage is the one that sl_dim
// used to be (active started at XSTART - 2 then), so active starts FX_LAT - 1 clocks earlier
// than that, at XSTART - 1 - FX_LAT. The line buffer read lands in rgb_pre two clocks after
// its address cycle (the BRAM and the rgb_pre register), and the overlay lookup address is
// the same xx: the overlay_color BRAM answers two clocks later, with the pixel rgb_pre shows.
// The source line (yy_s) only changes at the start of an output row, far from the picture,
// so which line is read on which row does not move.
localparam FX_LAT = 11;     // clocks from rgb_pre to rgb, see video_fx.v
always @(posedge clk_pixel) begin
    reg active_t;
    reg [10:0] xcnt_next;
    reg [10:0] ycnt_next;
    xcnt_next = xcnt + (overlay ? 256 : width);
    ycnt_next = ycnt + (overlay ? 224 : height);

    active_t = 0;
    if ({1'b0, cx} == XSTART - 12'd1 - FX_LAT) begin
        active_t = 1;
        active <= 1;
    end else if ({1'b0, cx} == XSTOP - 12'd1 - FX_LAT) begin
        active_t = 0;
        active <= 0;
    end

    if (active_t | active) begin        // increment xx
        xcnt <= xcnt_next;
        if (xcnt_next >= XSIZE) begin
            xcnt <= xcnt_next - XSIZE;
            xx <= xx + 1;
        end
    end

    cy_r <= cy;
    if (cy[0] != cy_r[0]) begin         // increment yy at new lines
        ycnt <= ycnt_next;
`ifdef HZ120
        if (ycnt_next >= 480) begin
            ycnt <= ycnt_next - 480;
            if (yy != lines - 8'd1)        // blanking keeps showing the last line
                yy <= yy + 1;
        end
`else
        if (ycnt_next >= 720) begin
            ycnt <= ycnt_next - 720;
            yy <= yy + 1;
        end
`endif
    end

    if (cx == 0) begin
        xx <= 0;
        xcnt <= 0;
    end
    
    if (cy == 0) begin
        yy <= 0;
        ycnt <= 0;
    end 

end

// calc rgb value to hdmi: the line buffer read as RGB8, two clocks after its address cycle
wire [23:0] pal = {mem_portB_rdata[COLOR_BITS*2 +: COLOR_BITS], {(8-COLOR_BITS){1'b0}},
                   mem_portB_rdata[COLOR_BITS   +: COLOR_BITS], {(8-COLOR_BITS){1'b0}},
                   mem_portB_rdata[0            +: COLOR_BITS], {(8-COLOR_BITS){1'b0}}};    // RGB4 to RGB8
`ifdef HZ120
// Mode 2-3 (Lottes-style brightness-preserving BFI): in linear light each
// pixel's content-frame budget (2x its value, gain 1.0: unchanged average
// brightness, cf. the Blur Busters / Lottes CRT beam simulator at 2 subframes)
// is carried as HI = min(1, budget) on one refresh and LO = the remainder on
// the other, through the precomputed BFI_HI/LO tables below (exact sRGB
// piecewise pair, GAMMA=2.4; worst average-light error 0.37 % of full
// white, see tools/bfi_lottes.py). Dark and mid pixels (v <= 0.5) land
// wholly in one refresh, i.e. full 50 % clarity; only bright pixels spill
// over. Mode 2 shows HI on every lit refresh (global parity); mode 3 flips
// the parity per screen half (top rows HI on lit refreshes, bottom rows HI
// on inserted ones), so the 60 Hz flicker has no whole-frame flash, at the
// same per-pixel brightness and clarity. Refresh pairs stay complementary
// and every pixel alternates HI/LO, so the phase swap above still averages
// LCD DC exactly as in mode 1.
// Credit: Mark Rejhon (Blur Busters) & Timothy Lottes (MIT, Dec 2024).
localparam [9:0] BEAM_SPLIT = 10'd240;  // mode-3 half split (top/bottom)
reg [7:0] BFI_HI [0:15];
reg [7:0] BFI_LO [0:15];
localparam [23:0] BORDER_HI = 24'h454545;
localparam [23:0] BORDER_LO = 24'h000000;
// In an inserted BFI refresh the whole picture (border included) is black
// (mode 1) or the HI/LO complement (modes 2-3). The menu overlay is exempt,
// so the menu stays steady.
wire bfi_lottes = (bfi_cfg == 2'd2) | (bfi_cfg == 2'd3);
wire bfi_eff_ins = bfi_ins ^ bfi_phase;
wire show_hi = ~bfi_eff_ins ^ ((bfi_cfg == 2'd3) & (cy >= BEAM_SPLIT));
wire bfi_dark = bfi_eff_ins & (bfi_cfg == 2'd1) & ~overlay;
reg [23:0] rgb_norm;
reg [23:0] rgb_hi, rgb_lo;
always @* begin
    if (active & sl_show) begin
        if (overlay)
            rgb_norm = {overlay_color[4:0],3'b0,overlay_color[9:5],3'b0,overlay_color[14:10],3'b0};       // BGR5 to RGB8
        else
            rgb_norm = pal;
        rgb_hi = overlay ? rgb_norm :
            {BFI_HI[pal[23:20]], BFI_HI[pal[15:12]], BFI_HI[pal[7:4]]};
        rgb_lo = overlay ? rgb_norm :
            {BFI_LO[pal[23:20]], BFI_LO[pal[15:12]], BFI_LO[pal[7:4]]};
    end else begin
        rgb_norm = 24'h303030;
        rgb_hi = BORDER_HI;
        rgb_lo = BORDER_LO;
    end
end
always @(posedge clk_pixel) begin
    if (bfi_lottes & ~overlay)
        rgb_pre <= show_hi ? rgb_hi : rgb_lo;
    else if (!bfi_dark)
        rgb_pre <= rgb_norm;
    else
        rgb_pre <= 24'h000000;      // black inserted refresh (mode 1)
    // Lottes modes carry real picture data on both refreshes, so both get
    // the same colour/scanline processing downstream (unlike black BFI).
    pic_pre <= active & sl_show & ~overlay & (~bfi_dark | bfi_lottes);
    dark_pre <= active & sl_show & ~overlay & sl_dark & (~bfi_dark | bfi_lottes);
end
`else
always @(posedge clk_pixel) begin
    if (active & sl_show) begin
        if (overlay)
            rgb_pre <= {overlay_color[4:0],3'b0,overlay_color[9:5],3'b0,overlay_color[14:10],3'b0};       // BGR5 to RGB8
        else
            rgb_pre <= pal;
    end else
        rgb_pre <= 24'h303030;
    pic_pre <= active & sl_show & ~overlay;
    dark_pre <= active & sl_show & ~overlay & sl_dark;
end
`endif

// colour controls, the scanline darkening and the CRT mask
video_fx fx (
    .clk(clk_pixel), .cx(cx), .cy(cy), .video_config({video_config[31:16], 1'b0, video_config[14:0]}),
    .rgb_in(rgb_pre), .pic_in(pic_pre), .dark_in(dark_pre), .darkness(sl_dk),
    .col_last_in(1'b0), .row_last_in(1'b0),
    .rgb_out(rgb)
);

// HDMI output.
logic[2:0] tmds;

`ifdef HZ120
localparam FRAMEWIDTH = 720;
localparam FRAMEHEIGHT = 480;
localparam TOTALWIDTH = 858;
localparam TOTALHEIGHT = 525;
localparam SCALE = 5;
localparam VIDEOID = 48;            // 480p120, VIC 48
localparam VIDEO_REFRESH = 120.0;
localparam COLLEN = 80;
localparam AUDIO_BIT_WIDTH = 16;
// 54 MHz / (858 x 525) = 119.8801 Hz, twice 59.9401 Hz. The exact 2x of the
// 60 Hz build (74.25 MHz / (1652 x 750) = 59.9274 Hz) would be an 858.18-pixel
// line; 858 is the longest integer line that does not run the game slower
// (+0.021 % vs the 60 Hz build). 859 would be slower.
localparam NATIVE_FRAME_WIDTH = 858;
`else
localparam FRAMEWIDTH = 1280;
localparam FRAMEHEIGHT = 720;
localparam TOTALWIDTH = 1650;
localparam TOTALHEIGHT = 750;
localparam SCALE = 5;
localparam VIDEOID = 4;
localparam VIDEO_REFRESH = 60.0;
localparam COLLEN = 80;
localparam AUDIO_BIT_WIDTH = 16;
// Genesis native rate: 1652 clocks/line = 59.9274 Hz at 74.25 MHz (see hdmi.sv).
localparam NATIVE_FRAME_WIDTH = 1652;
`endif
hdmi #( .VIDEO_ID_CODE(VIDEOID),
        .DVI_OUTPUT(0),
        .VIDEO_REFRESH_RATE(VIDEO_REFRESH),
        .IT_CONTENT(1),
        .AUDIO_RATE(AUDIO_RATE),
        .AUDIO_BIT_WIDTH(AUDIO_BIT_WIDTH),
        .START_X(0),
        .START_Y(0),
        .NATIVE_FRAME_WIDTH(NATIVE_FRAME_WIDTH) )

hdmi( .std_timing(std_timing),
        .clk_pixel_x5(clk_5x_pixel), 
        .clk_pixel(clk_pixel), 
        .clk_audio(clk_audio),
        .rgb(rgb), 
        .reset( /* ~resetn */ ),
        .audio_sample_word(audio_sample_word),
        .tmds(tmds), 
        .tmds_clock(tmdsClk), 
        .cx(cx), 
        .cy(cy),
        .frame_width(),
        .frame_height() );

// Gowin LVDS output buffer
ELVDS_OBUF tmds_bufds [3:0] (
    .I({clk_pixel, tmds}),
    .O({tmds_clk_p, tmds_d_p}),
    .OB({tmds_clk_n, tmds_d_n})
);

`ifdef HZ120
// BEGIN Lottes tables (tools/bfi_lottes.py, sRGB GAMMA=2.4).
// Per channel nibble: HI = lit-refresh value, LO = remainder refresh.
// [0] 00 -> HI 00 LO 00
// [1] 10 -> HI 1a LO 00
// [2] 20 -> HI 2f LO 00
// [3] 30 -> HI 45 LO 00
// [4] 40 -> HI 5a LO 00
// [5] 50 -> HI 6f LO 00
// [6] 60 -> HI 85 LO 00
// [7] 70 -> HI 9a LO 00
// [8] 80 -> HI b0 LO 00
// [9] 90 -> HI c5 LO 00
// [A] a0 -> HI da LO 00
// [B] b0 -> HI f0 LO 00
// [C] c0 -> HI ff LO 42
// [D] d0 -> HI ff LO 8c
// [E] e0 -> HI ff LO ba
// [F] f0 -> HI ff LO e0
// HI table (lit refresh), indexed by channel nibble:
assign BFI_HI[0] = 8'h00;
assign BFI_HI[1] = 8'h1a;
assign BFI_HI[2] = 8'h2f;
assign BFI_HI[3] = 8'h45;
assign BFI_HI[4] = 8'h5a;
assign BFI_HI[5] = 8'h6f;
assign BFI_HI[6] = 8'h85;
assign BFI_HI[7] = 8'h9a;
assign BFI_HI[8] = 8'hb0;
assign BFI_HI[9] = 8'hc5;
assign BFI_HI[10] = 8'hda;
assign BFI_HI[11] = 8'hf0;
assign BFI_HI[12] = 8'hff;
assign BFI_HI[13] = 8'hff;
assign BFI_HI[14] = 8'hff;
assign BFI_HI[15] = 8'hff;
// LO table (remainder refresh), indexed by channel nibble:
assign BFI_LO[0] = 8'h00;
assign BFI_LO[1] = 8'h00;
assign BFI_LO[2] = 8'h00;
assign BFI_LO[3] = 8'h00;
assign BFI_LO[4] = 8'h00;
assign BFI_LO[5] = 8'h00;
assign BFI_LO[6] = 8'h00;
assign BFI_LO[7] = 8'h00;
assign BFI_LO[8] = 8'h00;
assign BFI_LO[9] = 8'h00;
assign BFI_LO[10] = 8'h00;
assign BFI_LO[11] = 8'h00;
assign BFI_LO[12] = 8'h42;
assign BFI_LO[13] = 8'h8c;
assign BFI_LO[14] = 8'hba;
assign BFI_LO[15] = 8'he0;
// border 303030 -> HI 24'h454545 LO 24'h000000
`endif

endmodule
