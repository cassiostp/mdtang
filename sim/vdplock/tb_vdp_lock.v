// Real VDP, programmed over its CPU bus, feeding the interlace capture,
// three-field store, scaler and native-rate halt lock. Count HV counter
// advances per field, and tag every stored pixel with field/line/column.
// During scanout each parity must have one epoch and the expected position;
// assert that the VDP never writes a bank owned by HDMI. PAL is not exposed
// by mdtang_top (Americas/NTSC), so the integrated suite tests NTSC modes.
`timescale 1ns/1fs

module tb_vdp_lock;
    reg clk_sys = 0, clk_pixel = 0;
    always #9.286 clk_sys = ~clk_sys;              // 53.846 MHz
`ifdef HZ120
    always #9.259259259 clk_pixel = ~clk_pixel;
`else
    always #6.734006734 clk_pixel = ~clk_pixel;
`endif

    integer ilace = 0, dres = 0, pal_i = 0, v30 = 0, nogate = 0, nf = 12;
    initial begin
        if ($value$plusargs("ILACE=%d", ilace)) ;
        if ($value$plusargs("DRES=%d", dres)) ;
        if ($value$plusargs("PAL=%d", pal_i)) ;
        if ($value$plusargs("V30=%d", v30)) ;
        if ($value$plusargs("NOGATE=%d", nogate)) ;
        if ($value$plusargs("NF=%d", nf)) ;
    end

    reg rst_n = 0;

    // ---- CPU bus (register writes) --------------------------------------
    reg sel = 0, rnw = 1;
    reg [4:0] abus = 0;
    reg [15:0] di = 0;
    wire [15:0] dobus;
    wire dtack_n;

    // ---- VRAM stubs (one-cycle ack, zero data) ---------------------------
    wire vram_req, vram_we, vram_u_n, vram_l_n, vram32_req;
    reg vram_ack_r = 0, vram32_ack_r = 0;
    wire vram_ack, vram32_ack;
    wire [15:1] vram_a, vram32_a;
    wire [15:0] vram_d;
    wire [31:0] vram32_q = 0;
    assign vram_ack = vram_ack_r;
    assign vram32_ack = vram32_ack_r;
    always @(posedge clk_sys) begin
        vram_ack_r <= vram_req;
        vram32_ack_r <= vram32_req;
    end

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
        .HBL(hblank), .VBL(vblank),
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
    wire [7:0] ovx, ovy;
    wire [2:0] tmds_d_p, tmds_d_n;
    wire tmds_clk_p, tmds_clk_n;
    reg [15:0] aud = 0;
    always @(posedge clk_sys) aud <= aud + 1;
    framebuffer #(.WIDTH(320), .HEIGHT(240), .COLOR_BITS(4)) fb (
        .clk(clk_sys), .resetn(rst_n), .clk_pixel(clk_pixel), .clk_5x_pixel(1'b0),
        .hblank(hblank), .vblank(vblank), .ce_pix(ce_pix & (interlace_any | hsync_seen)),
        .r({y[3:0]}), .g(y[4:1]), .b(x[7:4]), .x(x), .y(y),
        .width(resolution[0] ? 320 : 256), .height(resolution[1] ? 240 : 224),
        .pause_core(pause_core),
        .interlace(interlace_any), .double_res(interlace), .field(field_out), .std_timing(1'b0),
        .overlay(1'b0), .overlay_x(ovx), .overlay_y(ovy), .overlay_color(15'd0),
        .scanlines(1'b0), .sl_darkness(2'd0), .sl_thick(1'b0), .sl_out(1'b0),
        .video_config(32'd0),
        .audio_left(aud), .audio_right(aud),
        .tmds_clk_n(tmds_clk_n), .tmds_clk_p(tmds_clk_p),
        .tmds_d_n(tmds_d_n), .tmds_d_p(tmds_d_p)
    );

    // Halt every field; the HDMI cadence changes with interlace.
    always @(posedge clk_sys) ce <= rst_n && !pause_core;

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
    integer field_lines[0:63];
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
    integer paused_clks = 0, total_clks = 0;

    always @(posedge clk_sys) begin
        if (rst_n && ce) begin
            if (dut.HV_VCNT !== vcnt_prev)
                line_steps = line_steps + 1;
            if (dut.FIELD !== field_prev) begin
                if (field_count < 64)
                    field_lines[field_count] = line_steps;

                field_count = field_count + 1;
                line_steps = 0;
            end
            if (pause_core && !pause_prev) begin
                halts = halts + 1;
                paused_at = $realtime;
                if (halts <= 40)
                    $display("  halt %0d at %0.3f ms (FIELD=%0d HV_VCNT=%0d)",
                             halts, $realtime / 1e6, dut.FIELD, dut.HV_VCNT);
            end
            if (!pause_core && pause_prev) begin
                wait_sum = wait_sum + ($realtime - paused_at);
                if ($realtime - paused_at > wait_max)
                    wait_max = $realtime - paused_at;
                if (halts <= 40)
                    $display("  release %0d after %0.1f us",
                             halts, ($realtime - paused_at) / 1000.0);
            end
            pause_prev = pause_core;
        end
        vcnt_prev = dut.HV_VCNT;
        field_prev = dut.FIELD;
    end

    always @(posedge clk_sys) begin
        if (rst_n) begin
            total_clks = total_clks + 1;
            if (!ce)
                paused_clks = paused_clks + 1;
        end
    end

    integer reads = 0, pubs = 0;
    reg [1:0] prev_even = 0, prev_odd = 1;
    reg [1:0] valid_prev = 0;
    reg [1:0] owner_even, owner_odd;
    integer epoch = 0;
    integer tags [0:230399];
    integer lines_written [0:230399];
    integer cols_written [0:230399];
    reg parity_written [0:230399];
    integer read_epoch [0:1];
    reg read_seen [0:1];
    reg ce_r = 0;
    always @(posedge clk_sys) begin
        ce_r <= fb.ce_pix;
        if (interlace_any && fb.ilace_write) begin
            if (fb.ilace_y == 0 && fb.ilace_x == 0) epoch = epoch + 1;
            if (fb.ilace_valid != 0 && fb.ilace_pixel &&
                (fb.ilace_wr_bank == fb.ilace_bank_even || fb.ilace_wr_bank == fb.ilace_bank_odd))
                $fatal(1, "writer owns an HDMI bank");
            tags[fb.mem_portA_addr] = epoch;
            lines_written[fb.mem_portA_addr] = fb.ilace_y;
            cols_written[fb.mem_portA_addr] = fb.ilace_x;
            parity_written[fb.mem_portA_addr] = field_out;
        end

    end
    integer a, rp, rl;
    always @(posedge clk_pixel) begin
        if (fb.cx == 0 && fb.cy == 0) begin read_seen[0] = 0; read_seen[1] = 0; end
        if (fb.ilace_bank_even != prev_even || fb.ilace_bank_odd != prev_odd) begin
            if (fb.cy != 0 || fb.cx > 2) $fatal(1, "bank changed during scanout");
            pubs = pubs + 1;
        end
        prev_even <= fb.ilace_bank_even; prev_odd <= fb.ilace_bank_odd;
        if (field_count > 5 && interlace_any && fb.ilace_ready && fb.active && fb.pic_show && fb.cy < fb.FRAMEHEIGHT && fb.xx < 256) begin
            a = fb.mem_portB_addr;
            rp = interlace ? fb.weave_line[0] : 0;
            rl = interlace ? fb.weave_line[8:1] : fb.yy_s;
            if (!read_seen[rp]) begin read_seen[rp] = 1; read_epoch[rp] = tags[a]; end
            if (tags[a] != read_epoch[rp] || lines_written[a] != rl || cols_written[a] != fb.xx ||
                (interlace && parity_written[a] != rp))
                $fatal(1, "torn/stale weave at %0d,%0d addr=%0d line=%0d wanted=%0d parity=%0d wanted=%0d epoch=%0d wanted=%0d",fb.cx,fb.cy,a,lines_written[a],rl,parity_written[a],rp,tags[a],read_epoch[rp]);
            reads = reads + 1;
        end
    end
    initial begin
        #100;
        repeat (8) @(posedge clk_sys);
        rst_n = 1;
        repeat (8) @(posedge clk_sys);
        reg_write(1, 8'h44 | (v30 ? 8'h08 : 8'h00));
        reg_write(12, dres ? 8'h06 : ilace ? 8'h02 : 8'h00);
        wait (field_count >= 5);
        t_first = $realtime;
        wait (field_count >= nf + 5);
        t_last = $realtime;
        $display("mode PAL=%0d ILACE=%0d DRES=%0d V30=%0d fields=%0d halts=%0d pubs=%0d reads=%0d rate=%0.9f",pal_i,ilace,dres,v30,field_count,halts,pubs,reads,nf*1e9/(t_last-t_first));
        for (i = 5; i < nf+5; i = i+1) begin
            $display("field %0d: %0d lines",i,field_lines[i]);
            if (ilace || dres) begin
                if (field_lines[i] != (pal_i ? 312 : 262) && field_lines[i] != (pal_i ? 313 : 263)) $fatal(1,"field length");
                if (field_lines[i] == field_lines[i-1]) $fatal(1,"fields do not alternate");
            end else if (field_lines[i] != (pal_i ? 313 : 262)) $fatal(1,"progressive length");
        end
        if (ilace || dres) begin
            if (nf*1e9/(t_last-t_first) < 59.8084 || nf*1e9/(t_last-t_first) > 59.8089) $fatal(1,"wrong locked rate");
            if (reads < 1000 || pubs < nf-2) $fatal(1,"missing weave/publications");
        end
        $display("tb_vdp_lock: PASS");
        $finish;
    end
    initial begin #2000000000; $fatal(1,"watchdog"); end
endmodule
