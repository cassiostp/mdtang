// Frame lock at the native Genesis rate (sim/framelock).
// Real framebuffer_sync.sv against a VDP-side model with the real timing: a
// line is 3420 clk cycles (320 or 256 active pixels of 8 or 10 clk, then the
// blanking), 262 lines per frame, the x / y counters and the write enable are
// those of mdtang_top.sv, and the core stops while pause_core is set. One
// simulation is one frame size, +W=256|320 +H=224|240.
// Standard variant: the 1652-clock native HDMI line (59.9274 Hz); hz120
// variant (-DHZ120): the 858-clock 480p120 line (119.8801 Hz, game 59.9401 Hz).
// Checks:
//  - the locked HDMI frame is exactly one native line x 750 (standard) or
//    858x525 (hz120) pixel clocks, stable across the run;
//  - the core waits at the sync point every frame (steady wait band) and
//    re-locks within 2 frames of a menu pause and a core reset;
//  - every line-buffer read of the picture finds its pixel written in this
//    frame (no tearing): the single read per source column must land after
//    the VDP wrote the line and before it is overwritten (hz120: the bank on
//    screen is a finished field, so one frame id and one field parity per
//    refresh means the two banks are not mixed);
//  - the audio sample holds while the core is paused (the frame-sync halt
//    must hold, never inject silence) and advances otherwise, with a small
//    max repeat at the HDMI audio clock.
// Interlace (+ILACE=1 mode 1, +DRES=1 double-res mode 2): the core's field
// is always 3420x262 clocks (V_TOTAL_HEIGHT has no interlace term) and the
// top drops FIELD/INTERLACE, so the scaler sees each field as a progressive
// frame of H lines; in double-res the two fields carry alternate rows of
// the 2*H-line picture. The model then toggles a field parity per field
// (encoded in the pixel data for +DRES) and the read check also requires
// the current field's parity, with exactly one halt per field while locked.
// +WSWITCH=1 / +HSWITCH=1 toggle the 256/320 width or the 224/240 height
// at a halt (as a vblank register write lands) and back, forgiving the
// transition HDMI frames' reads (hz120: six, the full frame buffer keeps
// showing the pre-switch field until the first post-switch field completes;
// a height switch moves the pause point ~1 ms, so one release misses its
// even-frame slot); waits and period stay checked throughout (hz120 allows
// two out-of-band halts on height-switch runs).
// Interlace/switch runs use a short scenario (lock + settled fields); the
// pause/reset re-lock is covered by the progressive runs.
// +SL_OUT=1 runs the scaler at Full scale (standard default: Full only for
// height switches, whose Integer picture top moves; hz120 default: Integer).
`timescale 1ns/1ps

module tb_frame_lock;

    reg clk_pixel = 0, clk = 0;
`ifdef HZ120
    always #9.259 clk_pixel = ~clk_pixel;       // 54 MHz (480p120)
`else
    always #6.734 clk_pixel = ~clk_pixel;       // 74.25 MHz
`endif
    always #9.286 clk = ~clk;                   // 53.846 MHz (50 x 28 / 26)

    integer w_arg, h_arg;
    integer ilace = 0, dres = 0, wswitch = 0, hswitch = 0, sl_out_arg = -1;
    reg [10:0] W;
    reg  [9:0] H;
    reg  short_mode = 0;
    initial begin
        if (!$value$plusargs("W=%d", w_arg)) w_arg = 320;
        if (!$value$plusargs("H=%d", h_arg)) h_arg = 224;
        if (!$value$plusargs("ILACE=%d", ilace)) ilace = 0;
        if (!$value$plusargs("DRES=%d", dres)) dres = 0;
        if (!$value$plusargs("WSWITCH=%d", wswitch)) wswitch = 0;
        if (!$value$plusargs("HSWITCH=%d", hswitch)) hswitch = 0;
        if (!$value$plusargs("SL_OUT=%d", sl_out_arg)) sl_out_arg = -1;
        W = w_arg; H = h_arg;
        short_mode = (ilace != 0) || (dres != 0) || (wswitch != 0) || (hswitch != 0);
    end
    reg field_par = 0;                          // interlace field parity (toggles per field)
    reg forgive = 0;                            // mode switch: skip read checks this HDMI frame

    reg menu_pause = 0;                         // menu pause: the whole machine holds (PAUSE_EN)
    reg core_reset = 0;                         // core reset: the VDP counters restart
    reg [31:0] vcfg = 32'h0;
