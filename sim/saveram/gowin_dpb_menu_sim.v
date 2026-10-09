// Sim-only stub of gowin_dpb_menu (the Gowin DPB IP behind textdisp's char
// buffer/font/logo memory). Dual-port, 2048 x 8, one-clock registered read.
module gowin_dpb_menu (
    input clka, input reseta, input ocea, input cea,
    input [10:0] ada, input wrea, input [7:0] dina, output reg [7:0] douta,
    input clkb, input resetb, input oceb, input ceb,
    input [10:0] adb, input wreb, input [7:0] dinb, output reg [7:0] doutb
);
reg [7:0] mem [0:2047];
always @(posedge clka) begin
    if (wrea) mem[ada] <= dina;
    douta <= mem[ada];
end
always @(posedge clkb) doutb <= mem[adb];
endmodule
