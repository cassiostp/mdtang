// Sychronized upscaler to HDMI
// nand2mario, 2024.10
//
// 480p120 build. The Mega Drive picture is stored in a double-buffered full
// frame (320 x 240, 12-bit) and each console frame is read out twice, once
// per HDMI refresh. Black-frame insertion is video_config[21:20]:
//   0 off (both refreshes lit), 1 the second refresh black, 2 the second
//   refresh at half brightness, 3 same as 1 (the rolling-scan prototype is
//   NES-only). The menu overlay is lit on every refresh. Modes 1-3 swap
//   which refresh is the dark one every ~30 s so an LCD's frame polarity
//   does not see a DC bias.
// Integer 2x scale, centred in the 720x480 frame. H32 is 512 wide, H40 is
// 640; 224 lines sit on rows 16..463 and 240 lines fill the frame.
module framebuffer #(
    parameter WIDTH = 320,          // max frame width (<=1280)
    parameter HEIGHT = 240,         // max frame height (<=720)
    parameter COLOR_BITS = 4        // bits per RGB color channel
)(
	input clk,                      // megadrive clock
	input resetn,
	input clk_pixel,                // 54 MHz pixel clock (480p120)
	input clk_5x_pixel,             // 5x pixel clock (270 MHz)

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
    input sl_out,                   // core_config[21]: dark output rows instead of an integer scale
    input [31:0] video_config,      // colour controls, CRT mask and smoothing, see video_fx.v, smooth.v (the LCD grid is unused)

    input std_timing,               // 1: standard 858-line 480p120, 0: native line (858 here; see hdmi.sv)

    input [15:0] audio_left,        // audio sample
    input [15:0] audio_right,

	// HDMI output signals
	output       tmds_clk_n,
	output       tmds_clk_p,
	output [2:0] tmds_d_n,
	output [2:0] tmds_d_p
);

localparam CLKFRQ = 54000;

// video stuff
wire [10:0] cx /* xsynthesis syn_keep=1 */;
wire [9:0] cy  /* xsynthesis syn_keep=1 */;

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

// BRAM port B read
reg [$clog2(WIDTH)-1:0] xx  /* xsynthesis syn_keep=1 */; // scaled-down pixel position
reg [$clog2(HEIGHT)-1:0] yy /* xsynthesis syn_keep=1 */;
reg [7:0] yy_s;             // source line to show (scanlines.v picks it for the integer scale)
reg [7:0] yb_s;             // the neighbour line to blend it with (smooth.v)
wire sm_rd_b;               // smooth.v: this clock reads the neighbour line, not the line to show
wire [1:0] sm_mode;         // smooth.v: the smoothing of this frame, 0 off, 1 sharp, 2 soft
wire [23:0] sm_rgb;         // the smoothed picture
always @(posedge clk_pixel) begin
    mem_portB_rdata <= mem[mem_portB_addr];
