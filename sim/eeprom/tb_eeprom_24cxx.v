// I2C EEPROM sequences against MiSTer's EPPROM_24CXX, wired to a byte BRAM
// exactly as system.sv wires it (synchronous read, byte write on ram_wr).
// The testbench plays the 68K bit-bang routines at the chip pins: write and
// random/sequential read transactions for each mode system.sv selects
// (0 = X24C01, 1 = 24C01-24C16, 2 = 24C65), checking ACKs, the bytes that
// land in (and come back out of) the BRAM, and that writes pulse ram_wr
// (which becomes BRAM_CHANGE -> the firmware's save dump notice).
`timescale 1ns/1ps

module tb_eeprom_24cxx;
    reg clk = 0;
    always #5 clk = ~clk;

    reg        rst = 1;
    reg  [1:0] mode = 0;
    reg [12:0] mask = 13'h7f;
    reg        sdai = 1, scl = 1;
    wire       sdao;
    wire       sda = sdao & sdai;

    wire [12:0] ram_a;
    wire  [7:0] ram_d;
    wire        ram_wr;
    reg   [7:0] ram_q;
    reg   [7:0] mem[0:8191];
    integer i, errors = 0, wr_pulses = 0;

    always @(posedge clk) begin
        if (ram_wr) begin
            mem[ram_a] <= ram_d;
            wr_pulses = wr_pulses + 1;
        end
        ram_q <= mem[ram_a];
    end

    EPPROM_24CXX dut (
        .clk(clk), .rst(rst), .en(1'b1),
        .mode(mode), .mask(mask),
        .sda_o(sdao), .sda_i(sdai), .scl(scl),
        .ram_addr(ram_a), .ram_q(ram_q), .ram_d(ram_d), .ram_wr(ram_wr), .ram_rd()
    );

    // --- I2C master helpers (levels held 8 clocks: the chip edge-detects
    // --- over 4 samples) ---
    task hold; begin repeat (8) @(posedge clk); end endtask

    task i2c_start; begin
        sdai = 1; scl = 1; hold;
        sdai = 0; hold;
        scl = 0; hold;
    end endtask

    task i2c_restart; begin
        sdai = 1; scl = 0; hold;
        scl = 1; hold;
        sdai = 0; hold;
        scl = 0; hold;
    end endtask

    task i2c_stop; begin
        sdai = 0; scl = 0; hold;
        scl = 1; hold;
        sdai = 1; hold;
    end endtask

    task i2c_write_byte(input [7:0] b); integer k; begin
        for (k = 7; k >= 0; k = k - 1) begin
            sdai = b[k]; hold;
            scl = 1; hold;
            scl = 0; hold;
        end
        sdai = 1;                       // ACK bit: slave pulls SDA low
        hold;
        scl = 1; hold;
        if (sda !== 1'b0) begin
            $display("FAIL: no ACK after byte %02x (sda=%b)", b, sda);
            errors = errors + 1;
        end
        scl = 0; hold;
    end endtask

    task i2c_read_byte(output [7:0] b, input ack); integer k; begin
        sdai = 1;
        for (k = 7; k >= 0; k = k - 1) begin
            hold;
            scl = 1; hold;
            b[k] = sda;
            scl = 0; hold;
        end
        sdai = ~ack;                    // master ACK (0) or NACK (1)
        hold;
        scl = 1; hold;
        scl = 0; hold;
        sdai = 1;
    end endtask

    task expect_mem(input [12:0] a, input [7:0] v); begin
        if (mem[a] !== v) begin
            $display("FAIL: mem[%04x] = %02x, want %02x", a, mem[a], v);
            errors = errors + 1;
        end
    end endtask

    task expect_rd(input [7:0] got, input [7:0] v, input [127:0] what); begin
        if (got !== v) begin
            $display("FAIL: %0s read %02x, want %02x", what, got, v);
            errors = errors + 1;
        end
    end endtask

    reg [7:0] rb;

    initial begin
        for (i = 0; i < 8192; i = i + 1) mem[i] = 8'hFF;
        repeat (10) @(posedge clk);
        rst = 0;
        hold;

        // ---- mode 0: X24C01 (7-bit address in the first byte) ----
        mode = 0; mask = 13'h7f;
        i2c_start; i2c_write_byte({7'h2A, 1'b0}); i2c_write_byte(8'hA5); i2c_stop;
        expect_mem(13'h2A, 8'hA5);
        i2c_start; i2c_write_byte({7'h2A, 1'b1});
        i2c_read_byte(rb, 0); expect_rd(rb, 8'hA5, "X24C01");
        i2c_stop;
        $display("mode 0 (X24C01) done, errors=%0d", errors);

        // ---- mode 1: 24C02 (device byte + word address) ----
        rst = 1; hold; rst = 0; hold;
        mode = 1; mask = 13'hff;
        i2c_start; i2c_write_byte(8'hA0); i2c_write_byte(8'h10);
        i2c_write_byte(8'h11); i2c_write_byte(8'h22); i2c_write_byte(8'h33);
        i2c_stop;
        expect_mem(13'h10, 8'h11); expect_mem(13'h11, 8'h22); expect_mem(13'h12, 8'h33);
        // random read of the middle byte, then sequential read across all 3
        i2c_start; i2c_write_byte(8'hA0); i2c_write_byte(8'h11);
        i2c_restart; i2c_write_byte(8'hA1);
        i2c_read_byte(rb, 0); expect_rd(rb, 8'h22, "24C02 random");
        i2c_stop;
        i2c_start; i2c_write_byte(8'hA0); i2c_write_byte(8'h10);
        i2c_restart; i2c_write_byte(8'hA1);
        i2c_read_byte(rb, 1); expect_rd(rb, 8'h11, "24C02 seq0");
        i2c_read_byte(rb, 1); expect_rd(rb, 8'h22, "24C02 seq1");
        i2c_read_byte(rb, 0); expect_rd(rb, 8'h33, "24C02 seq2");
        i2c_stop;
        $display("mode 1 (24C02) done, errors=%0d", errors);

        // ---- mode 2: 24C65 (device, high address, low address) ----
        rst = 1; hold; rst = 0; hold;
        mode = 2; mask = 13'h1fff;
        i2c_start; i2c_write_byte(8'hA0); i2c_write_byte(8'h12); i2c_write_byte(8'h34);
        i2c_write_byte(8'h5A); i2c_stop;
        expect_mem(13'h1234, 8'h5A);
        i2c_start; i2c_write_byte(8'hA0); i2c_write_byte(8'h12); i2c_write_byte(8'h34);
        i2c_restart; i2c_write_byte(8'hA1);
        i2c_read_byte(rb, 0); expect_rd(rb, 8'h5A, "24C65");
        i2c_stop;
        $display("mode 2 (24C65) done, errors=%0d", errors);

        if (wr_pulses != 5) begin
            $display("FAIL: ram_wr pulsed %0d times, want 5 (1+3+1 written bytes)", wr_pulses);
            errors = errors + 1;
        end

        if (errors == 0) $display("PASS tb_eeprom_24cxx");
        else $display("FAIL tb_eeprom_24cxx: %0d errors", errors);
        $finish(errors != 0);
    end

    initial begin
        #2000000;
        $display("FAIL: timeout");
        $finish(1);
    end
endmodule
