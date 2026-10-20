// The filters running inside the Mega Drive scaler. For a list of settings, the pixels that go
// into video_fx (rgb_pre and its flags) and the pixels that come out, FX_LAT clocks later, are
// logged with the output position, on a set of rows across the frame; model.py check compares
// each one with the golden model, so the CRT mask lands on the right output columns and rows, the
// scanline darkening comes after the colour, and the border and the overlay are left alone.
// Also checked here on every clock: the picture flag is set exactly for the pixels that are not
// the border colour, and never while the overlay is up (the picture holds no pixel of the border
// colour). One simulation is one frame size, +W=256|320 +H=224|240, and writes md_fx_WxH.log.
`timescale 1ns/1ps

module tb_md_fx;

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
        .hblank(1'b0), .vblank(1'b0), .interlace(1'b0), .double_res(1'b0), .field(1'b0), .std_timing(1'b0),
        .overlay(ov), .overlay_x(ovx), .overlay_y(ovy), .overlay_color(ovc),
        .scanlines(sl_on), .sl_darkness(sl_dark), .sl_thick(sl_thick), .sl_out(sl_out),
        .video_config(vcfg),
        .audio_left(16'd0), .audio_right(16'd0),
        .tmds_clk_n(tmds_clk_n), .tmds_clk_p(tmds_clk_p), .tmds_d_n(tmds_d_n), .tmds_d_p(tmds_d_p)
    );

    integer i;
    reg [31:0] h;
    reg [11:0] pix;
    initial begin
        #1;
        dut.pause_prog = 1'b0;                  // the VDP side is not played here
        h = 32'h7654321;
        for (i = 0; i < 320 * 32; i = i + 1) begin
            h = h * 1664525 + 1013904223;
            pix = h[29:18];
            if (pix == 12'h333) pix = 12'h334;  // 0x303030 is the border colour: keep it out of the picture
            dut.mem[i] = pix;
        end
    end

    // what went into video_fx FX_LAT clocks ago: {darkness, dark, pic, rgb}
    reg [27:0] hist [0:15];
    reg [27:0] now_in, old_in;
    integer logging = 0, nlog = 0, nbad_pic = 0, k;
    integer fd;
    reg     in_row;
    always @(negedge clk_pixel) begin
        now_in = {dut.sl_dk, dut.dark_pre, dut.pic_pre, dut.rgb_pre};
        old_in = hist[FX_LAT - 1];
        for (k = 15; k > 0; k = k - 1) hist[k] = hist[k - 1];
        hist[0] = now_in;
        // the border colour and the picture flag
        if (logging && dut.pic_pre !== (dut.rgb_pre !== 24'h303030 && !ov)) begin
            nbad_pic = nbad_pic + 1;
            if (nbad_pic <= 5)
                $display("pic flag %b with rgb_pre=%h overlay=%b at cx=%0d cy=%0d", dut.pic_pre, dut.rgb_pre, ov, dut.cx, dut.cy);
        end
        in_row = (dut.cy % 100 < 4) && dut.cy < 10'd720 && dut.cy >= 10'd40;
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
            logging = 1;
            wait_row730;
            logging = 0;
            $display("md_fx %0dx%0d on=%b out=%b thick=%b darkness=%0d overlay=%b video_config=%h logged", W, H, on, out, thick, dk, over, cfg);
        end
    endtask

    initial begin
        #1;
        fd = $fopen($sformatf("md_fx_%0dx%0d.log", w_arg, h_arg), "w");
        wait_row730;
        //    on out thk dk ov  video_config
        frame(0, 0, 0, 0, 0, 3'd2 | (3'd7 << 3) | (3'd2 << 6) | (2'd3 << 9));                // colour only
        frame(0, 0, 0, 0, 0, (2'd1 << 11) | (2'd2 << 13));                                   // aperture grille
        frame(1, 0, 0, 1, 0, (2'd2 << 11) | (2'd3 << 13));                                   // slot mask + scanlines
        frame(1, 1, 1, 2, 0, (2'd3 << 11) | (2'd1 << 13) | 3'd5);                            // dot mask, output rows, brightness -3
        frame(1, 0, 0, 3, 0, (3'd4 << 6) | (2'd1 << 9) | (2'd1 << 11));                      // greyscale + gamma + 100 % scanlines
        frame(0, 0, 0, 0, 1, 32'h0001_FFFF);                                                 // overlay: untouched
        frame(1, 0, 1, 2, 0, 32'h0003_8000 | 3'd1 | (3'd3 << 3) | (3'd6 << 6) | (2'd2 << 9) | (2'd3 << 11));  // grid bit: ignored
        frame(0, 0, 0, 0, 0, 32'h0001_2000);                                                 // firmware "off"
        $fclose(fd);
        if (nbad_pic != 0 || nlog == 0) begin
            $display("tb_md_fx: FAIL (%0d picture flag errors, %0d pixels logged)", nbad_pic, nlog);
            $fatal(1, "tb_md_fx: FAIL");
        end
        $display("tb_md_fx %0dx%0d: %0d pixels logged, picture flag ok", W, H, nlog);
        $finish;
    end

    initial begin
        #2000000000000;
        $fatal(1, "tb_md_fx: timeout");
    end
endmodule
