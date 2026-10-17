// VDP field lengths and the halt lock with the real vdp.v + the real
// framebuffer_sync.sv (issue #47).
// Programs R1/R12 through the CPU bus, then counts HV_VCNT steps between
// FIELD edges (lines per field), pause_core halts per field, and the game
// rate in fields/second over the run:
//   NTSC progressive : 262/field, locked to HDMI (one halt per field, ~59.93)
//   NTSC interlace   : 262/263 alternating, free-run (no halts, ~59.81)
//   PAL progressive  : 313/field (informational: longer than HDMI, stalls)
//   PAL interlace    : 312/313 alternating, free-run (~50.24)
// +PAL=1 selects PAL, +ILACE=1 interlace mode 1 (R12 bit 1), +DRES=1
// interlace mode 2 (R12 bits 2:1), +V30=1 the 240-line mode (R1 bit 3),
// +NOGATE=1 models mdtang_top.sv without the interlace free-run gate
// (shows the full-frame stall the gate exists to avoid).
`timescale 1ns/1ps

module tb_vdp_lock;
    reg clk_sys = 0, clk_pixel = 0;
    always #9.286 clk_sys = ~clk_sys;              // 53.846 MHz
    always #6.734 clk_pixel = ~clk_pixel;          // 74.25 MHz

    integer ilace = 0, dres = 0, pal_i = 0, v30 = 0, nogate = 0;
    initial begin
        if ($value$plusargs("ILACE=%d", ilace)) ;
        if ($value$plusargs("DRES=%d", dres)) ;
        if ($value$plusargs("PAL=%d", pal_i)) ;
        if ($value$plusargs("V30=%d", v30)) ;
        if ($value$plusargs("NOGATE=%d", nogate)) ;
    end

    reg rst_n = 0;

    // ---- CPU bus (register writes) --------------------------------------
    reg sel = 0, rnw = 1;
    reg [4:0] abus = 0;
    reg [15:0] di = 0;
    wire [15:0] dobus;
    wire dtack_n;

    // ---- VRAM stubs (combinational ack, zero data) -----------------------
    wire vram_req, vram_we, vram_u_n, vram_l_n, vram32_req;
    wire vram_ack, vram32_ack;
    wire [15:1] vram_a, vram32_a;
    wire [15:0] vram_d;
    wire [31:0] vram32_q = 0;
    assign vram_ack = vram_req;
    assign vram32_ack = vram32_req;

    // ---- VBUS stubs ------------------------------------------------------
    wire [23:1] vbus_addr;
    wire vbus_sel;
    wire [15:0] vbus_data = 0;
    wire vbus_dtack_n = 0;

    wire ce_pix, hblank, vblank, hsync, vsync;
    wire [3:0] r, g, b;
    wire field_out, interlace;
    wire [1:0] resolution;
`ifdef BASE_VDP
    // pre-fix vdp.v has no INTERLACE_ANY output: the old top never gated
    wire interlace_any = 1'b0;