`ifdef HZ120
    // Integer scale unless +SL_OUT=1 asks for Full.
    wire sl_out_tb = (sl_out_arg < 0) ? 1'b0 : sl_out_arg[0];
`else
    // A height switch moves the Integer picture top (row 24 for 224 lines, row 0
    // for 240): the first full frame in the new mode tears at the top while the
    // halt re-phases (one frame; the waits return to the steady band after).
    // The switch runs use Full scale instead (the firmware default), whose top
    // stays at row 0; the progressive runs above keep Integer scale.
    // +SL_OUT= overrides this (0 Integer, 1 Full).
    wire sl_out_tb = (sl_out_arg < 0) ? (hswitch != 0) : sl_out_arg[0];
`endif
    wire pause_core;

    wire [7:0] ovx, ovy;
    wire [2:0] tmds_d_p, tmds_d_n;
    wire       tmds_clk_p, tmds_clk_n;

    // ---- the VDP side -------------------------------------------------------------
    localparam LINE = 3420, LINES_FRAME = 262;
`ifdef HZ120
    localparam NATIVE_HTOTAL = 858, NATIVE_VTOTAL = 525;
`else
    localparam NATIVE_HTOTAL = 1652, NATIVE_VTOTAL = 750;
`endif
    integer pix;
    integer lc = 0, ln = 0;
    reg     hblank = 1, vblank = 1, hsync = 0, ce_pix = 0;
    integer frame = 0;
    reg     pause_prev = 0;
    always @(posedge clk) begin
        pix = (W == 320) ? 8 : 10;
        pause_prev <= pause_core;
        if (core_reset) begin
            lc = 0; ln = 0;
            field_par <= 0;
            hblank <= 1; vblank <= 1; hsync <= 0; ce_pix <= 0;
        end else if (!pause_core && !menu_pause) begin
            lc = lc + 1;
            if (lc == LINE) begin
                lc = 0;
                ln = ln + 1;
                if (ln == LINES_FRAME) ln = 0;
            end
            vblank <= (ln > H);
            if (ln == 0 && lc == 0) begin
                frame <= frame + 1;
                field_par <= ~field_par;
            end
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
        if (core_reset) begin
            x <= 0; y <= 0;
            ce_pix_r <= 0; hblank_r <= 0; hsync_seen <= 0;
        end else begin
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
    end

    // audio model: the DAC value advances only while the machine runs, as the
    // fixed system.sv does (PSG/FM/Z80 halt with PAUSE_EN, holding the sample)
    reg [15:0] aud = 0;
    always @(posedge clk) begin
        if (core_reset)
            aud <= 0;
        else if (!pause_core && !menu_pause)
            aud <= aud + 1;
    end

    reg [3:0] pr, pg, pb;
    always @(posedge clk) begin
        pr <= x[3:0] + y[3:0]; pg <= y[4:1];
        pb <= dres ? {field_par, x[7:5]} : x[7:4];   // double-res: the field is in the pixel
    end

    framebuffer #(.WIDTH(320), .HEIGHT(240), .COLOR_BITS(4)) dut (
        .clk(clk), .resetn(1'b1), .clk_pixel(clk_pixel), .clk_5x_pixel(1'b0),
        .ce_pix(ce_pix & hsync_seen), .r(pr), .g(pg), .b(pb), .x(x), .y(y),
        .width(W), .height(H), .pause_core(pause_core),
        .hblank(1'b0), .vblank(1'b0), .interlace(1'b0), .double_res(1'b0), .field(1'b0), .std_timing(1'b0),
        .overlay(1'b0), .overlay_x(ovx), .overlay_y(ovy), .overlay_color(15'd0),
        .scanlines(1'b0), .sl_darkness(2'd0), .sl_thick(1'b0), .sl_out(sl_out_tb),
        .video_config(vcfg),
        .audio_left({aud[15:1], 1'b0}), .audio_right({aud[15:1], 1'b0}),
        .tmds_clk_n(tmds_clk_n), .tmds_clk_p(tmds_clk_p), .tmds_d_n(tmds_d_n), .tmds_d_p(tmds_d_p)
    );
    initial begin
        #1;
        dut.pause_prog = 1'b0;
        // the HDMI audio divider has no reset (hardware recovers in < 1 ms);
        // give the sim a clean start so the audio-word repeat check sees edges
        dut.clk_audio = 1'b0;
        dut.audio_divider = 0;
    end

    // ---- what was written where -----------------------------------------------------
