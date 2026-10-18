// OSD glyph bit select at 480p. Each overlay pixel is held for 2 HDMI
// clocks, and textdisp needs those 2 clocks to fetch the font byte. The bit
// index has to be the x from the fetch, not the live x (which has already
// stepped on). A one-hot font byte makes a wrong index print the background.
`timescale 1ns/1ps

module tb_font_xoff;
    reg clk = 0, hclk = 0;
    always #10 clk = ~clk;
    always #10 hclk = ~hclk;

    reg [7:0] x = 0, y = 0;
    wire [14:0] color;
    textdisp dut (
        .clk(clk), .hclk(hclk), .resetn(1'b1),
        .x(x), .y(y), .color(color),
        .reg_char_we(4'd0), .reg_char_di(32'd0)
    );

    localparam [14:0] TEXT = 15'b10000_11111_11111;
    localparam [14:0] CURSOR = 15'b10000_11000_11111;   // x[7:3]==0 is the cursor column
    localparam [14:0] BACK = 15'b00000_00000_00000;
    integer n, fails;

    initial begin
        fails = 0;
        // character 1 at overlay (0,0); font row 0 is bit 7 set and the rest clear
        dut.state = 0;
        dut.x_r = 0;
        dut.sim_mem[{1'b0, 5'd0, 5'd0}] = 8'h01;
        dut.sim_mem[{1'b1, 7'h01, 3'b000}] = 8'b1000_0000;
        x = 1;                               // so the first pixel (x=0) is a real x[0] change
        repeat (4) @(posedge hclk);
        #1;

        // Each overlay pixel is 2 HDMI clocks, and consecutive x toggles x[0],
        // which is what starts a fetch. The lit pixel is the cursor colour
        // because column 0 is the cursor. Only bit 7 of the font byte is set.
        for (n = 0; n < 8; n = n + 1) begin
            x = n[7:0];
            @(posedge hclk); #1;             // x[0] changed: fetch starts, bit index latched
            @(posedge hclk); #1;             // OUTPUT: font byte is in, colour is this pixel
            if (n == 7) begin
                if (color !== CURSOR) begin
                    $display("FAIL: x=%0d color %h, want cursor %h (state %0d xoff %0d)", n, color, CURSOR, dut.state, dut.font_xoff);
                    fails = fails + 1;
                end
            end else if (color !== BACK) begin
                $display("FAIL: x=%0d color %h, want back (state %0d xoff %0d)", n, color, dut.state, dut.font_xoff);
                fails = fails + 1;
            end
        end
        if (fails != 0) begin
            $display("tb_font_xoff: FAIL (%0d)", fails);
            $fatal(1, "tb_font_xoff: FAIL");
        end
        $display("tb_font_xoff: PASS");
        $finish;
    end

    initial begin
        #100000;
        $fatal(1, "tb_font_xoff: timeout");
    end
endmodule