`else
    wire interlace_any;
`endif
    wire hbl_sig, vbl_sig;
    reg ce = 0;

    vdp dut (
        .RST_N(rst_n), .CLK(clk_sys), .CE(ce),
        .SEL(sel), .A(abus), .RNW(rnw), .DI(di), .DO(dobus), .DTACK_N(dtack_n),
        .vram_req(vram_req), .vram_ack(vram_ack), .vram_we(vram_we),
        .vram_a(vram_a), .vram_d(vram_d), .vram_q(16'd0),
        .vram_u_n(vram_u_n), .vram_l_n(vram_l_n),
        .vram32_req(vram32_req), .vram32_ack(vram32_ack),
        .vram32_a(vram32_a), .vram32_q(vram32_q),
        .EXINT(), .HL(1'b1), .HINT(), .VINT_TG68(), .VINT_T80(), .INTACK(1'b0),
        .BR_N(), .BG_N(1'b1), .BGACK_N(),
        .VBUS_ADDR(vbus_addr), .VBUS_DATA(vbus_data),
        .VBUS_SEL(vbus_sel), .VBUS_DTACK_N(vbus_dtack_n),
        .PAL(pal_i[0]),
        .CE_PIX(ce_pix), .FIELD_OUT(field_out), .INTERLACE(interlace),
`ifndef BASE_VDP
        .INTERLACE_ANY(interlace_any),
`endif
        .RESOLUTION(resolution),
        .HBL(hbl_sig), .VBL(vbl_sig),
        .R(r), .G(g), .B(b), .HS(hsync), .VS(vsync),
        .SVP_QUIRK(1'b0), .VRAM_SPEED(1'b0), .VSCROLL_BUG(1'b0),
        .BORDER_EN(1'b0), .CRAM_DOTS(1'b0), .OBJ_LIMIT_HIGH_EN(1'b0),
        .TRANSP_DETECT(),
        .BGA_EN(1'b1), .BGB_EN(1'b1), .SPR_EN(1'b1),
        .dbg_in(8'd0), .dbg_out()
    );

    // ---- mdtang_top.sv x/y counters --------------------------------------
    reg ce_pix_r = 0, hblank_r = 0, hsync_seen = 0;
    reg [8:0] x = 0;
    reg [7:0] y = 0;
    always @(posedge clk_sys) begin
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

    // ---- the real scaler --------------------------------------------------
    wire pause_core;
    wire [2:0] tmds_d_p, tmds_d_n;
    wire tmds_clk_p, tmds_clk_n;
    reg [15:0] aud = 0;
    always @(posedge clk_sys) aud <= aud + 1;
    framebuffer #(.WIDTH(320), .HEIGHT(240), .COLOR_BITS(4)) fb (
        .clk(clk_sys), .resetn(rst_n), .clk_pixel(clk_pixel), .clk_5x_pixel(1'b0),
        .ce_pix(ce_pix & hsync_seen),
        .r({y[3:0]}), .g(y[4:1]), .b(x[7:4]), .x(x), .y(y),
        .width(resolution[0] ? 320 : 256), .height(resolution[1] ? 240 : 224),
        .pause_core(pause_core),
        .std_timing(1'b0),
        .overlay(1'b0), .overlay_x(8'd0), .overlay_y(8'd0), .overlay_color(15'd0),
        .scanlines(1'b0), .sl_darkness(2'd0), .sl_thick(1'b0), .sl_out(1'b0),
        .video_config(32'd0),
        .audio_left(aud), .audio_right(aud),
        .tmds_clk_n(tmds_clk_n), .tmds_clk_p(tmds_clk_p),
        .tmds_d_n(tmds_d_n), .tmds_d_p(tmds_d_p)
    );

    // ---- mdtang_top.sv PAUSE_EN: (pause_core & ~interlaced_any) | menu ----
    // (menu pause is off in this bench; +NOGATE=1 keeps the old behaviour)
    always @(posedge clk_sys) begin
        if (!rst_n)
            ce <= 0;
        else if (nogate != 0)
            ce <= ~pause_core;
        else
            ce <= ~(pause_core & ~interlace_any);
    end

    // ---- register write: DI = 10_RRRRR_VVVVVVVV to the control port -------
    task reg_write(input [4:0] regnum, input [7:0] value);
        begin
            @(posedge clk_sys);
            sel = 1; rnw = 0; abus = 5'b00100; di = {2'b10, 1'b0, regnum, value};
            while (dtack_n) @(posedge clk_sys);
            @(posedge clk_sys);
            sel = 0; rnw = 1;
            while (!dtack_n) @(posedge clk_sys);
        end
    endtask

    // ---- measurement -------------------------------------------------------
    integer field_count = 0;
    integer line_steps = 0;
    integer field_lines[0:15];
    reg [8:0] vcnt_prev = 0;
    reg field_prev = 0;
    realtime t_first = 0, t_last = 0;
    integer halts = 0;
    reg pause_prev = 0;
    realtime paused_at = 0;
    realtime wait_sum = 0;
    realtime wait_max = 0;
    integer i;
    integer fails = 0;

    always @(posedge clk_sys) begin
        if (rst_n && ce) begin
            if (dut.HV_VCNT !== vcnt_prev)
                line_steps = line_steps + 1;
            if (dut.FIELD !== field_prev) begin
                if (field_count < 16)
                    field_lines[field_count] = line_steps;
                if (field_count == 0)
                    t_first = $realtime;
                t_last = $realtime;
                field_count = field_count + 1;
                line_steps = 0;
            end
            if (pause_core && !pause_prev) begin
                halts = halts + 1;
                paused_at = $realtime;
            end
            if (!pause_core && pause_prev) begin
                wait_sum = wait_sum + ($realtime - paused_at);
                if ($realtime - paused_at > wait_max)
                    wait_max = $realtime - paused_at;
            end
            pause_prev = pause_core;
        end
        vcnt_prev = dut.HV_VCNT;
        field_prev = dut.FIELD;
    end

    initial begin
        #1;
        // reset, then program R1 (M5 + display + V30?) and R12 (H32 + LSM)
        #100;
        rst_n = 0; ce = 0;
        repeat (10) @(posedge clk_sys);
        rst_n = 1;
        repeat (5) @(posedge clk_sys);
        ce = 1;
        reg_write(5'd1, 8'h44 | (v30 != 0 ? 8'h08 : 8'h00));
        reg_write(5'd12, (dres != 0) ? 8'h06 : (ilace != 0) ? 8'h02 : 8'h00);
        // settle one field, measure the next 8, then report
        wait (field_count >= 9);
        $display("VDPLOCK pal=%0d ilace=%0d dres=%0d v30=%0d nogate=%0d:",
                 pal_i, ilace, dres, v30, nogate);
        for (i = 1; i < 9; i = i + 1) begin
            $display("  field %0d: %0d lines (want %0d)", i, field_lines[i],
                     want_lines(i));
            if (field_lines[i] !== want_lines(i)) begin
                $display("VDPLOCK FAIL field %0d", i);
                fails = fails + 1;
            end
        end
        $display("  halts: %0d in %0d fields, wait avg %0.1f us max %0.1f us",
                 halts, field_count - 1,
                 (wait_sum / 1000.0) / (halts == 0 ? 1 : halts), wait_max / 1000.0);
        $display("  game rate: %0.3f fields/s over %0.3f ms",
                 1e9 * (field_count - 1) / (t_last - t_first),
                 (t_last - t_first) / 1e6);
        if (fails != 0) $fatal(1, "tb_vdp_lock: FAIL");
        $display("tb_vdp_lock: PASS");
        $finish;
    end

    // expected lines for measured field i (1..8: index 0 is the partial
    // reset field; odd indices are FIELD=1 odd fields). BASE_VDP (pre-fix)
    // is flat 262/313 everywhere except the NTSC-V30 no-reload quirk (512).
    function integer want_lines(input integer idx);
        integer base;
        begin
            base = (v30 != 0 && pal_i == 0) ? 512 : (pal_i != 0 ? 313 : 262);
`ifdef BASE_VDP
            want_lines = base;
`else
            if ((ilace != 0 || dres != 0) && !(v30 != 0 && pal_i == 0)) begin
                if (pal_i != 0)
                    want_lines = (idx % 2) ? 313 : 312;   // PAL: odd longer
                else
                    want_lines = (idx % 2) ? 263 : 262;   // NTSC: odd longer
            end else
                want_lines = base;
`endif
        end
    endfunction

    initial begin
        #5000000000;
        $display("tb_vdp_lock: TIMEOUT after %0d fields", field_count);
        $fatal(1, "tb_vdp_lock: timeout");
    end
endmodule