`ifdef HZ120
    localparam FB_WORDS = 2 * 320 * 240;
`else
    localparam FB_WORDS = 32 * 320;
`endif
    reg        t_ok   [0:FB_WORDS-1];
    integer    t_frame[0:FB_WORDS-1];
    integer    t_line [0:FB_WORDS-1];
    integer    t_col  [0:FB_WORDS-1];
    reg        t_par  [0:FB_WORDS-1];
    realtime   t_time [0:FB_WORDS-1];
    integer    i;
    initial for (i = 0; i < FB_WORDS; i = i + 1) begin t_ok[i] = 0; t_frame[i] = -1; t_line[i] = -1; t_col[i] = -1; t_par[i] = 0; t_time[i] = 0; end
`ifdef HZ120
    // y==240 is the pause row and is not stored. 240*320 aliases the other
    // bank's pixel 0, so a shadow write there would hide a real pixel.
    always @(posedge clk) begin
        if (dut.ce_pix & ~dut.ce_pix_r && y < 8'd240) begin
`else
    always @(posedge clk) begin
        if (dut.ce_pix & ~dut.ce_pix_r) begin
`endif
            t_ok[dut.mem_portA_addr]    = ~hblank & ~vblank & (x < W);
            t_frame[dut.mem_portA_addr] = frame;
            t_line[dut.mem_portA_addr]  = y;
            t_col[dut.mem_portA_addr]   = x;
            t_par[dut.mem_portA_addr]   = field_par;
            t_time[dut.mem_portA_addr]  = $realtime;
        end
    end

    // ---- the reads --------------------------------------------------------------------
    integer exp_frame = 0;
    reg     exp_par = 0;
    reg     checking = 0;
    integer n_read = 0, bad = 0, bad_total = 0;
    realtime rd_age, rd_age_min = 1e12;         // write-to-read age of checked reads
    integer frame_w0 = 0;                       // field count at the window start
    reg     used;
    reg     [7:0] want_line;
`ifdef HZ120
    // The bank on screen is a finished field, not the one the VDP is
    // writing. One frame id and one field parity for the whole refresh
    // means the two banks are not mixed.
    reg     par_set = 0, par_seen = 0;
    integer frame_seen = 0;
    always @(posedge clk_pixel) begin
        if (dut.cx == 11'd0 && dut.cy == 10'd0)
            par_set = 0;
        used = checking && !forgive && dut.active && dut.sl_show && dut.cy < 10'd480 && ({2'b00, dut.xx} < W);
        if (used) begin
            want_line = dut.yy_s;
            n_read = n_read + 1;
            if (!par_set) begin
                par_seen = t_par[dut.mem_portB_addr];
                frame_seen = t_frame[dut.mem_portB_addr];
                par_set = 1;
            end
            if (!t_ok[dut.mem_portB_addr]
                || t_line[dut.mem_portB_addr] != want_line || t_col[dut.mem_portB_addr] != dut.xx
                || t_frame[dut.mem_portB_addr] != frame_seen
                || (((ilace != 0) || (dres != 0)) && t_par[dut.mem_portB_addr] != par_seen)) begin
                bad = bad + 1;
                if (bad <= 10)
                    $display("UNWRITTEN %0dx%0d cy=%0d cx=%0d: read line %0d col %0d: found ok=%b frame %0d (want %0d) line %0d col %0d par %b (want %b)",
                             W, H, dut.cy, dut.cx, want_line, dut.xx,
                             t_ok[dut.mem_portB_addr], t_frame[dut.mem_portB_addr], frame_seen,
                             t_line[dut.mem_portB_addr], t_col[dut.mem_portB_addr],
                             t_par[dut.mem_portB_addr], par_seen);
            end else begin
                rd_age = $realtime - t_time[dut.mem_portB_addr];
                if (rd_age < rd_age_min) rd_age_min = rd_age;
            end
        end
    end
`else
    always @(posedge clk_pixel) begin
        if (dut.cy == dut.sl_pic_top && dut.cx == 11'd100) begin
            exp_frame = frame;
            exp_par = field_par;
        end
        used = checking && !forgive && dut.active && dut.sl_show && dut.cy < 10'd720 && ({2'b00, dut.xx} < W);
        if (used) begin
            want_line = dut.yy_s;
            n_read = n_read + 1;
            if (!t_ok[dut.mem_portB_addr] || t_frame[dut.mem_portB_addr] != exp_frame
                || t_line[dut.mem_portB_addr] != want_line || t_col[dut.mem_portB_addr] != dut.xx
                || (((ilace != 0) || (dres != 0)) && t_par[dut.mem_portB_addr] != exp_par)) begin
                bad = bad + 1;
                if (bad <= 10)
                    $display("UNWRITTEN %0dx%0d cy=%0d cx=%0d: read line %0d col %0d: found ok=%b frame %0d (want %0d) line %0d col %0d par %b (want %b)",
                             W, H, dut.cy, dut.cx, want_line, dut.xx,
                             t_ok[dut.mem_portB_addr], t_frame[dut.mem_portB_addr], exp_frame,
                             t_line[dut.mem_portB_addr], t_col[dut.mem_portB_addr],
                             t_par[dut.mem_portB_addr], exp_par);
            end else begin
                rd_age = $realtime - t_time[dut.mem_portB_addr];
                if (rd_age < rd_age_min) rd_age_min = rd_age;
            end
        end
    end
