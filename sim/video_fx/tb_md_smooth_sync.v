// The smoothing reads two lines of the line buffer while the VDP is still filling it. This plays
// the VDP side with its real timing and the scaler's real frame sync: a line is 3420 clk cycles
// (320 or 256 active pixels of 8 or 10 clk, then the blanking), 262 lines per frame, the
// x / y counters and the write enable are those of mdtang_top.sv, and the core stops while
// pause_core is set. Every read of the line buffer that the picture uses, the line to show and
// its neighbour (when the blend weight is not 0), must find the pixel it wants: written in
// this frame, as that line and column, and not yet overwritten by the line 32 later.
// The VDP clock is 0.1 % fast, so the core waits at the sync point for the HDMI side to reach
// the first row of the picture, as it is meant to. +LATE=us (default 0) holds the core that long
// after its release and cuts the same time off the blanking of its frame: the lines it writes
// afterwards come that much later after the release, as when it reaches the sync point late and
// is released at once (hdmi_first_line is high for the rest of the row, 20 us).
// One simulation is one frame size, +W=256|320 +H=224|240; it runs smoothing off, sharp and
// soft in every scanline mode, and prints how early the neighbour line is written.
`timescale 1ns/1ps

module tb_md_smooth_sync;

    reg clk_pixel = 0, clk = 0;
    always #6.734 clk_pixel = ~clk_pixel;       // 74.25 MHz
    always #9.29 clk = ~clk;                    // 53.8 MHz, 0.1 % faster than a 60 Hz frame needs

    integer w_arg, h_arg;
    integer late_arg;
    reg [10:0] W;
    reg  [9:0] H;
    initial begin
        if (!$value$plusargs("W=%d", w_arg)) w_arg = 320;
        if (!$value$plusargs("H=%d", h_arg)) h_arg = 224;
        if (!$value$plusargs("LATE=%d", late_arg)) late_arg = 0;
        W = w_arg; H = h_arg;
    end

    reg        sl_on = 0, sl_thick = 0, sl_out = 0, ov = 0;
    reg  [1:0] sl_dark = 0;
    reg [31:0] vcfg = 0;
    wire       pause_core;

    wire [7:0] ovx, ovy;
    wire [2:0] tmds_d_p, tmds_d_n;
    wire       tmds_clk_p, tmds_clk_n;

    // ---- the VDP side -------------------------------------------------------------------
    localparam LINE = 3420, LINES_FRAME = 262;
    integer pix;                                // clk cycles per pixel: 8 (H40) or 10 (H32)
    integer lc = 0, ln = 0;                     // clk cycle in the line, line in the frame (0 = the dummy line)
    reg     hblank = 1, vblank = 1, hsync = 0, ce_pix = 0;
    integer frame = 0;                          // frame counter, increments when vblank ends
    integer late_left = 0;                      // clk cycles the core is still held after its release
    reg     pause_prev = 0;
    always @(posedge clk) begin
        pix = (W == 320) ? 8 : 10;
        pause_prev <= pause_core;
        if (pause_prev && !pause_core) late_left = late_arg * 537 / 10;     // 53.7 clk cycles per us
        if (late_left > 0) late_left = late_left - 1;
        if (!pause_core && late_left == 0) begin
            lc = lc + 1;
            if (ln == LINES_FRAME - 1 && lc == LINE - late_arg * 537 / 10 - 1) lc = LINE - 1;
            if (lc == LINE) begin
                lc = 0;
                ln = ln + 1;
                if (ln == LINES_FRAME) ln = 0;
            end
            // line 0: 15 dummy pixels with vblank already low, then the blanking; lines 1..H: the picture
            vblank <= (ln > H);
            if (ln == 0 && lc == 0) frame <= frame + 1;
            hblank <= (ln == 0) ? (lc >= 15 * pix) : (lc >= 256 * 10);
            hsync  <= (lc >= 2700 && lc < 2900);
            ce_pix <= (lc % pix == 0) && (lc < 2560);
        end else begin
            ce_pix <= 0;
        end
    end

    // the counters of mdtang_top.sv
    reg ce_pix_r, hblank_r, hsync_seen = 0;
    reg [8:0] x = 0;
    reg [7:0] y = 0;
    always @(posedge clk) begin
        ce_pix_r <= ce_pix;
        if (vblank) begin
            y <= 0;
            hsync_seen <= 0;
        end
        if (hsync)
            hsync_seen <= 1;
        hblank_r <= hblank;
        if (hsync_seen) begin
            if (ce_pix & ~ce_pix_r & ~hblank & ~vblank)
                x <= x + 1;
            if (hblank) begin
                x <= 0;
                if (!hblank_r)
                    y <= y + 1;
            end
        end
    end

    reg [3:0] pr, pg, pb;
    always @(posedge clk) begin pr <= x[3:0] + y[3:0]; pg <= y[4:1]; pb <= x[7:4]; end

    framebuffer #(.WIDTH(320), .HEIGHT(240), .COLOR_BITS(4)) dut (
        .clk(clk), .resetn(1'b1), .clk_pixel(clk_pixel), .clk_5x_pixel(1'b0),
        .ce_pix(ce_pix & hsync_seen), .r(pr), .g(pg), .b(pb), .x(x), .y(y),
        .width(W), .height(H), .pause_core(pause_core),
        .overlay(ov), .overlay_x(ovx), .overlay_y(ovy), .overlay_color(15'd0),
        .scanlines(sl_on), .sl_darkness(sl_dark), .sl_thick(sl_thick), .sl_out(sl_out),
        .video_config(vcfg),
        .audio_left(16'd0), .audio_right(16'd0),
        .tmds_clk_n(tmds_clk_n), .tmds_clk_p(tmds_clk_p), .tmds_d_n(tmds_d_n), .tmds_d_p(tmds_d_p)
    );
    initial begin
        #1;
        dut.pause_core = 1'b0;
    end

    // ---- what was written where ----------------------------------------------------------
    // per line buffer entry: the frame, the line and the column of the last pixel written
    // (valid only for a pixel of the picture: not the blanking, not a column past the line), and when
    reg        t_ok   [0:32*320-1];
    integer    t_frame[0:32*320-1];
    integer    t_line [0:32*320-1];
    integer    t_col  [0:32*320-1];
    realtime   t_time [0:32*320-1];
    integer    i;
    initial for (i = 0; i < 32 * 320; i = i + 1) begin t_ok[i] = 0; t_frame[i] = -1; t_line[i] = -1; t_col[i] = -1; t_time[i] = 0; end
    always @(posedge clk) begin
        if (dut.ce_pix & ~dut.ce_pix_r) begin
            t_ok[dut.mem_portA_addr]    = ~hblank & ~vblank & (x < W);
            t_frame[dut.mem_portA_addr] = frame;
            t_line[dut.mem_portA_addr]  = y;
            t_col[dut.mem_portA_addr]   = x;
            t_time[dut.mem_portA_addr]  = $realtime;
        end
    end

    // ---- the reads -----------------------------------------------------------------------
    integer exp_frame = 0;
    reg     checking = 0;
    integer n_a = 0, n_b = 0, n_b_dn = 0, n_b_up = 0, bad = 0, bad_total = 0, n_total = 0;
    realtime slack, min_a, min_b_dn, min_b_up;
    integer pic_top;
    reg     used;
    wire    b_read = dut.sm_rd_b;
    reg     [7:0] want_line;
    integer lead, max_lead = 0;                 // how many lines the VDP is ahead of the line read
    always @(posedge clk_pixel) begin
        pic_top = dut.sl_pic_top;
        if (dut.cy == pic_top && dut.cx == 11'd100)
            exp_frame = frame;
        // reads of the picture: inside the window, of a column that exists, of a row that shows it
        used = checking && dut.active && !ov && dut.sl_show && dut.cy < 10'd720 && ({2'b00, dut.xx} < W)
               && (!b_read || (dut.sm_mode != 2'd0 && dut.wy != 8'd0));
        if (used) begin
            want_line = dut.ysel;
            if (!t_ok[dut.mem_portB_addr] || t_frame[dut.mem_portB_addr] != exp_frame
                || t_line[dut.mem_portB_addr] != want_line || t_col[dut.mem_portB_addr] != dut.xx) begin
                bad = bad + 1;
                if (bad <= 10)
                    $display("UNWRITTEN %0dx%0d cfg=%h sl=%b/%b cy=%0d cx=%0d: read line %0d (shown %0d) col %0d (%s): found ok=%b frame %0d (want %0d) line %0d col %0d",
                             W, H, vcfg, sl_on, sl_out, dut.cy, dut.cx, want_line, dut.yy_s, dut.xx, b_read ? "neighbour" : "shown",
                             t_ok[dut.mem_portB_addr], t_frame[dut.mem_portB_addr], exp_frame,
                             t_line[dut.mem_portB_addr], t_col[dut.mem_portB_addr]);
            end else begin
                lead = y - want_line;
                if (lead > max_lead) max_lead = lead;
                slack = $realtime - t_time[dut.mem_portB_addr];
                if (!b_read) begin
                    n_a = n_a + 1;
                    if (n_a == 1 || slack < min_a) min_a = slack;
                end else if (dut.yb_s > dut.yy_s) begin
                    n_b_dn = n_b_dn + 1;
                    if (n_b_dn == 1 || slack < min_b_dn) min_b_dn = slack;
                end else begin
                    n_b_up = n_b_up + 1;
                    if (n_b_up == 1 || slack < min_b_up) min_b_up = slack;
                end
            end
        end
    end

    // how long the core waits for the release, per frame
    realtime paused_at, wait_min = 1e12, wait_max = 0, wait_t;
    integer  waits = 0;
    reg      pause_r = 0;
    always @(posedge clk) begin
        pause_r <= pause_core;
        if (pause_core && !pause_r) paused_at = $realtime;
        if (!pause_core && pause_r) begin
            wait_t = $realtime - paused_at;
            waits = waits + 1;
            if (wait_t < wait_min) wait_min = wait_t;
            if (wait_t > wait_max) wait_max = wait_t;
        end
    end

    task wait_row730;
        begin
            while (dut.cy == 10'd730) @(posedge clk_pixel);
            while (dut.cy != 10'd730) @(posedge clk_pixel);
        end
    endtask

    // frames with these settings: two to settle, three checked
    task variant(input on, input out, input thick, input [1:0] dk, input [31:0] cfg);
        begin
            sl_on = on; sl_out = out; sl_thick = thick; sl_dark = dk; vcfg = cfg;
            checking = 0;
            wait_row730; wait_row730; wait_row730;
            bad = 0; n_a = 0; n_b = 0; n_b_dn = 0; n_b_up = 0; max_lead = 0; waits = 0; wait_min = 1e12; wait_max = 0;
            checking = 1;
            wait_row730; wait_row730; wait_row730;
            checking = 0;
            bad_total = bad_total + bad;
            n_total = n_total + n_a + n_b_dn + n_b_up;
            $display("sync %0dx%0d on=%b out=%b video_config=%h: %0d shown + %0d below + %0d above reads, %0d bad; min write-to-read %0.0f ns (shown), %0.0f ns (below), %0.0f ns (above); core up to %0d lines ahead; waited %0.1f..%0.1f us for the release",
                     W, H, on, out, cfg, n_a, n_b_dn, n_b_up, bad,
                     min_a, (n_b_dn ? min_b_dn : 0.0), (n_b_up ? min_b_up : 0.0), max_lead, wait_min / 1000.0, wait_max / 1000.0);
            if (bad != 0 || n_a == 0)
                $display("FAIL: %0d reads of a pixel that was not there", bad);
        end
    endtask

    localparam [31:0] SHARP = 32'h1 << 18, SOFT = 32'h2 << 18;

    initial begin
        wait_row730; wait_row730;
        if (late_arg == 0)                      // (the sync of the smoothing off is the one before smoothing)
            variant(0, 0, 0, 0, 32'h0);
        variant(0, 0, 0, 0, SHARP);
        variant(0, 0, 0, 0, SOFT);
        variant(1, 0, 0, 1, SHARP);            // integer scale
        variant(1, 0, 0, 1, SOFT);
        variant(1, 1, 0, 1, SHARP);            // output rows
        variant(1, 1, 0, 1, SOFT);
        if (bad_total != 0 || n_total == 0) begin
            $display("tb_md_smooth_sync %0dx%0d: FAIL (%0d bad reads of %0d)", W, H, bad_total, n_total);
            $fatal(1, "tb_md_smooth_sync: FAIL");
        end
        $display("tb_md_smooth_sync %0dx%0d: PASS, %0d line buffer reads, every one found its pixel", W, H, n_total);
        $finish;
    end

    initial begin
        #2000000000000;
        $fatal(1, "tb_md_smooth_sync: timeout");
    end
endmodule