end

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
wire [1:0] bfi_mode_eff = (bfi_cfg == 2'd3) ? 2'd1 : bfi_cfg;
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
            if (bfi_mode_eff != 2'd0) begin
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
// Nearest neighbour; smooth.v blends the source pixels (video_config[19:18]). For that the
// line buffer is read twice per source column, the line to show and its neighbour line.
//
wire [23:0] rgb;            // actual RGB output
reg [23:0] rgb_pre;         // before video_fx
reg pic_pre;                // rgb_pre is a pixel of the picture, not the border or the overlay
reg dark_pre;
reg active                  /* xsynthesis syn_keep=1 */;
reg [10:0] xcnt             /* xsynthesis syn_keep=1 */;
reg [10:0] ycnt             /* xsynthesis syn_keep=1 */;                  // fractional scaling counters
reg [9:0] cy_r;

// scanlines: sl_geom frames are scaled 3 rows per source line
// The LCD grid (video_config[15]) is not offered on the Mega Drive: 960 or 896 output columns
// for 256 or 320 source pixels is not a whole number of columns per pixel. Bit 15 is cleared
// for video_fx and cfg_grid is tied low, so the picture geometry never depends on it, and
// the grid flags are tied low.
wire sl_geom, sl_show, sl_dark, sl_last;
wire [7:0] sl_yy;
wire [1:0] sl_dk;
wire [7:0] lines = height >= 10'd232 ? 8'd240 : 8'd224;     // lines of the picture
sl_rows sl (
    .clk(clk_pixel), .cy(cy),
    .cfg_on(scanlines), .cfg_dark(sl_darkness), .cfg_thick(sl_thick), .cfg_out(sl_out),
    .cfg_grid(1'b0), .hide(overlay),
    .rows(3'd2), .dark_thin(3'd1), .dark_thick(3'd1),
    .lines(lines), .top(height >= 10'd232 ? 10'd0 : 10'd16),
    .geom(sl_geom), .pic_top(sl_pic_top), .yy(sl_yy), .show(sl_show), .dark(sl_dark), .last(sl_last), .darkness(sl_dk)
);
always @(posedge clk_pixel) yy_s <= sl_geom ? sl_yy : yy;

wire [7:0] xx_ov;           // xx, SM_LAT clocks old
assign overlay_x = xx_ov;
assign overlay_y = yy_s;
// Integer 2x, centred in 720. 320 -> 640 (starts at 40), 256 -> 512 (starts at 104).
wire [11:0] XSIZE  = {width, 1'b0};
wire [11:0] XSTART = (12'd720 - XSIZE) >> 1;
wire [11:0] XSTOP  = (12'd720 + XSIZE) >> 1;

// both source lines of a blend come from the bank HDMI is showing
wire [7:0] ysel = sm_rd_b ? yb_s : yy_s;
assign mem_portB_addr = (rd_bank ? FB_FRAME[17:0] : 18'd0) + ysel * 18'd320 + {9'd0, xx};

// address calculation
// Assume the video occupies fully on the Y direction, we are upscaling the video by `480/height`.
// xcnt and ycnt are fractional scaling counters.
// video_fx follows rgb_pre with FX_LAT register stages. Its first stage is the one that sl_dim
// used to be (active started at XSTART - 2 then), so active starts FX_LAT - 1 clocks earlier
// than that, at XSTART - 1 - FX_LAT. The smoothing is between the line buffer and rgb_pre:
// rgb_pre comes SM_LAT clocks later than the line buffer read alone would give it, so active
// starts SM_LAT clocks earlier still. The xx/xcnt counters, and so the line buffer read, run
// with it; the overlay lookup address (xx_ov) and `active` are delayed back by SM_LAT, so the
// picture, the overlay and the border land where they did. The source line (yy_s) only changes
// at the start of an output row, far from the picture, so which line is read on which row does
// not move.
localparam FX_LAT = 11;     // clocks from rgb_pre to rgb, see video_fx.v
localparam SM_LAT = 9;      // the line buffer read is followed by a register, smooth.v (LAT 8) and the rgb_pre register
reg cnew = 1'b0;            // the line buffer address is the first of a source column
always @(posedge clk_pixel) begin
    reg active_t;
    reg [10:0] xcnt_next;
    reg [10:0] ycnt_next;
    xcnt_next = xcnt + (overlay ? 256 : width);
    ycnt_next = ycnt + (overlay ? 224 : height);

    active_t = 0;
    if ({1'b0, cx} == XSTART - 12'd1 - FX_LAT - SM_LAT) begin
        active_t = 1;
        active <= 1;
    end else if ({1'b0, cx} == XSTOP - 12'd1 - FX_LAT - SM_LAT) begin
        active_t = 0;
        active <= 0;
    end

    // the first source column starts with the first pixel, the others when xx changes (there is
    // no column after the last one: the line buffer row ends there)
    cnew <= ({1'b0, cx} == XSTART - 12'd2 - FX_LAT - SM_LAT)
          | ((active_t | active) & (xcnt_next >= XSIZE) & ({2'b00, xx} != width - 11'd1));

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
        if (ycnt_next >= 480) begin
            ycnt <= ycnt_next - 480;
            if (yy != lines - 8'd1)        // blanking keeps showing the last line
                yy <= yy + 1;
        end
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

// xx and active, delayed by SM_LAT
reg [8*SM_LAT-1:0] xx_sh;
reg [SM_LAT-1:0] act_sh;
always @(posedge clk_pixel) begin
    xx_sh <= {xx_sh[8*SM_LAT-9:0], xx[7:0]};
    act_sh <= {act_sh[SM_LAT-2:0], active};
end
assign xx_ov = xx_sh[8*SM_LAT-1 -: 8];
wire active_d = act_sh[SM_LAT-1];

// The weights of the blend, from the same counters (smooth.v). Horizontally the output pixel
// is `width` of the XSIZE units of a source pixel, vertically `height` of 480.
localparam [16:0] KX_STEP_320 = (65536 * 256 + 320 / 2) / 320;
localparam [16:0] KX_HALF_640 = (65536 * 128 + 640 / 2) / 640;
localparam [16:0] KX_HALF_512 = (65536 * 128 + 512 / 2) / 512;
localparam [16:0] KY_STEP_224 = (65536 * 256 + 224 / 2) / 224;
localparam [16:0] KY_STEP_240 = (65536 * 256 + 240 / 2) / 240;
localparam [16:0] KY_HALF = (65536 * 128 + 480 / 2) / 480;
wire [7:0] wx, wy_ax;
wire hnext, vnext_ax;
smooth_axis ax (
    .clk(clk_pixel), .mode(sm_mode), .pos(xcnt), .step(width), .size(XSIZE),
    .k_step(width == 11'd320 ? KX_STEP_320 : 17'd65536), .k_half(XSIZE == 12'd512 ? KX_HALF_512 : KX_HALF_640),
    .first(xx == 9'd0), .last({2'b00, xx} == width - 11'd1), .w(wx), .next(hnext)
);
smooth_axis ay (
    .clk(clk_pixel), .mode(sm_mode), .pos(ycnt), .step({1'b0, height}), .size(12'd480),
    .k_step(height == 10'd240 ? KY_STEP_240 : KY_STEP_224), .k_half(KY_HALF),
    .first(yy_s == 8'd0), .last(yy_s == lines - 8'd1), .w(wy_ax), .next(vnext_ax)
);

// Scanline frames show 2 rows per source line: soft blends each row halfway
// towards its neighbour. Sharp has nothing to blend, the rows are whole.
reg sl_last_p, sl_show_p;           // the previous output row
always @(posedge clk_pixel)
    if (cy[0] != cy_r[0]) begin
        sl_last_p <= sl_last;
        sl_show_p <= sl_show;
    end
localparam [7:0] W_HALF = 8'd128;  // round(256 / 2)
wire row_first = ~sl_show_p | sl_last_p;
wire geom_blend = (sm_mode == 2'd2) & ((row_first & (yy_s != 8'd0)) | (sl_last & (yy_s != lines - 8'd1)));
wire [7:0] wy = sl_geom ? (geom_blend ? W_HALF : 8'd0) : wy_ax;
wire vnext = sl_geom ? sl_last : vnext_ax;
// Smoothing off does not use the neighbour, but smooth.v still subtracts it:
// an unread line is X, and X times weight 0 is X, which blanks the pixel.
// Read the line being shown so a just-in-time line fill stays defined.
always @(posedge clk_pixel)
    if (sm_mode == 2'd0)
        yb_s <= yy_s;
    else
        yb_s <= vnext ? ((yy_s == lines - 8'd1) ? yy_s : yy_s + 8'd1)
                      : ((yy_s == 8'd0) ? yy_s : yy_s - 8'd1);

// the line buffer read as RGB8, and the first-of-column flag with it
reg [23:0] pal_q;
reg cn1, cn2;
always @(posedge clk_pixel) begin
    pal_q <= {mem_portB_rdata[COLOR_BITS*2 +: COLOR_BITS], {(8-COLOR_BITS){1'b0}},
              mem_portB_rdata[COLOR_BITS   +: COLOR_BITS], {(8-COLOR_BITS){1'b0}},
              mem_portB_rdata[0            +: COLOR_BITS], {(8-COLOR_BITS){1'b0}}};    // RGB4 to RGB8
    cn1 <= cnew;
    cn2 <= cn1;
end

smooth sm (
    .clk(clk_pixel), .cy(cy), .cfg(video_config[19:18]), .mode(sm_mode),
    .rd_b(sm_rd_b), .rd_rgb(pal_q), .col_new(cn2), .wx(wx), .hnext(hnext), .wy(wy),
    .rgb_out(sm_rgb)
);

// In an inserted BFI refresh the whole picture (border included) is black or
// half brightness. The menu overlay is exempt, so the menu stays steady.
wire bfi_eff_ins = bfi_ins ^ bfi_phase;
wire bfi_dark = bfi_eff_ins & (bfi_mode_eff != 2'd0) & ~overlay;
reg [23:0] rgb_norm;
always @* begin
    if (active_d & sl_show) begin
        if (overlay)
            rgb_norm = {overlay_color[4:0],3'b0,overlay_color[9:5],3'b0,overlay_color[14:10],3'b0};       // BGR5 to RGB8
        else
            rgb_norm = sm_rgb;
    end else
        rgb_norm = 24'h303030;
end
always @(posedge clk_pixel) begin
    if (!bfi_dark)
        rgb_pre <= rgb_norm;
    else if (bfi_mode_eff == 2'd1)
        rgb_pre <= 24'h000000;
    else
        rgb_pre <= {1'b0, rgb_norm[23:17], 1'b0, rgb_norm[15:9], 1'b0, rgb_norm[7:1]};
    pic_pre <= active_d & sl_show & ~overlay & ~bfi_dark;
    dark_pre <= active_d & sl_show & ~overlay & sl_dark & ~bfi_dark;
end

// colour controls, the scanline darkening and the CRT mask
video_fx fx (
    .clk(clk_pixel), .cx(cx), .cy(cy), .video_config({video_config[31:16], 1'b0, video_config[14:0]}),
    .rgb_in(rgb_pre), .pic_in(pic_pre), .dark_in(dark_pre), .darkness(sl_dk),
    .col_last_in(1'b0), .row_last_in(1'b0),
    .rgb_out(rgb)
);

// HDMI output.
logic[2:0] tmds;

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

endmodule
