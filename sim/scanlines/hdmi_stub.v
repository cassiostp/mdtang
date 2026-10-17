// Stand-ins for the Gowin and HDMI parts of a scaler, for simulation: a pixel
// counter with the real module's timing (cx, cy count the frame, and
// the picture is the rgb input seen while cx = x + 1), and a pass-through
// output buffer.
module hdmi #(
    parameter VIDEO_ID_CODE = 4,
    parameter DVI_OUTPUT = 0,
    parameter VIDEO_REFRESH_RATE = 60.0,
    parameter IT_CONTENT = 1,
    parameter AUDIO_RATE = 48000,
    parameter AUDIO_BIT_WIDTH = 16,
    parameter START_X = 0,
    parameter START_Y = 0,
    // Native console frame rate: when std_timing is 1 the 720p mode (VIC 4)
    // uses the standard 1650 x 750 timing; when 0 it uses
    // NATIVE_FRAME_WIDTH x 750, a line a few pixels longer or shorter that
    // runs the HDMI output at the console's own refresh rate. Only the line
    // length changes; the sync pulse start/size and polarity stay the 720p
    // values. All other VIC modes are untouched.
    parameter int NATIVE_FRAME_WIDTH = 1650
) (
    // 1: standard 720p timing; 0: native console rate (NATIVE_FRAME_WIDTH)
    input         std_timing,
    input         clk_pixel_x5,
    input         clk_pixel,
    input         clk_audio,
    input  [23:0] rgb,
    input         reset,
    input  [15:0] audio_sample_word [1:0],
    output [2:0]  tmds,
    output        tmds_clock,
    output reg [10:0] cx = START_X,
    output reg [9:0]  cy = START_Y,
    output [10:0] frame_width,
    output [9:0]  frame_height
);
    wire [10:0] frame_w = std_timing ? 11'd1650 : NATIVE_FRAME_WIDTH[10:0];
    assign frame_width = frame_w;
    assign frame_height = 750;
    assign tmds = 3'b0;
    assign tmds_clock = 1'b0;
    always @(posedge clk_pixel) begin
        cx <= (cx == frame_w - 11'd1) ? 11'd0 : cx + 11'd1;
        if (cx == frame_w - 11'd1)
            cy <= (cy == 10'd749) ? 10'd0 : cy + 10'd1;
    end
endmodule

module ELVDS_OBUF (input I, output O, output OB);
    assign O = I;
    assign OB = ~I;
endmodule
