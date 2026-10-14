#!/usr/bin/env python3
# Synthetic test ROMs for the >4MB loader / SSF2 banking / I2C EEPROM sim
# (tb_main.cpp). Three images, each just vectors + a few hand-encoded 68K
# instructions over a known filler pattern:
#   ssf2.bin   5 MB: bank-register writes, then reads through banked slots
#   4mb.bin    exactly 4 MB: reads the last word (the old loader wrapped the
#              byte count to 0 here and reported a short ROMSZ)
#   eeprom.bin 1 MB: a table player that bit-bangs $200001 (NBA Jam wiring,
#              EEPROM_QUIRK=3) through I2C transactions expanded below, and
#              logs every SDA sample to RAM for the harness to check
# Also emits build/expected.h: pattern-word expectations and the I2C steps
# whose SDA sample must read a given value.
import os, struct, sys

OUT = sys.argv[1] if len(sys.argv) > 1 else "build"
os.makedirs(OUT, exist_ok=True)

def pat(off):                       # filler word at byte offset off
    v = (off >> 1) ^ (off >> 17)
    return v & 0xFFFF

def fill(size):
    d = bytearray(size)
    for off in range(0, size, 2):
        struct.pack_into(">H", d, off, pat(off))
    return d

# --- tiny 68K assembler (only the forms below) ---
class Asm:
    def __init__(self, base):
        self.base, self.b, self.labels, self.fix = base, bytearray(), {}, []
    def org(self): return self.base + len(self.b)
    def w(self, *ws):
        for x in ws: self.b += struct.pack(">H", x & 0xFFFF)
    def l(self, x): self.b += struct.pack(">I", x & 0xFFFFFFFF)
    def label(self, n): self.labels[n] = self.org()
    def movea_l(self, imm, an): self.w(0x207C | (an << 9)); self.l(imm)
    def move_l_imm(self, imm, dn): self.w(0x203C | (dn << 9)); self.l(imm)
    def move_w_imm(self, imm, dn): self.w(0x303C | (dn << 9), imm)
    def halt(self): self.w(0x60FE)

def finish(d, a, code_off=0x2000):
    struct.pack_into(">I", d, 0, 0x00FF1000)          # SSP
    struct.pack_into(">I", d, 4, code_off)            # reset PC
    for v in range(8, 0x100, 4):                      # stray vectors: halt too
        struct.pack_into(">I", d, v, code_off)
    d[code_off:code_off + len(a.b)] = a.b

def store_magic(a):                                    # -(A2) protocol: results then 0xFACE
    a.move_w_imm(0xFACE, 0); a.w(0x34C0)               # move.w d0,(a2)+

expected = []

# ---- SSF2, 5 MB ----
d = fill(5 * 1024 * 1024)
a = Asm(0x2000)
a.movea_l(0x00FF0000, 2)
def readw(a, addr):
    a.movea_l(addr, 3); a.w(0x3013, 0x34C0)            # move.w (a3),d0 ; move.w d0,(a2)+
readw(a, 0x080100); expected.append(("ssf2", 0, pat(0x080100)))     # slot 1 as loaded
a.movea_l(0xA130F3, 3); a.w(0x16BC, 9)                             # slot 1 <- bank 9 ($480000)
readw(a, 0x080100); expected.append(("ssf2", 1, pat(0x480100)))
a.movea_l(0xA130FF, 3); a.w(0x16BC, 8)                             # slot 7 <- bank 8 ($400000)
readw(a, 0x380010); expected.append(("ssf2", 2, pat(0x400010)))
readw(a, 0x040100); expected.append(("ssf2", 3, pat(0x040100)))     # slot 0 untouched
store_magic(a); a.halt()
finish(d, a)
open(f"{OUT}/ssf2.bin", "wb").write(d)

