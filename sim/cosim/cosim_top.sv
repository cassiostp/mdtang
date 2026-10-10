// cosim_top: the MegaDrive co-simulation DUT. A small top around the REAL
// mdtang interface logic -- iosys_bl616 (UART protocol, OSD text, save
// channel) and sdram.v (SDRAM controller incl. the battery-save client on its
// port 3) -- plus a behavioral SDRAM chip, MD-bus-like traffic and test
// hooks. No game, no video, no audio: this exercises firmware<->core
// interactions (pad frames, combos, save dumps/restores, reset, MODE,
// core_config) without hardware.
//
// CYCLES AND CLOCKS
//   clk/hclk/resetn come from the C++ bridge. Unlike the NES cosim there is
//   no fclk: sdram.v is a single-clock controller, and mdtang_top runs iosys
//   and sdram.v on ONE clock (clk_sys) -- cosim mirrors that with a single
//   clk at 21.492 MHz (the firmware's sim tick; the real core runs it at
//   53.75 MHz, the model just steps slower in wall time, every core timer
//   keeps its sim-time length). hclk is tied to clk by the bridge: it only
//   feeds textdisp's render pipeline, whose pixels nobody observes (OSD text
//   is snapshotted straight out of the DPB array, see below).
//   One sim tick (firmware sim_time, 1/21.492MHz) is one clk period.
//   FREQ is 21_492_000 everywhere: iosys's UART then runs at exactly the
//   2 Mbaud the bridge decodes (uart_fixed's tick = 524288/Inc clk with
//   Inc = (2^19 * Baud + FREQ/2)/FREQ = 10.746 clk/bit), sdram.v's refresh
//   and 200 us power-on stay real-time, and sdram.v stays below its CAS=2
//   FREQ ceiling.
//
// PROGRAMMING MODEL
//   The generated iosys_bl616_cosim answers core-ID replies with the
//   cosim_core_id input (see Makefile: the ONLY difference from the real
//   iosys_bl616.v, made by mechanical sed at build time and verified by
//   diff). Programming a bitstream = the bridge sets cosim_core_id and
//   pulses resetn, like hardware loading fresh logic. SDRAM contents are
//   RETAINED across reset (external chip), matching hardware.
//   sdram.v's reset IS wired to resetn (tb_system_save's gotcha #1: tie it
//   high and the controller never re-initializes after a reprogram;
//   mdtang_top's .resetn(1'b1) is safe only because JTAG config resets the
//   Gowin FFs). Its ack0..3 toggles have NO reset (gotcha #2): power-on 0
//   is what the model gets (Verilator zero-init), and a reset pulse may
//   leave one stale toggle pending -- exactly as tb_sdram_save models it.
//   silence=1 (MODE blackout) forces both UART lines idle; the bridge ends
//   it with a reset pulse and cosim_core_id=0 (flash bitstream), after which
//   the firmware reboots.
//
// GAME/TRAFFIC MODEL
//   Port 0 gets pulsed MD-bus-like traffic (LFSR-driven, deterministic, held
//   until acked like tb_system_save's client): ROM reads and 68K-RAM reads
//   with a gap of 1..8 clk between requests. Any WRITE into the cart-SRAM
//   window (SDRAM words {8'h41, 1'b0, X[15:1]} = bytes $820000-$83FFFF, i.e.
//   cart $200000-$23FFFF) pulses sv_core_we, exactly what system.sv's
//   BRAM_CHANGE does for real cart writes -- iosys dirties the save and owes
//   the MCU a 0x0B notice. Traffic stops while a ROM loads (mdtang_top holds
//   the system off via md_on during loading).
//   churn_en: the "game" continuously scribbles cart SRAM (combo-during-dump).
//   poke_valid/poke_off/poke_data/poke_ack: single game-path SRAM writes for
//   wram-write/wram-burst (and poke-save). Poke wins over churn and normal
//   traffic for its slot.
//   Port 1 is the ROM loader path wired as mdtang_top wires it (one byte per
//   rom_do_valid), port 2 (RV) is idle, and the save engine rides port 3 --
//   the lowest SDRAM priority (real arbitration), so dumps genuinely contend
//   with game and loader traffic.
//
// OBSERVABILITY (all real unless noted)
//   core_config/video_config/overlay: straight out of iosys (expect-config-bit
//   reads the real register). rom_bytes: ROM payload bytes consumed (firmware streams
//   the ROM; no loader parses it here). sdram_busy: controller init.
//   game_joy1/2: the pads as mdtang_top hands them to the game (muted while
//   the overlay is up OR core_config[22] -- the scanline-preview mute), plus
//   a COSIM-only check that the mute holds. OSD text / save RAM: read by the
//   C++ bridge DIRECTLY out of the behavioral arrays (gowin_dpb_menu.mem,
//   sdram_chip.mem, both `verilator public`), no model clocking per cell.
//   The char buffer lives at DPB $000-$37F = {1'b0, y[4:0], x[4:0]} (32x28).
module cosim_top (
    input wire clk,
    input wire hclk,
    input wire resetn,

    input wire [11:0] joy1,
    input wire [11:0] joy2,

    input wire uart_rx,
    output wire uart_tx,
    input wire silence,
    input wire [15:0] cosim_core_id,

    output wire [31:0] core_config,
    output wire [31:0] video_config,
    output wire overlay,
    output wire sdram_busy,
    output reg [31:0] rom_bytes,
    // TX-pending for the bridge's idle jump: a reply owed or a frame on the
    // wire. Hierarchical into iosys (cosim-owned top; the DUT itself is
    // untouched): send_state covers every TX frame, response_* the core-ID /
    // config-string handoff (RX posts, TX picks up a tick or two later), and
    // sv_rd_req/sv_rd_ack/sv_notify the save-block / dirty-notice path.
    // Without this the bridge would jump over the idle gap between a request
    // and its reply, skipping the reply unsampled. (A joypad frame due on
    // its throttle timer is NOT included: delaying it by a jump is harmless,
    // the firmware polls.)
    output wire tx_pending,
    input wire poke_valid,
    input wire [15:0] poke_off,
    input wire [7:0] poke_data,
    output reg poke_ack,
    input wire churn_en
);

