// framebuffer_sync.sv (the Mega Drive scaler) with scanlines, whole frames: the HDMI
// part is a stub that counts cx/cy like the real one (hdmi_stub.v), the picture is the
// scaler's rgb output. The VDP side is played by the testbench: before each output row
// it puts the source line that row should show into the line buffer (standard) or the
// full frame (hz120), so a wrong source line shows up as a wrong colour.
// Checks, for each setting and for 256/320 x 224/240 frames, every output row of the
// frame against the model of src/scanlines.v: which source line it shows, border rows,
// dark rows and the darkened colour; the horizontal extent of the picture; and the row
// where the core is released to start a frame (hdmi_first_line).
// The hz120 variant additionally checks the BFI modes (video_config[21:20]), the
// overlay exemption, and dumps example frames (Full/Integer, scanlines on/off,
// menu open or not) to frames/.
// Fails with $fatal on the first mismatch.
// Variant: compile with -DHZ120 -I ../../src/variant/hz120 for the 480p120 build,
// without it (with -I ../../src/variant/standard) for the standard 720p build.
`timescale 1ns/1ps

module tb_md_scaler;

    reg clk_pixel = 0, clk = 0;
`ifdef HZ120
    always #9.259 clk_pixel = ~clk_pixel;       // 54 MHz
`else
    always #6.734 clk_pixel = ~clk_pixel;       // 74.25 MHz
`endif
    always #9.3 clk = ~clk;                     // 53.7 MHz

    reg        sl_on = 0, sl_thick = 0, sl_out = 0, ov = 0;
    reg  [1:0] sl_dark = 0;
    reg [31:0] vcfg = 0;
    reg [10:0] W = 256;
    reg  [9:0] H = 224;
    wire [7:0] overlay_x, overlay_y;
    reg [14:0] overlay_color = 15'b10101_01010_11100;   // BGR5
    wire [2:0] tmds_d_p, tmds_d_n;
    wire       tmds_clk_p, tmds_clk_n;
    wire       pause_core;

    framebuffer #(.WIDTH(320), .HEIGHT(240), .COLOR_BITS(4)) dut (
        .clk(clk), .resetn(1'b1), .clk_pixel(clk_pixel), .clk_5x_pixel(1'b0),
        .ce_pix(1'b0), .r(4'd0), .g(4'd0), .b(4'd0), .x(9'd0), .y(8'd0),
        .width(W), .height(H), .pause_core(pause_core),
        .interlace(1'b0), .double_res(1'b0), .field(1'b0), .std_timing(1'b0),
        .overlay(ov), .overlay_x(overlay_x), .overlay_y(overlay_y), .overlay_color(overlay_color),
        .scanlines(sl_on), .sl_darkness(sl_dark), .sl_thick(sl_thick), .sl_out(sl_out), .video_config(vcfg),
        .audio_left(16'd0), .audio_right(16'd0),
        .tmds_clk_n(tmds_clk_n), .tmds_clk_p(tmds_clk_p), .tmds_d_n(tmds_d_n), .tmds_d_p(tmds_d_p)
    );
    initial dut.pause_prog = 1'b0;

    // what the HDMI sink would show: rgb while cx = x + 1
`ifdef HZ120
    localparam FW = 720, FH = 480;              // 480p active
    localparam VTOT = 525;                      // 480p120 total
    localparam R = 2;                           // 480p integer scale: 2 rows per source line
`else
    localparam FW = 1280, FH = 720;             // 720p active
    localparam VTOT = 750;                      // 720p total
    localparam R = 3;