`endif

    // ---- the halt: wait per frame -------------------------------------------------------
    // steady band: free 60.0935 Hz vs HDMI 59.9274 Hz -> ~46 us/frame
    // (hz120: free 60.0935 Hz vs two 480p120 frames at 59.9401 Hz -> ~43 us).
    // pre-lock transients (a ~0 us coincidental release, one full-frame wait)
    // can only happen before the phase locks; the scenario awaits lock before
    // checking, so the checked windows admit no forgiveness.
    realtime paused_at, wait_min = 1e12, wait_max = 0, wait_t;
    integer  waits = 0;
    reg      pause_r = 0;
    localparam real WAIT_LO = 10.0, WAIT_HI = 150.0;   // us
    integer wait_viol = 0;
    reg ok1 = 0, ok2 = 0;                         // last two waits in band (lock detector)
    reg last_ok = 0;
    always @(posedge clk) begin
        pause_r <= pause_core;
        if (pause_core && !pause_r) paused_at = $realtime;
        if (!pause_core && pause_r) begin
            wait_t = $realtime - paused_at;
            waits = waits + 1;
            if (wait_t < wait_min) wait_min = wait_t;
            if (wait_t > wait_max) wait_max = wait_t;
            last_ok = (wait_t >= WAIT_LO * 1000.0 && wait_t <= WAIT_HI * 1000.0);
            ok2 <= ok1;
            ok1 <= last_ok;
            $display("wait #%0d: %0.1f us %s (VDP frame %0d, HDMI %0dx%0d, time %0d)",
                     waits, wait_t / 1000.0, last_ok ? "ok" : "OUT", frame, dut.cx, dut.cy, $time);
            if (checking && !last_ok) begin
                wait_viol = wait_viol + 1;
                $display("WAIT %0.1f us outside %0.0f..%0.0f us (wait #%0d, time %0d)", wait_t / 1000.0, WAIT_LO, WAIT_HI, waits, $time);
            end
        end
    end

    // ---- the HDMI frame period ------------------------------------------------------------
    // hdmi_frames counts every frame regardless of checking, so the scenario
    // can wait on it; the period is verified only while checking.
    integer hdmi_frames = 0;
    integer pix_clks = 0;
    integer frames_seen = 0;
    integer period_viol = 0;
`ifdef HZ120
    localparam integer NATIVE_PERIOD = NATIVE_HTOTAL * NATIVE_VTOTAL;   // 858*525 = 450450
