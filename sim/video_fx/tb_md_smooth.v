// The smoothing running inside the Mega Drive scaler (video_config[19:18]). The line buffer holds
// a pseudo-random picture, which is dumped (md_src_WxH.hex) for the model. For a list of settings
// the pixels that go into video_fx (rgb_pre and its flags) and the pixels that come out, FX_LAT
// clocks later, are logged with their output position on a set of rows across the frame (the top
// and bottom rows, and every 13th); model.py check_smooth compares each one with the golden model:
// which source pixels are blended and with what weights, in both modes and both geometries, the
// border and the overlay left alone, the filters and the scanline darkening acting on the smoothed
// picture. One simulation is one frame size, +W=256|320 +H=224|240, and writes md_smooth_WxH.log.
`timescale 1ns/1ps

module tb_md_smooth;

    localparam FX_LAT = 11;

    reg clk_pixel = 0, clk = 0;
    always #6.734 clk_pixel = ~clk_pixel;       // 74.25 MHz
    always #9.3 clk = ~clk;                     // 53.7 MHz

    integer w_arg, h_arg;
    reg [10:0] W;
    reg  [9:0] H;
    initial begin
        if (!$value$plusargs("W=%d", w_arg)) w_arg = 320;
        if (!$value$plusargs("H=%d", h_arg)) h_arg = 224;
        W = w_arg; H = h_arg;
    end

    reg        sl_on = 0, sl_thick = 0, sl_out = 0, ov = 0;
    reg  [1:0] sl_dark = 0;
    reg [31:0] vcfg = 0;

    wire [7:0] ovx, ovy;
    reg [14:0] ovc, ovc1;
    function [14:0] ov_pix(input [7:0] x, input [7:0] y);
        ov_pix = {x[4:0] ^ y[6:2], x[7:3] + y[4:0], y[7:3] ^ x[6:2]};
    endfunction
    always @(posedge clk_pixel) begin
        ovc1 <= ov_pix(ovx, ovy); ovc <= ovc1;
    end

    wire [2:0] tmds_d_p, tmds_d_n;
    wire       tmds_clk_p, tmds_clk_n;

    framebuffer #(.WIDTH(320), .HEIGHT(240), .COLOR_BITS(4)) dut (
        .clk(clk), .resetn(1'b1), .clk_pixel(clk_pixel), .clk_5x_pixel(1'b0),
        .ce_pix(1'b0), .r(4'd0), .g(4'd0), .b(4'd0), .x(9'd0), .y(8'd0),
        .width(W), .height(H),
        .std_timing(1'b0),
        .overlay(ov), .overlay_x(ovx), .overlay_y(ovy), .overlay_color(ovc),
        .scanlines(sl_on), .sl_darkness(sl_dark), .sl_thick(sl_thick), .sl_out(sl_out),
        .video_config(vcfg),
        .audio_left(16'd0), .audio_right(16'd0),
        .tmds_clk_n(tmds_clk_n), .tmds_clk_p(tmds_clk_p), .tmds_d_n(tmds_d_n), .tmds_d_p(tmds_d_p)
    );

    integer i;
    reg [31:0] h;
    initial begin
        #1;
        dut.pause_core = 1'b0;                  // the VDP side is not played here
        h = 32'h7654321;
        for (i = 0; i < 320 * 32; i = i + 1) begin
            h = h * 1664525 + 1013904223;
            dut.mem[i] = h[29:18];
        end
        $writememh($sformatf("md_src_%0dx%0d.hex", w_arg, h_arg), dut.mem);
    end

    // what went into video_fx FX_LAT clocks ago: {darkness, dark, pic, rgb}
    reg [27:0] hist [0:15];
    reg [27:0] now_in, old_in;
    integer logging = 0, nlog = 0, k;
    integer fd;
    reg     in_row;
    always @(negedge clk_pixel) begin
        now_in = {dut.sl_dk, dut.dark_pre, dut.pic_pre, dut.rgb_pre};
        old_in = hist[FX_LAT - 1];
        for (k = 15; k > 0; k = k - 1) hist[k] = hist[k - 1];
        hist[0] = now_in;
        in_row = dut.cy < 10'd720 && (dut.cy < 10'd30 || dut.cy >= 10'd690 || dut.cy % 13 == 0);
        if (logging && in_row && dut.cx < 11'd1280) begin
            $fwrite(fd, "%h %0d %0d %0d %0d %0d 0 0 %h %h\n", vcfg, dut.cx, dut.cy,
                    old_in[24], old_in[25], old_in[27:26], old_in[23:0], dut.rgb);
            nlog = nlog + 1;
        end
    end

    task wait_row730;
        begin
            while (dut.cy == 10'd730) @(posedge clk_pixel);
            while (dut.cy != 10'd730) @(posedge clk_pixel);
        end
    endtask

    // one frame with these settings, logged
    task frame(input on, input out, input thick, input [1:0] dk, input over, input [31:0] cfg);
        begin
            sl_on = on; sl_out = out; sl_thick = thick; sl_dark = dk; ov = over; vcfg = cfg;
            wait_row730;
            $fwrite(fd, "F %0d %0d %0d %0d %0d %h %0d %0d\n", on, out, thick, dk, over, cfg, w_arg, h_arg);
            logging = 1;
            wait_row730;
            logging = 0;
            $display("md_smooth %0dx%0d on=%b out=%b thick=%b darkness=%0d overlay=%b video_config=%h logged", W, H, on, out, thick, dk, over, cfg);
        end
    endtask

    localparam [31:0] SHARP = 32'h1 << 18, SOFT = 32'h2 << 18, RSVD = 32'h3 << 18;
    localparam [31:0] FX = 3'd2 | (3'd7 << 3) | (3'd2 << 6) | (2'd3 << 9) | (2'd2 << 11) | (2'd1 << 13);   // colour + slot mask

    initial begin
        #1;
        fd = $fopen($sformatf("md_smooth_%0dx%0d.log", w_arg, h_arg), "w");
        wait_row730;
        //    on out thk dk ov  video_config
        frame(0, 0, 0, 0, 0, 32'h0);                       // off: the model's convention is the scaler's
        frame(1, 0, 0, 0, 0, 32'h0);
        frame(0, 0, 0, 0, 0, RSVD);                        // reserved = off
        frame(0, 0, 0, 0, 0, SHARP);                       // 960x720
        frame(0, 0, 0, 0, 0, SOFT);
        frame(1, 0, 0, 1, 0, SHARP);                       // integer scale, 896x672 (224 lines) or 960x720
        frame(1, 0, 1, 2, 0, SOFT | 32'h0001_2000);
        frame(1, 1, 0, 2, 0, SHARP);                       // output rows, 960x720
        frame(1, 1, 1, 1, 0, SOFT);
        frame(0, 0, 0, 0, 0, SHARP | FX);                  // with the other filters
        frame(1, 0, 0, 1, 0, SOFT | FX);
        frame(1, 1, 1, 3, 0, SHARP | 32'h0001_5A91);
        frame(0, 0, 0, 0, 1, SHARP | FX);                  // menu overlay up: untouched
        frame(1, 0, 0, 2, 1, SOFT);
        frame(0, 0, 0, 0, 0, SHARP);                       // and back
        $fclose(fd);
        if (nlog == 0) begin
            $display("tb_md_smooth %0dx%0d: FAIL (nothing logged)", W, H);
            $fatal(1, "tb_md_smooth: FAIL");
        end
        $display("tb_md_smooth %0dx%0d: %0d pixels logged", W, H, nlog);
        $finish;
    end

    initial begin
        #2000000000000;
        $fatal(1, "tb_md_smooth: timeout");
    end
endmodule