`endif
    reg [23:0] img [0:FW*FH-1];
    reg        first_line_seen [0:749];
    always @(posedge clk_pixel) begin
        if (dut.cy < FH && dut.cx >= 11'd1 && dut.cx <= FW)
            img[dut.cy * FW + dut.cx - 1] = dut.rgb;
        if (dut.cx == 11'd700)
            first_line_seen[dut.cy] = dut.hdmi_first_line;
    end

    localparam BORDER = 24'h303030;

    // source picture: line l has colour src_color(l) (RGB4), or, when by_column is
    // set, column c has colour col_color(c)
    function [11:0] src_color(input integer l);
        reg [3:0] a, b, c;
        begin
            a = 4 + (l * 5) % 11; b = 4 + (l * 7) % 9; c = 4 + (l * 3) % 7;
            src_color = {a, b, c};
        end
    endfunction
    function [11:0] col_color(input integer n);
        reg [3:0] a, b, c;
        begin
            a = 3 + (n % 12); b = 15 - (n % 12); c = 4 + (n % 5);
            col_color = {a, b, c};
        end
    endfunction
    function [23:0] to_rgb(input [11:0] p);       // as in the scaler
        to_rgb = {p[11:8], 4'b0, p[7:4], 4'b0, p[3:0], 4'b0};
    endfunction
    function [23:0] overlay_rgb(input [14:0] o);
        overlay_rgb = {o[4:0], 3'b0, o[9:5], 3'b0, o[14:10], 3'b0};
    endfunction

    reg by_column = 0;
    // the source line an output row shows in the current mode, -1 for a border row
    // (Scale Integer centres the picture with a border even with scanlines off)
    reg cur_geom;
    function integer exp_line(input integer row);
        begin
            if (cur_geom)
                exp_line = (row < (FH - R * H) / 2 || row >= (FH + R * H) / 2) ? -1 : (row - (FH - R * H) / 2) / R;
            else
                exp_line = row * H / FH;
        end
    endfunction

    // the VDP: the line an output row needs is in the buffer before the row starts
    integer fl, fc;
    always @(dut.cy) begin
        if (dut.cy < FH) begin
            fl = exp_line(dut.cy);
            if (fl >= 0 && !by_column)
                for (fc = 0; fc < 320; fc = fc + 1)
`ifdef HZ120
                    dut.mem[fl * 320 + fc] = src_color(fl);
`else
                    dut.mem[(fl % 32) * 320 + fc] = src_color(fl);
`endif
        end
    end

    task load_columns;
        integer sl, c;
        begin
            for (sl = 0; sl < 240; sl = sl + 1)
                for (c = 0; c < 320; c = c + 1)
`ifdef HZ120
                    dut.mem[sl * 320 + c] = col_color(c);
`else
                    dut.mem[(sl % 32) * 320 + c] = col_color(c);