// ---- UART gating (MODE blackout) ----
wire uart_rx_iosys = silence ? 1'b1 : uart_rx;
wire uart_tx_iosys;
assign uart_tx = silence ? 1'b1 : uart_tx_iosys;

// ---- save channel (iosys <-> sdram.v port 3), as mdtang_top wires it ----
wire [15:0] sv_addr;
wire [7:0] sv_din, sv_q;
wire sv_we, sv_req, sv_ack;
wire [15:0] sv_dword;
reg sv_core_we = 0;
// big-endian word: even byte = upper lane (mdtang_top, verbatim)
assign sv_q = sv_addr[0] ? sv_dword[7:0] : sv_dword[15:8];

// ---- ROM sink: the loader path + a count of what the firmware streams ----
// One SDRAM write per rom_do_valid, exactly as mdtang_top wires port 1: the
// req1 toggle flips on every byte and the controller acks it within ~6 clk
// (2 Mbaud puts a byte on the loader at most every ~107 ticks).
wire [7:0] rom_do;
wire rom_do_valid;
wire [7:0] rom_loading;
wire game_on = (rom_loading == 8'd0);   // mdtang_top: LOADING(loading != 0)

reg loader_req = 0;
reg [21:0] loader_addr = 0, loader_addr_next = 0;
always @(posedge clk) begin
    if (!resetn) begin
        rom_bytes <= 0;
        loader_req <= 0;
        loader_addr <= 0;
        loader_addr_next <= 0;
    end else begin
        if (rom_do_valid) begin
            rom_bytes <= rom_bytes + 1;
            loader_req <= ~loader_req;
            loader_addr <= loader_addr_next;
            loader_addr_next <= loader_addr_next + 1;
        end
    end
end

assign tx_pending = (sys.send_state != 4'd0) || (sys.response_req != sys.response_ack) ||
                    (sys.sv_rd_req != sys.sv_rd_ack) || sys.sv_notify;

iosys_bl616_cosim #(
    .FREQ(21_492_000),
    .COLOR_LOGO(15'b00000_00100_11111),
    .SAVE_IF(1),
    .SAVE_AW(16),
    .SAVE_SYNC(0)
) sys (
    .clk(clk),
    .hclk(hclk),
    .resetn(resetn),
    .cosim_core_id(cosim_core_id),

    .overlay(overlay),
    .overlay_x(8'h00),
    .overlay_y(8'h00),
    .overlay_color(),
    .joy1(joy1),
    .joy2(joy2),
    .hid1(),
    .hid2(),

    .rom_loading(rom_loading),
    .rom_do(rom_do),
    .rom_do_valid(rom_do_valid),

    .mgmt_address(),
    .mgmt_read(),
    .mgmt_readdata(16'h0),
    .mgmt_write(),
    .mgmt_writedata(),
    .fdd_request(2'b00),

    .kbd_data(8'h0),
    .kbd_data_valid(),

    .sv_addr(sv_addr),
    .sv_din(sv_din),
    .sv_we(sv_we),
    .sv_q(sv_q),
    .sv_core_we(sv_core_we),
    .sv_req(sv_req),
    .sv_ack(sv_ack),

    .core_config(core_config),
    .video_config(video_config),
    .uart_rx(uart_rx_iosys),
    .uart_tx(uart_tx_iosys)
);

// ---- SDRAM: real controller + behavioral chip, as mdtang_top ----
wire [15:0] sdram_dq;
wire [12:0] sdram_a;
wire [1:0] sdram_ba, sdram_dqm;
wire sdram_ncs, sdram_nwe, sdram_nras, sdram_ncas, sdram_cke;

// game bus (port 0)
reg req0 = 0, wr0 = 0;
reg [24:1] addr0 = 0;
reg [15:0] din0 = 0;
reg [1:0] be0 = 2'b11;
wire ack0;
wire [15:0] dout0;

sdram #(.FREQ(21_492_000)) sdram (
    .SDRAM_DQ(sdram_dq), .SDRAM_A(sdram_a), .SDRAM_DQM(sdram_dqm), .SDRAM_BA(sdram_ba),
    .SDRAM_nWE(sdram_nwe), .SDRAM_nRAS(sdram_nras), .SDRAM_nCAS(sdram_ncas),
    .SDRAM_nCS(sdram_ncs), .SDRAM_CKE(sdram_cke),
    .clk(clk), .resetn(resetn), .refresh_allowed(1'b1), .busy(sdram_busy),
    .req0(req0), .ack0(ack0), .wr0(wr0), .addr0(addr0), .din0(din0), .dout0(dout0), .be0(be0),
    .req1(loader_req), .ack1(), .wr1(1'b1), .addr1({3'b000, loader_addr[21:1]}),
    .din1({2{rom_do}}), .dout1(), .be1(loader_addr[0] ? 2'b01 : 2'b10),
    .req2(1'b0), .ack2(), .wr2(1'b0), .addr2(24'h0), .din2(16'h0), .dout2(), .be2(2'b00),
    .req3(sv_req), .ack3(sv_ack), .wr3(sv_we),
    .addr3({8'h41, 1'b0, sv_addr[15:1]}), .din3({2{sv_din}}), .dout3(sv_dword),
    .be3({~sv_addr[0], sv_addr[0]})
);

sdram_chip chip (
    .fclk(clk),
    .A(sdram_a),
    .BA(sdram_ba),
    .DQM(sdram_dqm),
    .nCS(sdram_ncs),
    .nWE(sdram_nwe),
    .nRAS(sdram_nras),
    .nCAS(sdram_ncas),
    .SDRAM_DQ(sdram_dq)
);

// ---- MD-bus-like traffic + game SRAM writes (clk domain) ----
// Deterministic 16-bit LFSR (x^16+x^14+x^13+x^11+1), never zero.
reg [15:0] lfsr = 16'hACE1;
function [15:0] lfsr_next(input [15:0] s);
    lfsr_next = {s[14:0], s[15] ^ s[13] ^ s[12] ^ s[10]};
endfunction

reg [3:0] gap = 0;
reg [7:0] access = 0;
reg [15:0] churn_off = 0;
reg poke_busy = 0;

always @(posedge clk) begin
    if (!resetn) begin
        req0 <= 0;
        wr0 <= 0;
        addr0 <= 0;
        din0 <= 0;
        be0 <= 2'b11;
        sv_core_we <= 0;
        poke_ack <= 0;
        poke_busy <= 0;
        gap <= 0;
        access <= 0;
        churn_off <= 0;
        lfsr <= 16'hACE1;
    end else begin
        lfsr <= lfsr_next(lfsr);
        sv_core_we <= 0;
        // poke_ack is level (not a pulse): it stays up from accept until the
        // bridge releases poke_valid, so a batch-granularity sampler cannot
        // miss it between evaluations.
        if (!poke_valid)
            poke_ack <= 0;

        if (poke_valid && !poke_busy && game_on && req0 == ack0) begin
            // Test hook: one game-path cart-SRAM write (dirties the save).
            // Accepted only when the bus is free; the request is then HELD
            // (addr/wr/be/din stable) until ack0 catches up, like the real
            // client protocol -- no frame-sampling races to hold for.
            req0 <= ~req0;
            addr0 <= {8'h41, 1'b0, poke_off[15:1]};
            wr0 <= 1;
            be0 <= {~poke_off[0], poke_off[0]};   // byte lane, big-endian
            din0 <= {2{poke_data}};
            sv_core_we <= 1;
            poke_ack <= 1;
            poke_busy <= 1;
        end else if (!poke_valid) begin
            poke_busy <= 0;
            if (game_on && req0 == ack0) begin
                if (gap != 0)
                    gap <= gap - 1;
                else begin
                    // The bus asks again 1..8 clk after an ack (tb_system_save
                    // uses a 0..3 gap; leaving idle slots lets the lowest-
                    // priority save engine through between game accesses).
                    gap <= 4'd1 + {1'b0, lfsr[2:0]};
                    req0 <= ~req0;
                    access <= access + 1;
                    be0 <= 2'b11;
                    if (churn_en && !access[1]) begin
                        // The game scribbles cart SRAM as work RAM, walking
                        // the 64 KB window a word at a time (every 4th access,
                        // as NES churns every 4th CPU cycle).
                        wr0 <= 1;
                        addr0 <= {8'h41, 1'b0, churn_off[15:1]};
                        din0 <= {lfsr[7:0] ^ churn_off[15:8], lfsr[15:8] ^ churn_off[7:0]};
                        churn_off <= churn_off + 16'd2;
                        sv_core_we <= 1;
                    end else begin
                        wr0 <= 0;
                        if (access[2] && access[0])
                            addr0 <= {8'h40, 1'b0, lfsr[15:1]};   // 68K RAM read
                        else
                            addr0 <= {8'h00, lfsr} & 24'h3FFFFF;  // ROM read
                    end
                end
            end
        end
    end
end

// ---- the game's pads, as mdtang_top drives them ----------------------------
// The overlay mutes them, and so does core_config[22] (the firmware's
// scanline preview runs the MegaDrive with the menu hidden and the pads
// dead). The vectors below are what mdtang_top hands to the (unmodelled)
// system instance; the COSIM check makes "bit 22 mutes the pads" a live test
// subject: the m-config script presses pads THROUGH the bridge while the
// preview is up, and this fires if the game would still see them.
wire pads_muted = overlay | core_config[22];
wire [11:0] game_joy1 = pads_muted ? 12'b0 : btn_snes2md(joy1);
wire [11:0] game_joy2 = pads_muted ? 12'b0 : btn_snes2md(joy2);

`ifdef COSIM
    always @(posedge clk)
        if (resetn && core_config[22] && !overlay && (game_joy1 != 12'b0 || game_joy2 != 12'b0)) begin
            $display("cosim_top: pads reach the game while core_config[22]=1: %h %h", game_joy1, game_joy2);
            $fatal(1, "cosim_top: pad-mute check failed");
        end
`endif

// snes layout: R L X A RT LT DN UP START SELECT Y B, high active
// md layout:   Z,Y,X,Mode,Start,C,B,A,Up,Down,Left,Right  (mdtang_top, verbatim)
function [11:0] btn_snes2md(input [11:0] snes);
    reg [11:0] md;
    md[0] = snes[7];    // Right
    md[1] = snes[6];    // Left
    md[2] = snes[5];    // Down
    md[3] = snes[4];    // Up
    md[4] = snes[1];    // A
    md[5] = snes[0];    // B
    md[6] = snes[8];    // C
    md[7] = snes[3];    // Start
    md[8] = 0;          // Mode
    md[9] = 0;          // X
    md[10] = 0;         // Y
    md[11] = 0;         // Z
    btn_snes2md = md;
endfunction

endmodule
