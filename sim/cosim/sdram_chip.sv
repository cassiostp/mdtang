// Behavioral SDRAM chip for the MegaDrive co-sim: answers the exact command
// subset the real sdram.v issues (ACT, single-word READ/WRITE with
// auto-precharge, DQM-masked writes, CL2 reads; refresh / mode-set /
// precharge accepted and ignored), taken from the tb_sdram_save /
// tb_system_save models in sim/saveram (which pass against the real
// controller). Read timing: the word is registered at the READ command edge
// and driven on the two following clocks -- the controller samples DQ at
// cycle[4], one clock after its ack at cycle[3], and issues nothing else on
// the bus meanwhile. rv1 never clears (like the TB): after the first read the
// chip drives DQ whenever it is not capturing a WRITE.
//
// Address map (16-bit 4Mx16 part, as mdtang_top): ACT latches
// {bank, row} = {BA[1:0], A[12:0]}; the READ/WRITE column A[8:0] selects the
// word, so the word address is {BA, row, col} = the byte address [24:1]. The
// regions actually touched in the co-sim (ROM < word 0x400000, cart SRAM at
// word 0x410000+) all index below 0x800000, so 2^23 words suffice.
//
// Byte lanes are big-endian as mdtang_top uses them (even bytes = the UPPER
// half), but that mux lives in cosim_top's sv_q / the controller's be; here
// DQM simply masks lane 0 = DQ[7:0], lane 1 = DQ[15:8].
//
// Power-up: all 0xFFFF (blank save RAM reads 0xFF, matching the firmware's
// MD blank byte and SRAM power-up). Contents are RETAINED across resetn: on
// hardware reprogramming the FPGA does not clear the external SDRAM.
// The mem array is `verilator public` for the C++ bridge's fast reads
// (expect-save-ram); iverilog ignores the attribute.
module sdram_chip (
    input fclk,
    input [12:0] A,
    input [1:0] BA,
    input [1:0] DQM,
    input nCS, nWE, nRAS, nCAS,
    inout [15:0] SDRAM_DQ
);

reg [12:0] row_lat [0:3];
reg [15:0] mem [0:(1 << 23) - 1] /*verilator public*/;

integer i;
initial begin
    for (i = 0; i < (1 << 23); i = i + 1)
        mem[i] = 16'hFFFF;
end

wire [2:0] cmd = {nRAS, nCAS, nWE};        // nCS is 0 by construction (sdram.v)
wire [23:0] word = {BA, row_lat[BA], A[8:0]};
reg rv1 = 0;
reg [15:0] rq1 = 0;
wire rd_fire = (cmd == 3'b101);
wire wr_fire = (cmd == 3'b100);

always @(posedge fclk) begin
    if (cmd == 3'b011)
        row_lat[BA] <= A[12:0];
    else if (wr_fire) begin
        if (!DQM[0])
            mem[word][7:0] <= SDRAM_DQ[7:0];
        if (!DQM[1])
            mem[word][15:8] <= SDRAM_DQ[15:8];
    end
    if (rd_fire) begin
        rv1 <= 1'b1;
        rq1 <= mem[word];
    end
end

assign SDRAM_DQ = (rv1 && !wr_fire) ? rq1 : 16'hzzzz;

endmodule
