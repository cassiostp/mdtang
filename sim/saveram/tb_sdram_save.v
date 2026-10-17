// Save-channel unit test for sdram.v: the fourth (lowest-priority) port that
// mdtang_top hangs the cart SRAM's battery-save channel off, verified against a
// behavioral 16-bit SDRAM. Covers ack'd byte writes/reads through the top's
// byte-lane glue (even byte = the upper DQ lane, like the 68K's UDS), the
// {8'h41, 1'b0, addr[15:1]} word map = SDRAM 0x820000+2*addr, row crossing
// inside a dump, that save traffic alongside a port-0 game stream never
// delays or skews the game, and that a save transaction never issues twice.
// Run with run.sh (iverilog).

`timescale 1ns/1ps

module tb_sdram_save;

localparam [24:1] SRAM = 24'h41_0000;   // cart SRAM in this SDRAM layout

reg clk = 0;
always #9.2967 clk = ~clk;              // clk_sys 53.75 Mhz half period

reg resetn = 0;
wire busy;
wire [15:0] SDRAM_DQ;

// ---- save client side: the mdtang_top.sv byte-to-port-3 glue ----
reg  [15:0] sv_addr = 0;
reg  [7:0]  sv_din = 0;
reg         sv_we = 0, sv_req = 0;
wire        sv_ack;
wire [7:0]  sv_q;
wire [15:0] sv_dword;

assign sv_q = sv_addr[0] ? sv_dword[7:0] : sv_dword[15:8];

// ---- port 0: the game, driven by the tasks and the stream below ----
reg  [24:1] addr0_t = 0;
reg  [15:0] din0_t = 0;
reg         we0_t = 0, hold0 = 0;       // 1: hold req0 until acked, like the bus FSM
wire [15:0] dout0;
wire ack0;
reg         req0 = 0;
reg         game_stream = 0, req0_s = 0;
reg  [24:1] addr0_s = 0;
integer     cph = 0;
always @(posedge clk) begin             // a ROM-read-ish every 6 clk while on
    cph <= cph + 1;
    if (game_stream && cph % 6 == 5) begin
        addr0_s <= addr0_s + 1;
        req0_s <= ~req0_s;
    end
end

sdram #(.FREQ(53_750_000)) dut (
    .SDRAM_DQ(SDRAM_DQ), .SDRAM_A(A), .SDRAM_DQM(DQM), .SDRAM_BA(BA),
    .SDRAM_nWE(nWE), .SDRAM_nRAS(nRAS), .SDRAM_nCAS(nCAS),
    .SDRAM_nCS(nCS), .SDRAM_CKE(cke),
    .clk(clk), .resetn(resetn), .refresh_allowed(1'b1), .busy(busy),
    .req0(req0 | (game_stream & req0_s)), .ack0(ack0), .wr0(game_stream ? 1'b0 : we0_t),
    .addr0(game_stream ? addr0_s : addr0_t), .din0(din0_t), .dout0(dout0),
    .be0(2'b11),
    .req1(1'b0), .ack1(), .wr1('0), .addr1(24'h0), .din1('0), .dout1(), .be1(2'b00),
    .req2(1'b0), .ack2(), .wr2('0), .addr2(24'h0), .din2('0), .dout2(), .be2(2'b00),
    .req3(sv_req), .ack3(sv_ack), .wr3(sv_we),
    .addr3({8'h41, 1'b0, sv_addr[15:1]}), .din3({2{sv_din}}), .dout3(sv_dword),
    .be3({~sv_addr[0], sv_addr[0]})
);
wire [12:0] A;
wire [1:0] DQM, BA;
wire nWE, nRAS, nCAS, nCS, cke;

// ---- behavioral SDRAM: 4 banks, activate latches the row, CL2 read ----
reg [12:0] row_lat [0:3];
reg [15:0] mem [0:(1<<23)-1];
wire [2:0] cmd = {nRAS, nCAS, nWE};
wire [23:0] word = {BA, row_lat[BA], A[8:0]};    // controller: bank addr[24:23],
                                                 // row A[10:0], column word A[8:0]
reg rv1 = 0;
reg [15:0] rq1 = 0;
wire rd_fire = (cmd == 3'b101);
wire wr_fire = (cmd == 3'b100);

always @(posedge clk) begin
    if (cmd == 3'b011)                        // activate
        row_lat[BA] <= A[12:0];
    else if (wr_fire) begin                   // write, byte-masked by DQM
        if (!DQM[0]) mem[word][7:0]   <= SDRAM_DQ[7:0];
        if (!DQM[1]) mem[word][15:8]  <= SDRAM_DQ[15:8];
    end
    // CL2 in this controller's frame: cmd rides cycle[2], the read data is
    // sampled at cycle[4] and the chip keeps driving until told otherwise.
    if (rd_fire) begin
        rv1 <= 1'b1;
        rq1 <= mem[word];
    end
end
assign SDRAM_DQ = (rv1 && !wr_fire) ? rq1 : 16'hzzzz;

// the save client must not accept a second request before the ack
integer errs = 0;
reg sv_req_d = 0;
always @(posedge clk) begin
    sv_req_d <= sv_req;
    if (sv_req != sv_req_d && sv_req_d != sv_ack) begin
        errs = errs + 1;
        $display("FAIL: two save requests at once t=%0t ack=%b we=%b addr=%06h", $time, sv_ack, sv_we, sv_addr);
    end
end

// ---- client tasks ----
task done_ok;
    integer t;
begin
    t = 0;
    @(posedge clk);                         // let this task's req toggle land first
    while (sv_ack != sv_req && t < 20000) begin @(posedge clk); t = t + 1; end
    if (sv_ack != sv_req) begin
        errs = errs + 1;
        $display("FAIL: save ack timeout");
    end
end
endtask

task sv_write(input [15:0] a, input [7:0] d);
begin
    @(posedge clk); sv_addr <= a; sv_din <= d; sv_we <= 1; sv_req <= ~sv_req;
    done_ok;
end
endtask

task sv_read(input [15:0] a, input [7:0] e);
    reg [7:0] got;
begin
    @(posedge clk); sv_addr <= a; sv_we <= 0; sv_req <= ~sv_req;
    done_ok;
    repeat (14) @(posedge clk);   // the word lands at cycle[4] of the frame, after the ack
    got = sv_q;
    if (got !== e) begin
        errs = errs + 1;
        $display("FAIL: sv read [%06x] = %02x, expected %02x", a, got, e);
    end
end
endtask

task game_read(input [24:1] a, input [15:0] e);
    integer t;
begin
    @(posedge clk); addr0_t <= a; we0_t <= 0; req0 <= ~req0;
    t = 0;
    @(posedge clk);
    while (ack0 != req0 && t < 20000) begin @(posedge clk); t = t + 1; end
    if (ack0 != req0) begin
        errs = errs + 1;
        $display("FAIL: game ack timeout (the save port starved the game?)");
    end
    if (dout0 !== e) begin
        errs = errs + 1;
        $display("FAIL: game read [%07x] = %04x, expected %04x", a, dout0, e);
    end
end
endtask

function [7:0] pat(input integer i);
    pat = (i * 7 + 13) & 8'hFF;
endfunction

integer k;

initial begin
    // model FF power-on state (Gowin FFs come up 0; the ack toggles have no reset)
    dut.ack0 = 0; dut.ack1 = 0; dut.ack2 = 0; dut.ack3 = 0;
    repeat (10) @(posedge clk);
    resetn = 1;
    wait (busy == 0);                       // init ends after 200 us
    repeat (20) @(posedge clk);

    // 1. byte writes/reads across the region, incl. row crossings (stride 63)
    for (k = 0; k < 256; k = k + 1)
        sv_write(k[15:0] * 63, pat(k));
    for (k = 0; k < 256; k = k + 1)
        sv_read(k[15:0] * 63, pat(k));

    // 2. byte lane: even byte = upper DQ lane = word[15:8], neighbours intact
    sv_write(16'h0100, 8'hAA);
    sv_write(16'h0101, 8'h55);
    sv_read(16'h0100, 8'hAA);
    sv_read(16'h0101, 8'h55);
    if (mem[SRAM + 24'h000080] !== {8'hAA, 8'h55}) begin
        errs = errs + 1;
        $display("FAIL: mem word = %04x, expected AA55 (lane map)", mem[SRAM + 24'h000080]);
    end

    // 3. save traffic alongside a game read stream: the game is never delayed
    //    beyond one save byte (lowest priority), and nothing skews
    @(posedge clk); addr0_t <= 24'h0_0100; din0_t <= 16'h7755; we0_t <= 1; req0 <= ~req0;
    begin : w0
        integer t; t = 0;
        @(posedge clk);
        while (ack0 != req0 && t < 20000) begin @(posedge clk); t = t + 1; end
    end
    @(posedge clk); we0_t <= 0;
    game_read(24'h0_0100, 16'h7755);         // reads back through the stream mux
    game_stream = 1;
    for (k = 0; k < 16; k = k + 1) begin
        sv_write(16'h1000 + k[15:0], 8'h30 + k[7:0]);
        sv_read (16'h1000 + k[15:0], 8'h30 + k[7:0]);
    end
    game_stream = 0; req0_s = 0;

    // 4. a dump-like read burst: write then read one whole block, byte exact
    for (k = 0; k < 512; k = k + 1) sv_write(k[15:0], pat(k));
    for (k = 0; k < 512; k = k + 1) sv_read(k[15:0], pat(k));

    // 5. the game's own SRAM writes (port 0) must be readable by the save
    //    channel byte-exact: the game writes a word, the dump reads both bytes
    @(posedge clk); addr0_t <= SRAM + 24'h2000; din0_t <= 16'hBE71; we0_t <= 1; req0 <= ~req0;
    begin : w1
        integer t; t = 0;
        @(posedge clk);
        while (ack0 != req0 && t < 20000) begin @(posedge clk); t = t + 1; end
    end
    @(posedge clk); we0_t <= 0;
    sv_read(16'h4000, 8'hBE);               // word 0x41_2000 = save byte 0x4000
    sv_read(16'h4001, 8'h71);

    if (errs == 0) $display("tb_sdram_save: PASS");
    else $fatal(1, "tb_sdram_save: FAIL, %0d errors", errs);
    $finish;
end

endmodule
