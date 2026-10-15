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
    // Native refresh: when std_timing is 1 the 720p mode uses the standard
    // 1650-clock line; when 0 it uses NATIVE_FRAME_WIDTH clocks, the
    // console's own refresh rate at the same 74.25 MHz pixel clock.
    parameter int NATIVE_FRAME_WIDTH = 1650
) (
    // std_timing selects the standard 60.00 Hz 720p timing (1) or the native
    // console rate (0); a menu option for it may come later.
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
    wire [10:0] frame_w = (std_timing === 1'b1) ? 11'd1650 : NATIVE_FRAME_WIDTH[10:0];
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