`endif
        end
    endtask

    function [7:0] dim8(input [7:0] v, input [1:0] d);
        case (d)
        0: dim8 = v - v / 4;
        1: dim8 = v / 2;
        2: dim8 = v / 4;
        default: dim8 = 0;
        endcase
    endfunction

    function [23:0] darken(input [23:0] p, input [1:0] d);
        darken = {dim8(p[23:16], d), dim8(p[15:8], d), dim8(p[7:0], d)};
    endfunction

    // wait for the end of the frame drawn with the new settings: img holds it when this
    // returns (in the blanking past the last active row). Called right after the previous
    // check, the next frame is the first with the new settings; at the start it takes one more.
    integer settle_frames = 2;
    task settle;
        begin
`ifdef HZ120
            repeat (settle_frames) begin
                while (dut.cy != 10'd510) @(posedge clk_pixel);
                while (dut.cy == 10'd510) @(posedge clk_pixel);
            end
`else
            repeat (settle_frames) begin
                while (dut.cy != 10'd725) @(posedge clk_pixel);
                while (dut.cy == 10'd725) @(posedge clk_pixel);
            end
`endif
            settle_frames = 1;
        end
    endtask

    task fail(input [8*60-1:0] what, input integer row, input [23:0] got, input [23:0] want);
        begin
            $display("FAIL: %0s at row %0d: got %h, want %h (%0dx%0d on=%b out=%b thick=%b dark=%0d ov=%b)",
                     what, row, got, want, W, H, sl_on, sl_out, sl_thick, sl_dark, ov);
            $fatal(1, "tb_md_scaler: FAIL");
        end
    endtask

    integer row, line, rr, nd, XP, x, first, last, runs, runlen, minrun, maxrun, w, pw, ptop;
    reg [23:0] want, got, prev;
    reg is_geom;

    task check_rows(input on, input out, input thick, input [1:0] dk, input over);
        begin
            is_geom = ~out & ~over;             // Scale Integer: integer geometry even with scanlines off
`ifdef HZ120
            nd = 1;                                 // 2 rows per line: thin and thick are both one dark row
            XP = 360;                               // centre of the 720-wide frame, inside both 512 and 640
`else
            nd = thick ? 2 : 1;
            XP = 640;
`endif
            ptop = is_geom ? (FH - R * H) / 2 : 0;
            for (row = 0; row < FH; row = row + 1) begin
                got = img[row * FW + XP];
                line = exp_line(row);
                if (over)
                    want = overlay_rgb(overlay_color);
                else if (line < 0)
                    want = BORDER;
                else begin
                    want = to_rgb(src_color(line));
                    if (on & (is_geom ? ((row - ptop) % R >= R - nd) : (out & ((row % R) >= R - nd))))
                        want = darken(want, dk);
                end
                if (got !== want) fail("picture", row, got, want);
`ifdef HZ120
                if (img[row * FW + 0] !== BORDER) fail("left border", row, img[row * FW + 0], BORDER);
                if (img[row * FW + FW - 1] !== BORDER) fail("right border", row, img[row * FW + FW - 1], BORDER);
`else
                if (img[row * FW + 100] !== BORDER) fail("left border", row, img[row * FW + 100], BORDER);
                if (img[row * FW + 1200] !== BORDER) fail("right border", row, img[row * FW + 1200], BORDER);
`endif
            end
            // the core is released at the first row of the picture
            for (row = 0; row < VTOT; row = row + 1)
                if (first_line_seen[row] !== (row == ptop)) begin
                    $display("FAIL: hdmi_first_line at row %0d is %b (picture top %0d)", row, first_line_seen[row], ptop);
                    $fatal(1, "tb_md_scaler: FAIL");
                end
        end
    endtask

    // horizontal extent and pixel widths on a row through the middle of the picture
    task check_columns(input geom);
        begin
`ifdef HZ120
            // integer 2x, or the full 4:3 frame (640 wide) at Full scale
            pw = geom ? W * 2 : 640;
            row = 240;
`else
            pw = (geom && H == 224) ? 896 : 960;
            row = 360;
`endif
            first = -1; last = -1; runs = 0; minrun = 99; maxrun = 0; runlen = 0; prev = BORDER;
            for (x = 0; x < FW; x = x + 1) begin
                got = img[row * FW + x];
                if (got !== BORDER) begin
                    if (first < 0) first = x;
                    last = x;
                    if (got !== prev) begin
                        if (runs > 0) begin
                            if (runlen < minrun) minrun = runlen;
                            if (runlen > maxrun) maxrun = runlen;
                        end
                        runs = runs + 1; runlen = 0;
                    end
                    runlen = runlen + 1;
                end
                prev = got;
            end
            w = last - first + 1;
            if (first !== (FW - pw) / 2 || w !== pw) begin
                $display("FAIL: picture spans x=%0d..%0d (width %0d), want %0d..%0d (%0dx%0d geom=%b)", first, last, w, (FW - pw) / 2, (FW + pw) / 2 - 1, W, H, geom);
                $fatal(1, "tb_md_scaler: FAIL");
            end
            if (runs !== W) begin
                $display("FAIL: %0d source columns on the row, want %0d", runs, W);
                $fatal(1, "tb_md_scaler: FAIL");
            end
            // each source column is the same 2 or 3 or 3 or 4 pixels wide (hz120: 2, or 2..3 at Full)
            if (minrun < (pw / W) || maxrun > (pw + W - 1) / W) begin
                $display("FAIL: pixel widths %0d..%0d, want %0d..%0d", minrun, maxrun, pw / W, (pw + W - 1) / W);
                $fatal(1, "tb_md_scaler: FAIL");
            end
        end
    endtask

    task run(input on, input out, input thick, input [1:0] dk, input over);
        begin
            sl_on = on; sl_out = out; sl_thick = thick; sl_dark = dk; ov = over;
            cur_geom = ~out & ~over;
            settle;
            check_rows(on, out, thick, dk, over);
            $display("framebuffer %0dx%0d on=%b out=%b thick=%b darkness=%0d overlay=%b: ok", W, H, on, out, thick, dk, over);
        end
    endtask

    task columns(input on, input out);
        begin
            sl_on = on; sl_out = out; ov = 0;
            cur_geom = ~out;
            settle;
            check_columns(~out);
            $display("framebuffer %0dx%0d columns on=%b out=%b: ok", W, H, on, out);
        end
    endtask

`ifdef HZ120
    // write img to a binary PPM (P6) for the report
    task dump(input [8*128-1:0] name);
        integer f, n;
        begin
            f = $fopen(name, "wb");
            if (f == 0) begin
                $display("FAIL: cannot open %0s", name);
                $fatal(1, "tb_md_scaler: FAIL");
            end
            $fwrite(f, "P6\n%0d %0d\n255\n", FW, FH);
            for (n = 0; n < FW * FH; n = n + 1)
                $fwrite(f, "%c%c%c", img[n][23:16], img[n][15:8], img[n][7:0]);
            $fclose(f);
            $display("frame %0s written", name);
        end
    endtask

    task frame(input on, input out, input thick, input [1:0] dk, input over, input [8*64-1:0] tag);
        reg [8*128-1:0] path;
        begin
            sl_on = on; sl_out = out; sl_thick = thick; sl_dark = dk; ov = over;
            cur_geom = ~out & ~over;
            settle; settle;
            $sformat(path, "frames/md120_320x224_%0s.ppm", tag);
            dump(path);
        end
    endtask
`endif

    initial begin
        cur_geom = 0;
        #1;
        // 256x224, the Mega Drive's usual frame: the vertical geometry and the darkening
        W = 256; H = 224;
        run(0, 0, 0, 2, 0);                     // Integer scale, scanlines off: integer geometry, no darkening
        run(0, 1, 0, 2, 0);                     // Full scale, scanlines off: full geometry, no darkening
        run(1, 0, 0, 2, 0);                     // the default: integer, thin, 75 %
        run(1, 0, 1, 0, 0);
        run(1, 0, 0, 1, 0);
        run(1, 0, 1, 3, 0);
        run(1, 1, 0, 2, 0);                     // output rows
        run(1, 1, 1, 1, 0);
        run(1, 0, 0, 2, 1);                     // menu up: the overlay is left alone
        run(1, 1, 1, 2, 1);
        run(1, 0, 1, 2, 0);                     // and back
        // the other frame sizes
        W = 320; H = 224;
        run(0, 0, 0, 2, 0);
        run(0, 1, 0, 2, 0);
        run(1, 0, 0, 2, 0);
        run(1, 0, 1, 3, 0);
        run(1, 1, 0, 1, 0);
        W = 320; H = 240;                       // 240 lines are exactly 3 rows each, no border
        run(0, 0, 0, 2, 0);
        run(0, 1, 0, 2, 0);
        run(1, 0, 0, 2, 0);
        run(1, 0, 1, 1, 0);
        run(1, 1, 0, 2, 0);
        W = 256; H = 240;
        run(0, 0, 0, 2, 0);
        run(0, 1, 0, 2, 0);
        run(1, 0, 1, 2, 0);
        // by column: the horizontal geometry
        by_column = 1;
        load_columns;
        W = 256; H = 224;
        columns(0, 0); columns(0, 1); columns(1, 0); columns(1, 1);
        W = 320; H = 224;
        columns(0, 0); columns(0, 1); columns(1, 0);
        W = 320; H = 240;
        columns(0, 0); columns(0, 1); columns(1, 0);
`ifdef HZ120
        // BFI: video_config[21:20]. Off shows the frame twice; black blanks
        // every other refresh; dim halves it; 3 is treated as black. The
        // overlay stays lit on both refreshes.
        begin : bfi
            reg [23:0] a, b, lit;
            sl_on = 0; sl_out = 0; ov = 0; W = 320; H = 224; by_column = 0;
            vcfg = 32'd0;
            settle; settle;
            a = img[200 * FW + 360];
            settle;
            b = img[200 * FW + 360];
            if (a !== b || a === 24'h0 || a === BORDER) begin
                $display("FAIL: BFI off frames %h %h", a, b);
                $fatal(1, "tb_md_scaler: FAIL");
            end
            lit = a;
            vcfg = 32'd1 << 20;                    // mode 1, black
            settle; settle;
            a = img[200 * FW + 360];
            settle;
            b = img[200 * FW + 360];
            if (!((a === lit && b === 24'h0) || (b === lit && a === 24'h0))) begin
                $display("FAIL: BFI black frames %h %h, lit %h", a, b, lit);
                $fatal(1, "tb_md_scaler: FAIL");
            end
            vcfg = 32'd3 << 20;                    // mode 3, same as black
            settle; settle;
            a = img[200 * FW + 360];
            settle;
            b = img[200 * FW + 360];
            if (!((a === lit && b === 24'h0) || (b === lit && a === 24'h0))) begin
                $display("FAIL: BFI rolling-as-black frames %h %h, lit %h", a, b, lit);
                $fatal(1, "tb_md_scaler: FAIL");
            end
            vcfg = 32'd2 << 20;                    // mode 2, dim
            settle; settle;
            a = img[200 * FW + 360];
            settle;
            b = img[200 * FW + 360];
            if (!((a === lit && b === {1'b0, lit[23:17], 1'b0, lit[15:9], 1'b0, lit[7:1]}) ||
                  (b === lit && a === {1'b0, lit[23:17], 1'b0, lit[15:9], 1'b0, lit[7:1]}))) begin
                $display("FAIL: BFI dim frames %h %h, lit %h", a, b, lit);
                $fatal(1, "tb_md_scaler: FAIL");
            end
            vcfg = 32'd1 << 20;
            ov = 1;
            settle; settle;
            a = img[200 * FW + 360];
            settle;
            b = img[200 * FW + 360];
            if (a !== overlay_rgb(overlay_color) || b !== a) begin
                $display("FAIL: BFI under overlay %h %h", a, b);
                $fatal(1, "tb_md_scaler: FAIL");
            end
            ov = 0; vcfg = 0;
            $display("framebuffer BFI modes 0/1/2/3 and overlay: ok");
        end
        // example frames for the report: Integer/Full, scanlines on/off, menu or not
        by_column = 0;
        W = 320; H = 224;
        frame(0, 0, 0, 2, 0, "int_noscan_nomenu");
        frame(1, 0, 0, 2, 0, "int_scan_nomenu");
        frame(0, 1, 0, 2, 0, "full_noscan_nomenu");
        frame(1, 1, 0, 2, 0, "full_scan_nomenu");
        frame(0, 0, 0, 2, 1, "int_noscan_menu");
        frame(1, 0, 0, 2, 1, "int_scan_menu");
        frame(0, 1, 0, 2, 1, "full_noscan_menu");
        frame(1, 1, 0, 2, 1, "full_scan_menu");
`endif
        $display("tb_md_scaler: PASS");
        $finish;
    end

    initial begin
        #4000000000;
        $fatal(1, "tb_md_scaler: timeout");
    end
endmodule