# ---- exactly 4 MB ----
d = fill(4 * 1024 * 1024)
a = Asm(0x2000)
a.movea_l(0x00FF0000, 2)
readw(a, 0x3FFFFE); expected.append(("mb4", 0, pat(0x3FFFFE)))      # very last word
readw(a, 0x200100); expected.append(("mb4", 1, pat(0x200100)))
readw(a, 0x040100); expected.append(("mb4", 2, pat(0x040100)))
store_magic(a); a.halt()
finish(d, a)
open(f"{OUT}/4mb.bin", "wb").write(d)

# ---- EEPROM script player (quirk 3: write {scl,sda}=d[1:0] to $200001,
# ---- read SDA on bit 1) ----
steps = []      # (scl, sdai) written per step; sample taken right after
checks = []     # (step index, expected SDA)
def st(scl, sda, expect=None):
    if expect is not None: checks.append((len(steps), expect))
    steps.append((scl << 1) | sda)
def i2c_start(): st(1,1); st(1,0); st(0,0)
def i2c_restart(): st(0,1); st(1,1); st(1,0); st(0,0)
def i2c_stop(): st(0,0); st(1,0); st(1,1)
def i2c_write(b):
    for k in range(7, -1, -1):
        bit = (b >> k) & 1; st(0,bit); st(1,bit); st(0,bit)
    st(0,1); st(1,1,expect=0); st(0,1)                  # ACK from the chip
def i2c_read(val, ack):
    for k in range(7, -1, -1):
        st(0,1); st(1,1,expect=(val >> k) & 1); st(0,1)
    st(0, 0 if ack else 1); st(1, 0 if ack else 1); st(0, 0 if ack else 1); st(0,1)

# txn 0: the byte the harness restored into the save image at $42 must read back
i2c_start(); i2c_write(0xA0); i2c_write(0x42); i2c_restart(); i2c_write(0xA1)
i2c_read(0x99, ack=False); i2c_stop()
# txn 1: write A5 3C at $10,$11
i2c_start(); i2c_write(0xA0); i2c_write(0x10); i2c_write(0xA5); i2c_write(0x3C); i2c_stop()
# txn 2: random-read them back
i2c_start(); i2c_write(0xA0); i2c_write(0x10); i2c_restart(); i2c_write(0xA1)
i2c_read(0xA5, ack=True); i2c_read(0x3C, ack=False); i2c_stop()

d = fill(1024 * 1024)
a = Asm(0x2000)
a.movea_l(0x200001, 0)
a.movea_l(0x3000, 1)
a.movea_l(0x00FF0010, 2)
a.move_l_imm(len(steps), 7)
loop = a.org()
a.w(0x1019)            # move.b (a1)+,d0
a.w(0x1080)            # move.b d0,(a0)
a.w(0x1010)            # move.b (a0),d0
a.w(0x14C0)            # move.b d0,(a2)+
a.w(0x5387)            # subq.l #1,d7 (0x51.., bit 8 set: 0x5287 would be addq)
a.w(0x6600 | ((loop - (a.org() + 2)) & 0xFF))   # bne.s loop
a.movea_l(0x00FF0000, 2); store_magic(a); a.halt()
finish(d, a)
d[0x3000:0x3000 + len(steps)] = bytes(steps)
open(f"{OUT}/eeprom.bin", "wb").write(d)

with open(f"{OUT}/expected.h", "w") as f:
    f.write("// generated by make_roms.py\n")
    for name in ("ssf2", "mb4"):
        vals = [v for (n, i, v) in sorted(expected) if n == name]
        f.write(f"static const uint16_t exp_{name}[] = {{{', '.join(hex(v) for v in vals)}}};\n")
    f.write(f"static const int eeprom_steps = {len(steps)};\n")
    f.write("static const struct { int step; int sda; } eeprom_checks[] = {\n")
    for s, v in checks: f.write(f"    {{{s}, {v}}},\n")
    f.write("};\n")
print(f"ssf2/mb4/eeprom ROMs + expected.h in {OUT} (eeprom: {len(steps)} steps, {len(checks)} checks)")