`else
    localparam integer NATIVE_PERIOD = NATIVE_HTOTAL * NATIVE_VTOTAL;   // 1239000
`endif
    always @(posedge clk_pixel) begin
        pix_clks = pix_clks + 1;
        if (dut.cx == 11'd0 && dut.cy == 10'd0) begin
            hdmi_frames = hdmi_frames + 1;
            if (checking) begin
                frames_seen = frames_seen + 1;
                if (frames_seen > 1 && pix_clks != NATIVE_PERIOD) begin
                    period_viol = period_viol + 1;
                    $display("PERIOD %0d pixel clocks, want %0d (frame #%0d)", pix_clks, NATIVE_PERIOD, frames_seen);
                end
            end
            pix_clks = 0;
        end
    end

    // ---- audio: the sample holds while paused ----------------------------------------------
    // Sampled on the falling sys clock, when every nonblocking update has
    // settled (sampling on the rising edge would race the release edge and
    // report the first advancing sample as a hold failure). The halt and the
    // release each advance the pipeline by a cycle or two (the enables gate
    // the next slot, like the real system.sv); only a sustained advance
    // while paused is a failure, so the first 4 paused cycles are forgiven.
    reg [15:0] last_latch = 0;
    reg        latch_init = 0;
    integer    aud_change_while_paused = 0;
    integer    paused_for = 0;
    reg [15:0] last_word = 0;
    integer    run = 0, max_run = 0;
    reg        aud_clk_prev = 0;
    integer    aud_words = 0, aud_x = 0;
    always @(negedge clk) begin
        if (pause_core || menu_pause)
            paused_for <= paused_for + 1;
        else
            paused_for <= 0;
        if (checking && latch_init && paused_for > 4 && (pause_core || menu_pause)) begin
            if (dut.audio_sample_word[0] !== last_latch) begin
                aud_change_while_paused = aud_change_while_paused + 1;
                if (aud_change_while_paused <= 10)
                    $display("AUDIO changed while paused: %h -> %h", last_latch, dut.audio_sample_word[0]);
            end
        end
        last_latch <= dut.audio_sample_word[0];
        latch_init <= 1;
    end
    always @(posedge clk_pixel) begin
        if (checking && !core_reset) begin
            // A pause (frame-sync halt or menu) holds the sample by design;
            // repeats across a pause are not a stuck sample, so the max-run
            // check below only counts repeats while the machine runs. Holds
            // are still checked by aud_change_while_paused above.
            if (pause_core || menu_pause) begin
                run = 1;
            end else if (dut.clk_audio && !aud_clk_prev) begin
                aud_words = aud_words + 1;
                if (dut.audio_sample_word[0] === 16'hxxxx || dut.audio_sample_word[0] !== dut.audio_sample_word[0]) begin
                    aud_x = aud_x + 1;
                end else if (aud_words > 1 && dut.audio_sample_word[0] === last_word) begin
                    run = run + 1;
                end else begin
                    if (run > max_run) max_run = run;
                    run = 1;
                    last_word = dut.audio_sample_word[0];
                end
            end
            aud_clk_prev <= dut.clk_audio;
        end
    end

    // ---- scenario ---------------------------------------------------------------------------
    task wait_hdmi_frames(input integer n);
        integer f0;
        begin
            f0 = hdmi_frames;
            while (hdmi_frames < f0 + n) @(posedge clk_pixel);
        end
    endtask

    // Await the lock: two consecutive in-band waits (the deterministic fixed
    // point; pre-lock transients can only precede it). Returns the HDMI
    // frames waited, or fails after 8 frames.
    task await_lock(output integer took);
        integer f0;
        begin
            // forget pre-event releases: the two in-band waits must be new
            ok1 = 0; ok2 = 0;
            took = 0;
            f0 = hdmi_frames;
            while (!(ok1 && ok2) && took < 8) begin
                wait_hdmi_frames(1);
                took = hdmi_frames - f0;
            end
            if (!(ok1 && ok2)) begin
                $display("FAIL: never locked in 8 frames");
                $fatal(1, "tb_frame_lock: FAIL");
            end
        end
    endtask

    integer lock_took = 0, relock_pause = 0, relock_reset = 0;

    task checkpoint(input [8*40-1:0] what, input integer max_new_bad, input integer max_new_wait);
        integer fields_w;
        begin
            fields_w = frame - frame_w0;
            $display("lock %0dx%0d %0s: %0d HDMI frames, %0d fields, %0d reads (min age %0.1f us), waits %0.1f..%0.1f us over %0d halts, audio max run %0d words",
                     W, H, what, frames_seen, fields_w, n_read, rd_age_min / 1000.0, wait_min / 1000.0, wait_max / 1000.0, waits, max_run);
            if (waits < fields_w - 1 || waits > fields_w + 1) begin
                $display("FAIL %0s: %0d halts for %0d fields (want one per field)", what, waits, fields_w);
                $fatal(1, "tb_frame_lock: FAIL");
            end
            if (bad > max_new_bad) begin
                $display("FAIL %0s: %0d bad reads", what, bad);
                $fatal(1, "tb_frame_lock: FAIL");
            end
            if (wait_viol > max_new_wait) begin
                $display("FAIL %0s: %0d waits outside the steady band", what, wait_viol);
                $fatal(1, "tb_frame_lock: FAIL");
            end
        end
    endtask

    initial begin
        #1;                                     // let the plusargs land first
        if (short_mode) begin
            // interlace / double-res / mode switch: lock, then settled fields
            checking = 0;
            await_lock(lock_took);
            $display("lock %0dx%0d ilace=%0d dres=%0d wswitch=%0d hswitch=%0d: locked after %0d HDMI frames",
                     W, H, ilace, dres, wswitch, hswitch, lock_took);
            checking = 1;
            frames_seen = 0;
            bad = 0; wait_viol = 0; period_viol = 0; waits = 0; wait_min = 1e12; wait_max = 0;
            n_read = 0; aud_change_while_paused = 0; max_run = 0; run = 0; aud_words = 0;
            frame_w0 = frame; rd_age_min = 1e12;
            wait_hdmi_frames(10);
            if (wswitch || hswitch) begin
                while (!pause_core) @(posedge clk);
                if (wswitch) W = (W == 320) ? 256 : 320;
                if (hswitch) H = (H == 224) ? 240 : 224;
                $display("mode switch to %0dx%0d at a halt", W, H);
`ifdef HZ120
                // The pre-switch field stays on screen until the first
                // post-switch field completes and swaps in. After a height
                // switch the pause point moves ~1 ms, so one release misses
                // its even-frame slot (a single ~15.7 ms halt, then locked
                // again); forgive the transition plus five refreshes.
                // Waits stay checked, with two out-of-band halts allowed
                // for the two height switches (see the checkpoint below).
                forgive = 1; wait_hdmi_frames(6); forgive = 0;
`else
                forgive = 1; wait_hdmi_frames(1); forgive = 0;
`endif
                wait_hdmi_frames(5);
                while (!pause_core) @(posedge clk);
                if (wswitch) W = (W == 320) ? 256 : 320;
                if (hswitch) H = (H == 224) ? 240 : 224;
                $display("mode switch back to %0dx%0d at a halt", W, H);
`ifdef HZ120
                forgive = 1; wait_hdmi_frames(6); forgive = 0;
`else
                forgive = 1; wait_hdmi_frames(1); forgive = 0;
`endif
                wait_hdmi_frames(5);
            end
            checking = 0;
`ifdef HZ120
            checkpoint("short-settled", 0, hswitch ? 2 : 0);
`else
            checkpoint("short-settled", 0, 0);
`endif
            if (period_viol != 0) begin $display("FAIL short-settled: %0d bad periods", period_viol); $fatal(1, "tb_frame_lock: FAIL"); end
            if (aud_change_while_paused != 0) begin $display("FAIL short-settled: audio moved while paused"); $fatal(1, "tb_frame_lock: FAIL"); end
            if (aud_x != 0) begin $display("FAIL short-settled: %0d X audio words", aud_x); $fatal(1, "tb_frame_lock: FAIL"); end
            if (max_run > 8) begin $display("FAIL short-settled: audio max run %0d > 8", max_run); $fatal(1, "tb_frame_lock: FAIL"); end
            $display("tb_frame_lock %0dx%0d ilace=%0d dres=%0d wswitch=%0d hswitch=%0d sl_out=%0d: PASS, %0d HDMI frames (lock %0d), audio words %0d max run %0d",
                     W, H, ilace, dres, wswitch, hswitch, sl_out_tb, hdmi_frames, lock_took, aud_words, max_run);
            $finish;
        end
        // startup: await the lock, then check 10 locked frames with no
        // forgiveness (pre-lock transients precede the lock by construction)
        checking = 0;
        await_lock(lock_took);
        $display("lock %0dx%0d startup: locked after %0d HDMI frames", W, H, lock_took);
        checking = 1;
        frames_seen = 0;
        bad = 0; wait_viol = 0; period_viol = 0; waits = 0; wait_min = 1e12; wait_max = 0;
        n_read = 0; aud_change_while_paused = 0; max_run = 0; run = 0; aud_words = 0;
        frame_w0 = frame; rd_age_min = 1e12;
        wait_hdmi_frames(10);
        checking = 0;
        checkpoint("settled", 0, 0);
        if (period_viol != 0) begin $display("FAIL settled: %0d bad periods", period_viol); $fatal(1, "tb_frame_lock: FAIL"); end
        if (aud_change_while_paused != 0) begin $display("FAIL settled: audio moved while paused"); $fatal(1, "tb_frame_lock: FAIL"); end

        // menu pause for 10 HDMI frames (phase preserved), then re-lock
        menu_pause = 1;
        wait_hdmi_frames(10);
        menu_pause = 0;
        await_lock(relock_pause);
        $display("lock %0dx%0d post-pause: re-locked after %0d HDMI frames", W, H, relock_pause);
        checking = 1;
        frames_seen = 0;
        bad = 0; wait_viol = 0; waits = 0; wait_min = 1e12; wait_max = 0; n_read = 0;
        frame_w0 = frame; rd_age_min = 1e12;
        wait_hdmi_frames(8);
        checking = 0;
        checkpoint("post-pause", 0, 0);
        if (aud_change_while_paused != 0) begin $display("FAIL post-pause: audio moved while paused"); $fatal(1, "tb_frame_lock: FAIL"); end

        // core reset: VDP counters restart with arbitrary phase, the lock
        // must come back, then 8 clean frames
        core_reset = 1;
        wait_hdmi_frames(2);
        core_reset = 0;
        #1;
        dut.pause_prog = 1'b0;
        await_lock(relock_reset);
        $display("lock %0dx%0d post-reset: re-locked after %0d HDMI frames", W, H, relock_reset);
        checking = 1;
        frames_seen = 0;
        bad = 0; wait_viol = 0; waits = 0; wait_min = 1e12; wait_max = 0; n_read = 0;
        frame_w0 = frame; rd_age_min = 1e12;
        wait_hdmi_frames(8);
        checking = 0;
        checkpoint("post-reset", 0, 0);

        bad_total = bad_total + bad;
        $display("tb_frame_lock %0dx%0d sl_out=%0d: PASS, %0d HDMI frames (lock %0d, relock pause %0d reset %0d), audio words %0d max run %0d, %0d X words, %0d pause changes",
                 W, H, sl_out_tb, hdmi_frames, lock_took, relock_pause, relock_reset, aud_words, max_run, aud_x, aud_change_while_paused);
        if (period_viol != 0 || aud_x != 0 || aud_change_while_paused != 0) begin
            $display("tb_frame_lock %0dx%0d: FAIL (period %0d, X %0d, pause-changes %0d)", W, H, period_viol, aud_x, aud_change_while_paused);
            $fatal(1, "tb_frame_lock: FAIL");
        end
        if (max_run > 8) begin
            $display("tb_frame_lock %0dx%0d: FAIL (audio max run %0d > 8)", W, H, max_run);
            $fatal(1, "tb_frame_lock: FAIL");
        end
        $finish;
    end

    initial begin
        #1000000000000;
        $fatal(1, "tb_frame_lock: timeout");
    end
endmodule
