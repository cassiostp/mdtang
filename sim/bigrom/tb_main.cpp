// Headless full-system checks for >4 MB ROMs, SSF2 banking and the I2C
// EEPROM cart path, run on the real mdtang_top (VERILATOR build, sdram_sim
// backing store) with the synthetic ROMs from make_roms.py. The ROM stream
// and the save restore/dump toggles are driven exactly as the firmware
// drives them (loader bytes under loading=1, save bytes while still held,
// then release); the 68K side does the banking and bit-banging itself.
#include <cstdio>
#include <cstdint>
#include <cstring>
#include <vector>
#include "Vmdtang_top.h"
#include "Vmdtang_top_mdtang_top.h"
#include "verilated.h"
#include "expected.h"

static Vmdtang_top *top;
static Vmdtang_top_mdtang_top *md;
static int errors = 0;
static bool saw_sv_we;

static void step() {                        // one clk_sys edge, clk_z80 at half rate
    top->clk_sys = 0; top->eval();
    top->clk_sys = 1; top->eval();
    top->clk_z80 = !top->clk_z80; top->eval();
    if (md->sv_core_we) saw_sv_we = true;
}
static void steps(int n) { for (int i = 0; i < n; i++) step(); }

// Stream a ROM the firmware way (loading=1 holds the core in reset), but
// leave loading up so a save restore can follow before the release.
static void load_rom(const char *path) {
    FILE *f = fopen(path, "rb");
    if (!f) { printf("FAIL: cannot open %s\n", path); errors++; return; }
    std::vector<uint8_t> rom;
    for (int c; (c = fgetc(f)) != EOF;) rom.push_back((uint8_t)c);
    fclose(f);
    while (md->reset) step();
    top->loading = 1; step();
    for (uint8_t b : rom) {
        top->loader_do = b;
        top->loader_do_valid = 1;
        step();
        top->loader_do_valid = 0;
        steps(5);                           // sdram_sim write latency
    }
    printf("loaded %s (%zu bytes)\n", path, rom.size());
}

// One save-channel byte transaction (the iosys engine's req/ack toggle).
static uint8_t sv_xfer(uint16_t addr, uint8_t din, bool we) {
    top->verilator_sv_addr = addr;
    top->verilator_sv_din = din;
    top->verilator_sv_we = we;
    steps(2);
    top->verilator_sv_req = !top->verilator_sv_req;
    for (int i = 0; i < 100 && md->sv_ack != top->verilator_sv_req; i++) step();
    if (md->sv_ack != top->verilator_sv_req) {
        printf("FAIL: save xfer at %u never acked\n", addr); errors++;
    }
    steps(2);
    return md->sv_q;
}

static uint16_t ram_word(int byte_off) {    // 68K RAM at $FF0000 -> sdram word 0x400000
    return md->u_sdram__DOT__mem[0x400000 + (byte_off >> 1)];
}
static uint8_t ram_byte(int byte_off) {
    uint16_t w = ram_word(byte_off & ~1);
    return (byte_off & 1) ? (w & 0xFF) : (w >> 8);
}

static bool wait_magic(int nresults, int max_steps) {
    for (int i = 0; i < max_steps; i++) {
        step();
        if (ram_word(2 * nresults) == 0xFACE) return true;
    }
    return false;
}

static void check_results(const char *name, const uint16_t *exp, int n) {
    for (int i = 0; i < n; i++) {
        uint16_t got = ram_word(2 * i);
        if (got != exp[i]) {
            printf("FAIL %s result %d: got %04x want %04x\n", name, i, got, exp[i]);
            errors++;
        }
    }
    printf("%s: %d results checked\n", name, n);
}

static void fresh_core(uint32_t quirks) {
    delete top;
    top = new Vmdtang_top;
    md = top->mdtang_top;
    top->verilator_core_config = quirks;
    saw_sv_we = false;
    steps(10);
}

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    const char *dir = argc > 1 ? argv[1] : "build";
    char path[256];

    // ---- 5 MB SSF2 banking ----
    fresh_core(0);
    snprintf(path, sizeof path, "%s/ssf2.bin", dir);
    load_rom(path);
    top->loading = 0;
    if (!wait_magic(4, 400000)) { printf("FAIL ssf2: no completion magic\n"); errors++; }
    else check_results("ssf2", exp_ssf2, 4);

    // ---- exactly 4 MB (loader byte-count wrap) ----
    fresh_core(0);
    snprintf(path, sizeof path, "%s/4mb.bin", dir);
    load_rom(path);
    top->loading = 0;
    steps(4);                               // ROMSZ latches from the byte count here
    if ((md->loader_addr >> 1) != 0x200000) {
        printf("FAIL 4mb: ROMSZ %u words, want 0x200000\n", md->loader_addr >> 1);
        errors++;
    }
    if (!wait_magic(3, 400000)) { printf("FAIL 4mb: no completion magic\n"); errors++; }
    else check_results("mb4", exp_mb4, 3);

    // ---- I2C EEPROM (NBA Jam wiring, quirk 3), incl. save restore/dump ----
    fresh_core(3);
    snprintf(path, sizeof path, "%s/eeprom.bin", dir);
    load_rom(path);
    // restore: one 512-byte blank block with a marker at $42, as saved
    for (int i = 0; i < 512; i++) sv_xfer(i, i == 0x42 ? 0x99 : 0xFF, true);
    top->loading = 0;
    if (!wait_magic(0, 2000000)) {
        printf("FAIL eeprom: no completion magic (ram[0]=%04x log:", ram_word(0));
        for (int i = 0; i < 16; i++) printf(" %02x", ram_byte(0x10 + i));
        printf(")\n");
        errors++;
    }
    else {
        for (auto &c : eeprom_checks) {
            int got = (ram_byte(0x10 + c.step) >> 1) & 1;
            if (got != c.sda) {
                printf("FAIL eeprom step %d: SDA %d want %d\n", c.step, got, c.sda);
                errors++;
            }
        }
        printf("eeprom: %d steps, %zu SDA checks\n", eeprom_steps,
               sizeof eeprom_checks / sizeof eeprom_checks[0]);
    }
    if (!saw_sv_we) { printf("FAIL eeprom: BRAM_CHANGE (sv_core_we) never pulsed\n"); errors++; }
    // dump the save image back out through the same bridge
    uint8_t img[512];
    for (int i = 0; i < 512; i++) img[i] = sv_xfer(i, 0, false);
    if (img[0x10] != 0xA5 || img[0x11] != 0x3C || img[0x42] != 0x99) {
        printf("FAIL eeprom dump: [10]=%02x [11]=%02x [42]=%02x, want a5 3c 99\n",
               img[0x10], img[0x11], img[0x42]);
        errors++;
    }
    for (int i = 0; i < 512; i++)
        if (i != 0x10 && i != 0x11 && i != 0x42 && img[i] != 0xFF) {
            printf("FAIL eeprom dump: unexpected byte [%d]=%02x\n", i, img[i]);
            errors++;
            break;
        }
    printf("eeprom: save dump checked\n");

    if (errors == 0) printf("PASS tb_bigrom\n");
    else printf("FAIL tb_bigrom: %d errors\n", errors);
    return errors != 0;
}
