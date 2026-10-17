// System-level battery-save test for mdtang: the REAL iosys_bl616 wired to the
// REAL sdram.v port 3 exactly as mdtang_top does it (one clock, clk_sys
// 53.75 MHz; even save byte = the upper DQ lane), with a behavioral SDRAM,
// an MD-bus-like client hammering port 0 (ROM reads plus cart SRAM writes),
// and an MCU model on the UART that behaves like the firmware during a game:
// it restores the save at load, then runs whole dumps (0x12 -> 0x0A) while
// the "main task" polls the core ID, sends HID frames and the player changes
// the pad.
//
// What it guards: the UART link of iosys must keep working during dumps.
// Every dump block must arrive byte exact, every core-ID poll must be
// answered, every HID frame taken and every pad change reported -- the
// in-game menu/reset combos depend on those pad frames.
//
// run.sh compiles a sim copy of iosys with the 20 ms joypad rate limit
// shortened, so a pad change is due within ~0.2 ms here.

`timescale 1ns/1ps

module tb_system_save;

localparam real BIT = 500.0;            // MCU UART: 2 Mbaud, 1 stop bit

// ---- clock: clk_sys drives iosys and the SDRAM controller alike ----
reg clk = 0;
always #9.2967 clk = ~clk;              // 53.75 MHz
reg sys_resetn = 0;

localparam NBLK = 32;                   // dumped per round: 16 KB of the 64 KB window

function [7:0] pat(input [7:0] seed, input integer blk, input integer i);
    pat = seed ^ (blk * 37) ^ i[7:0] ^ (i >> 8);
endfunction

// ---- MD-bus-like client on port 0 (req/ack toggles, held until acked) ----
reg         req0 = 0, wr0 = 0;
reg  [24:1] addr0 = 0;
reg  [15:0] din0 = 0;
reg   [1:0] be0 = 2'b11;
wire        ack0;
wire [15:0] dout0;
reg         core_we = 0;
reg         traffic = 0;
integer     gap = 0;
reg  [15:0] wofs;
always @(posedge clk) begin
    core_we <= 0;
    if (traffic && req0 == ack0) begin
        if (gap != 0) gap <= gap - 1;
        else begin
            gap <= $random & 3;          // the bus asks again 0..3 clk after an ack
            if (($random & 15) == 0) begin
                // the game rewrites cart SRAM with what it already holds, so
                // the dumps stay checkable while the dirty logic sees writes
                wofs = 16'h3F00 + ($random & 16'h00FE);     // block 31, even byte
                wr0 <= 1; be0 <= 2'b11;
                addr0 <= {8'h41, 1'b0, wofs[15:1]};
                din0 <= {pat(8'h5A, wofs >> 9, wofs & 16'h1FF), pat(8'h5A, wofs >> 9, (wofs & 16'h1FF) + 1)};
                core_we <= 1;
            end else begin
                wr0 <= 0; be0 <= 2'b11;
                addr0 <= $random & 24'h3FFFFF;              // ROM
            end
            req0 <= ~req0;
        end
    end
end

// ---- DUT: iosys + sdram.v, connected as in mdtang_top ----
wire [15:0] sv_addr;
wire [7:0]  sv_din, sv_q;
wire        sv_we, sv_req, sv_ack;
wire [15:0] sv_dword;
assign sv_q = sv_addr[0] ? sv_dword[7:0] : sv_dword[15:8];
reg  [11:0] joy1 = 0, joy2 = 0;
reg         uart_rx = 1;
wire        uart_tx;

iosys_bl616 #(.FREQ(53_750_000), .CORE_ID(4), .SAVE_IF(1), .SAVE_AW(16), .SAVE_SYNC(0)) sys (
    .clk(clk), .hclk(clk), .resetn(sys_resetn),
    .overlay(), .overlay_x(8'h00), .overlay_y(8'h00), .overlay_color(),
    .joy1(joy1), .joy2(joy2), .hid1(), .hid2(),
    .rom_loading(), .rom_do(), .rom_do_valid(), .core_config(),
    .mgmt_readdata(16'h0), .fdd_request(2'b00), .kbd_data(8'h0),
    .sv_addr(sv_addr), .sv_din(sv_din), .sv_we(sv_we), .sv_q(sv_q),
    .sv_core_we(core_we), .sv_req(sv_req), .sv_ack(sv_ack),
    .uart_rx(uart_rx), .uart_tx(uart_tx)
);

wire [12:0] A;
wire [1:0] DQM, BA;
wire nWE, nRAS, nCAS, nCS, cke, busy;
wire [15:0] SDRAM_DQ;

sdram #(.FREQ(53_750_000)) sdram (
    .SDRAM_DQ(SDRAM_DQ), .SDRAM_A(A), .SDRAM_DQM(DQM), .SDRAM_BA(BA),
    .SDRAM_nWE(nWE), .SDRAM_nRAS(nRAS), .SDRAM_nCAS(nCAS),
    .SDRAM_nCS(nCS), .SDRAM_CKE(cke),
    .clk(clk), .resetn(sys_resetn), .refresh_allowed(1'b1), .busy(busy),
    .req0(req0), .ack0(ack0), .wr0(wr0), .addr0(addr0), .din0(din0), .dout0(dout0), .be0(be0),
    .req1(1'b0), .ack1(), .wr1('0), .addr1(24'h0), .din1('0), .dout1(), .be1(2'b00),
    .req2(1'b0), .ack2(), .wr2('0), .addr2(24'h0), .din2('0), .dout2(), .be2(2'b00),
    .req3(sv_req), .ack3(sv_ack), .wr3(sv_we),
    .addr3({8'h41, 1'b0, sv_addr[15:1]}), .din3({2{sv_din}}), .dout3(sv_dword),
    .be3({~sv_addr[0], sv_addr[0]})
);

// ---- behavioral SDRAM (as tb_sdram_save): 4 banks, CL2 in this frame ----
reg [12:0] row_lat [0:3];
reg [15:0] mem [0:(1<<23)-1];
wire [2:0] cmd = {nRAS, nCAS, nWE};
wire [23:0] word = {BA, row_lat[BA], A[8:0]};
reg rv1 = 0;
reg [15:0] rq1 = 0;
wire rd_fire = (cmd == 3'b101);
wire wr_fire = (cmd == 3'b100);
always @(posedge clk) begin
    if (cmd == 3'b011)
        row_lat[BA] <= A[12:0];
    else if (wr_fire) begin
        if (!DQM[0]) mem[word][7:0]  <= SDRAM_DQ[7:0];
        if (!DQM[1]) mem[word][15:8] <= SDRAM_DQ[15:8];
    end
    if (rd_fire) begin
        rv1 <= 1'b1;
        rq1 <= mem[word];
    end
end
assign SDRAM_DQ = (rv1 && !wr_fire) ? rq1 : 16'hzzzz;

// ---- MCU side: receive and parse the FPGA's frames ----
wire [7:0] cap_data;
wire cap_valid;
async_receiver #(.ClkFrequency(53_750_000), .Baud(2_000_000)) cap (
    .clk(clk), .RxD(uart_tx), .RxD_data(cap_data), .RxD_data_ready(cap_valid)
);

integer errs = 0;
integer pos = 0, flen = 0;
reg [7:0] ftype = 0;
reg [7:0] fbuf [0:1023];
integer n_id = 0, n_dirty = 0, n_joy = 0, n_blk = 0;
reg [15:0] last_joy1 = 0;
reg [15:0] last_blk = 16'hFFFF;
reg [7:0]  blkdata [0:511];

always @(posedge clk) if (cap_valid) begin
    if (pos == 0) begin
        if (cap_data == 8'hAA) pos <= 1;
        else begin errs = errs + 1; $display("FAIL t=%0t: junk byte %02x between frames", $time, cap_data); end
    end else if (pos == 1) begin flen <= cap_data << 8; pos <= 2; end
    else if (pos == 2) begin flen <= flen | cap_data; pos <= 3; end
    else if (pos == 3) begin ftype <= cap_data; pos <= 4; end
    else begin
        fbuf[pos - 4] = cap_data;
        if (pos - 4 == flen - 2) begin          // last payload byte
            pos <= 0;
            case (ftype)
            8'h01: begin
                n_id = n_id + 1;
                if (fbuf[0] !== 8'h04) begin errs = errs + 1; $display("FAIL: core id %02x", fbuf[0]); end
            end
            8'h03: begin n_joy = n_joy + 1; last_joy1 = {fbuf[0], fbuf[1]}; end
            8'h0A: begin
                last_blk = {fbuf[0], fbuf[1]};
                for (integer i = 0; i < 512; i = i + 1) blkdata[i] = fbuf[2 + i];
                n_blk = n_blk + 1;
            end
            8'h0B: n_dirty = n_dirty + 1;
            default: begin errs = errs + 1; $display("FAIL: unknown frame type %02x", ftype); end
            endcase
        end else
            pos <= pos + 1;
    end
end

// ---- MCU side: send frames (one sender at a time, like taskENTER_CRITICAL) ----
reg tx_lock = 0;
task tx_byte(input [7:0] b);
    integer k;
begin
    uart_rx = 1'b0; #BIT;
    for (k = 0; k < 8; k = k + 1) begin uart_rx = b[k]; #BIT; end
    uart_rx = 1'b1; #BIT;
end
endtask
task lock;   begin while (tx_lock) #50; tx_lock = 1; end endtask
task unlock; begin tx_lock = 0; end endtask
task send_hdr(input [15:0] len, input [7:0] c);
begin tx_byte(8'hAA); tx_byte(len[15:8]); tx_byte(len[7:0]); tx_byte(c); end
endtask


task restore_all(input [7:0] seed);
    integer b, k;
begin
    for (b = 0; b < NBLK; b = b + 1) begin
        lock;
        send_hdr(16'd515, 8'h11); tx_byte(b >> 8); tx_byte(b[7:0]);
        for (k = 0; k < 512; k = k + 1) tx_byte(pat(seed, b, k));
        unlock;
    end
end
endtask

// one firmware sv_fetch_block(): 0x12, then the block within 1 s (scaled: 10 ms; one block frame takes ~2.9 ms)
task fetch(input integer b, input [7:0] seed, input check);
    integer n0, t, k;
begin
    n0 = n_blk;
    lock; send_hdr(16'd3, 8'h12); tx_byte(b >> 8); tx_byte(b[7:0]); unlock;
    t = 0;
    while (n_blk == n0 && t < 10000) begin #1000; t = t + 1; end
    if (n_blk == n0) begin
        errs = errs + 1;
        $display("FAIL t=%0t: block %0d never arrived  send_state=%0d sv_data_rdy=%b sv_req=%b sv_ack=%b",
                 $time, b, sys.send_state, sys.sv_data_rdy, sv_req, sv_ack);
    end else if (last_blk != b) begin
        errs = errs + 1; $display("FAIL: asked block %0d, got %0d", b, last_blk);
    end else if (check) begin
        for (k = 0; k < 512; k = k + 1)
            if (blkdata[k] !== pat(seed, b, k)) begin
                errs = errs + 1;
                if (errs < 20) $display("FAIL: block %0d byte %0d = %02x, expected %02x", b, k, blkdata[k], pat(seed, b, k));
            end
    end
end
endtask

// the main task's get_core_id(): 0x01, then the reply within 200 ms (scaled: 5 ms; it may wait out a block frame)
task poll_id;
    integer n0, t;
begin
    n0 = n_id;
    lock; send_hdr(16'd1, 8'h01); unlock;
    t = 0;
    while (n_id == n0 && t < 5000) begin #1000; t = t + 1; end
    if (n_id == n0) begin
        errs = errs + 1;
        $display("FAIL t=%0t: core-ID poll unanswered send_state=%0d recv_state=%b", $time, sys.send_state, sys.recv_state);
    end
end
endtask

// a HID frame (main task, send_hid_state): the core must take it, even when it
// lands while iosys still owes a core-ID reply behind a long block frame
task send_hid(input [15:0] h);
begin
    lock; send_hdr(16'd5, 8'h09); tx_byte(h[15:8]); tx_byte(h[7:0]); tx_byte(0); tx_byte(0); unlock;
    #2000;
    if (sys.hid1 !== h) begin
        errs = errs + 1;
        $display("FAIL t=%0t: HID frame %04x dropped (core has %04x) recv_state=%b", $time, h, sys.hid1, sys.recv_state);
    end
end
endtask

// the player: change the pad, the MCU must see the new state soon
task press(input [11:0] v);
    integer t;
begin
    joy1 = v;
    t = 0;
    while (last_joy1 !== {4'b0, v} && t < 5000) begin #1000; t = t + 1; end
    if (last_joy1 !== {4'b0, v}) begin
        errs = errs + 1;
        $display("FAIL t=%0t: pad %03x never reported (MCU still sees %03x) send_state=%0d",
                 $time, v, last_joy1, sys.send_state);
    end
end
endtask

integer round, b, k;
reg dumping = 0;


initial begin
    // FF power-on state of regs without a reset (Gowin FFs come up 0; the
    // sdram ack toggles have no reset, like tb_sdram_save models them)
    sys.send_idx = 0; sys.response_req = 0; sys.response_ack = 0;
    sys.joy1_reg = 0; sys.joy2_reg = 0; sys.send_state_next = 0;
    sdram.ack0 = 0; sdram.ack1 = 0; sdram.ack2 = 0; sdram.ack3 = 0;
    
    repeat (300) @(posedge clk);
    sys_resetn = 1;
    wait (busy == 0);
    repeat (50) @(posedge clk);

    // load: restore while the core is held (no traffic), like saves_restore()
    restore_all(8'h5A);
    traffic = 1;
    poll_id;
    press(12'h004); press(12'h00C); press(12'h40C); press(12'h000);

    // game running: dumps (the save task) race the main task and the player
    for (round = 0; round < 3; round = round + 1) begin
        dumping = 1;
        fork
            begin
                for (b = 0; b < NBLK; b = b + 1) fetch(b, 8'h5A, 1);
                dumping = 0;
            end
            begin
                while (dumping) begin poll_id; #(37_000 + round * 11_000); end
            end
            begin
                while (dumping) begin send_hid(16'h0008); #23_000; send_hid(0); #31_000; end
            end
            begin
                while (dumping) begin
                    press(12'h004); #7_000; press(12'h00C); #5_000; press(12'h40C);
                    #60_000; press(12'h000); #40_000;
                end
            end
        join
        // after the dump the controls must still work
        poll_id;
        press(12'h40C); press(12'h000);
        press(12'h80C); press(12'h000);
    end

    $display("tb_system_save: %0d blocks, %0d id replies, %0d pad frames, %0d dirty notices",
             n_blk, n_id, n_joy, n_dirty);
    if (errs == 0) $display("tb_system_save: PASS");
    else $fatal(1, "tb_system_save: FAIL, %0d errors", errs);
    $finish;
end

initial begin
    #2_000_000_000;
    $fatal(1, "tb_system_save: FAIL, global timeout");
end

endmodule
