#!/usr/bin/env bash
# Writes the small test programs of the savestate/pause tests into dir $1.
# The PRGs are "10 SYS2061" followed by machine code at $080D.
set -euo pipefail
D="$1"
mkdir -p "$D"

# sid.prg (both SIDs answer at $D400): volume $1F (LP), resonance $F1 (filter
# voice 1), voice 1 noise AD $09 SR $A8, voice 2 pulse SR $F0, voice 3
# triangle AD $22; loop at $0855: OSC3/ENV3 -> $0400/$0401, cutoff and voice 1
# frequency sweep, gate of voice 1 toggled every 256 loops
printf '\001\010\013\010\012\000\236\062\060\066\061\000\000\000\251\037\215\030\324\251\361\215\027\324\251\100\215\026\324\251\011\215\005\324\251\250\215\006\324\251\040\215\001\324\251\010\215\012\324\251\020\215\010\324\251\360\215\015\324\251\101\215\013\324\251\003\215\017\324\251\042\215\023\324\251\021\215\022\324\251\201\205\374\215\004\324\255\033\324\215\000\004\255\034\324\215\001\004\346\375\245\375\215\026\324\215\000\324\320\350\245\374\111\001\205\374\215\004\324\114\125\010' > "$D/sid.prg"

# reu.prg (REU 512 KiB, status bit 53): loop at $080D: swap $0400-$07E7
# with REU $x1000 (bank 1..7 in turn, cmd $92), border and screen change,
# status read, then a fetch armed for $FF00 (cmd $81) and triggered by a
# write to $FF00, status read
printf '\001\010\013\010\012\000\236\062\060\066\061\000\000\000\251\000\215\002\337\251\004\215\003\337\251\000\215\004\337\251\020\215\005\337\346\373\245\373\051\007\215\006\337\251\350\215\007\337\251\003\215\010\337\251\000\215\012\337\251\222\215\001\337\356\040\320\356\001\004\255\000\337\215\002\004\251\201\215\001\337\215\000\377\255\000\337\215\003\004\114\015\010' > "$D/reu.prg"

# ocean.crt (Ocean type 1, 8 banks of 8 KiB, 16K mode): every bank holds the
# same code at $8000 (CBM80 cold start at $8009) and the byte bank*$11 at
# $8100. $FB = 0, loop at $8010: bank = ++$FB & 7 -> $DE00 ($8016), $8100 ->
# $0400 and the border, $A100 (ROMH, same bank) -> $0401
python3 - "$D/ocean.crt" <<'EOF'
import struct, sys
code = bytes.fromhex("09800980c3c2cd3830a2ff9aa90085fbe6fba5fb29078d00dead00818d00048d20d0ad00a18d01044c1080")
out = b"C64 CARTRIDGE   " + struct.pack(">IHHBB", 0x40, 0x0100, 5, 0, 0) + bytes(6) + b"SSTEST OCEAN".ljust(32, b"\0")
for bank in range(8):
    rom = bytearray(0x2000)
    rom[:len(code)] = code
    rom[0x100] = bank * 0x11
    out += b"CHIP" + struct.pack(">IHHHH", 0x2010, 0, bank, 0x8000, 0x2000) + rom
open(sys.argv[1], "wb").write(out)
EOF

# rtc.prg (PCF8583 on the cassette port: SCL = $01 bit 3, SDA = $01 bit 5,
# read back through cassette sense $01 bit 4, inverted): SEI, loop at $080E:
# start, $A0, word address 2, repeated start, $A1, read the seconds byte ->
# $0400 ($0826), stop, $0401 counts the loops
printf '\001\010\013\010\012\000\236\062\060\066\061\000\000\000\170\040\062\010\251\240\040\103\010\251\002\040\103\010\040\062\010\251\241\040\103\010\040\150\010\215\000\004\040\216\010\356\001\004\114\016\010\251\047\205\001\251\057\205\001\251\017\205\001\251\007\205\001\140\242\010\012\110\251\007\220\002\251\047\205\001\011\010\205\001\051\367\205\001\150\312\320\352\251\047\205\001\251\057\205\001\251\047\205\001\140\242\010\251\000\205\373\251\057\205\001\245\001\051\020\311\020\046\373\251\047\205\001\312\320\355\251\057\205\001\251\047\205\001\245\373\111\377\140\251\007\205\001\251\017\205\001\251\057\205\001\140' > "$D/rtc.prg"

# opl.prg (Sound Expander, status bit 12; write $DF40 index / $DF50 value,
# read $DF60 status): SEI, the init table (channel 0 instrument, channel 1 a
# held drone keyed on, timer 1 every 25 x 80 us = 2 ms and timer 2 started,
# both unmasked), then the loop at $0825: write the index of the next music
# register to $DF40, wait at $082B for a timer flag in $DF60 (status -> $0401),
# write its value, clear the flags ($04 = $80), $0400 counts the steps. 48
# steps (pitch, key on/off, carrier level and waveform, drone pitch), then the
# last one is written again at every tick. Most of the time the CPU waits
# between the index and the value of a register.
python3 - "$D/opl.prg" <<'EOF'
import sys
ORG = 0x080D
INIT = [(0x01, 0x20), (0x20, 0x01), (0x23, 0x01), (0x40, 0x10), (0x43, 0x00), (0x60, 0xF2), (0x63, 0xF2),
        (0x80, 0x55), (0x83, 0x55), (0xE0, 0x01), (0xC0, 0x06),
        (0x21, 0x21), (0x24, 0x21), (0x41, 0x18), (0x44, 0x08), (0x61, 0xF0), (0x64, 0xF0), (0x81, 0x00), (0x84, 0x00),
        (0xA1, 0x41), (0xB1, 0x32), (0x02, 0xE7), (0x03, 0x00), (0x04, 0x03)]
MUSIC = []
for i, f in enumerate([0x6B, 0x81, 0x98, 0xB0, 0xCA, 0xE5, 0x02, 0x20]):
    MUSIC += [(0xA0, f), (0xB0, 0x31), (0x43, i * 5), (0xB0, 0x11), (0xE3, i & 3), (0xA1, 0x41 + 4 * i)]
def code(it, mt):
    c = [0x78, 0xA2, 0x00]                                   # SEI; LDX #0
    init = ORG + len(c)
    c += [0xBD, it & 255, it >> 8, 0xF0, 0x0E]              # LDA itab,X; BEQ done
    c += [0x8D, 0x40, 0xDF, 0xBD, (it + 1) & 255, (it + 1) >> 8, 0x8D, 0x50, 0xDF]
    c += [0xE8, 0xE8, 0x4C, init & 255, init >> 8]          # INX; INX; JMP init
    c += [0xA0, 0x00]                                       # done: LDY #0
    loop = ORG + len(c)
    c += [0xB9, mt & 255, mt >> 8, 0x8D, 0x40, 0xDF]        # LDA mtab,Y; STA $DF40
    c += [0xAD, 0x60, 0xDF, 0x10, 0xFB, 0x8D, 0x01, 0x04]   # wait: LDA $DF60; BPL wait; STA $0401
    c += [0xB9, (mt + 1) & 255, (mt + 1) >> 8, 0x8D, 0x50, 0xDF]
    c += [0xA9, 0x04, 0x8D, 0x40, 0xDF, 0xA9, 0x80, 0x8D, 0x50, 0xDF, 0xEE, 0x00, 0x04]
    c += [0xC8, 0xC8, 0xC0, 2 * len(MUSIC)]                 # INY; INY; CPY #len
    c += [0xD0, (loop - (ORG + len(c) + 2)) & 255]          # BNE loop
    c += [0x88, 0x88, 0x4C, loop & 255, loop >> 8]          # DEY; DEY; JMP loop
    return c
itab = ORG + len(code(0, 0))
mtab = itab + 2 * len(INIT) + 1
body = code(itab, mtab) + [b for p in INIT for b in p] + [0] + [b for p in MUSIC for b in p]
assert len(MUSIC) < 128 and body[0x18:0x1B] == [0xB9, mtab & 255, mtab >> 8]   # loop at $0825, wait at $082B
stub = bytes([0x01, 0x08, 0x0B, 0x08, 0x0A, 0x00, 0x9E]) + b"2061" + bytes(3)
open(sys.argv[1], "wb").write(stub + bytes(body))
EOF

# ef.crt (EasyFlash, type 32, boots in Ultimax from ROMH bank 0): ROML banks
# 0-7 (sector 0 of the ROML flash) and ROMH bank 0. The boot copies a routine
# to RAM ($0800, Ultimax has RAM only at $0000-$0FFF) and loops there: sector
# erase of ROML banks 0-7 with DQ6 toggle polling (the poll count -> $0400,
# $0401 and the border), then 64 bytes programmed in bank 1 (byte X = X ^
# pass ^ EasyFlash RAM $DF00+X, polled), read back and summed into $0402 and
# into the EasyFlash RAM at $DF00 + (pass & 63). The first erase starts 6.83M
# clk_sys after the CRT load, a pass takes 2.65M: the erase 1.2M (busy count
# 1M, its 64 KiB write-back 1.2M), the 64 programs 1.43M.
python3 - "$D/ef.crt" <<'EOF'
import struct, sys
RUN = 0x0800
c = []
def at(): return RUN + len(c)
def bne(t): c.extend([0xD0, (t - (at() + 2)) & 0xFF])
def poke(a, v): c.extend([0xA9, v, 0x8D, a & 255, a >> 8])     # LDA #v; STA a
c += [0xA9, 0x00, 0x85, 0x02]                                   # pass = 0
loop = at()
poke(0xDE00, 0)                                                 # bank 0
for a, v in ((0x8555, 0xAA), (0x82AA, 0x55), (0x8555, 0x80), (0x8555, 0xAA), (0x82AA, 0x55), (0x8000, 0x30)):
    poke(a, v)                                                  # sector erase
c += [0xA9, 0x00, 0x85, 0x03, 0x85, 0x04]                       # poll count = 0
poll = at()
c += [0xE6, 0x03, 0xD0, 0x02, 0xE6, 0x04, 0xAD, 0x00, 0x80, 0xCD, 0x00, 0x80]   # count; LDA $8000; CMP $8000
bne(poll)
c += [0xA5, 0x03, 0x8D, 0x00, 0x04, 0xA5, 0x04, 0x8D, 0x01, 0x04, 0x8D, 0x20, 0xD0]
poke(0xDE00, 1)                                                 # bank 1
c += [0xA2, 0x00]                                               # LDX #0
prog = at()
for a, v in ((0x8555, 0xAA), (0x82AA, 0x55), (0x8555, 0xA0)):
    poke(a, v)                                                  # byte program
c += [0x8A, 0x45, 0x02, 0x5D, 0x00, 0xDF, 0x9D, 0x00, 0x80]     # TXA; EOR pass; EOR $DF00,X; STA $8000,X
wait = at()
c += [0xBD, 0x00, 0x80, 0xDD, 0x00, 0x80]                       # LDA $8000,X; CMP $8000,X
bne(wait)
c += [0xE8, 0xE0, 0x40]; bne(prog)                              # INX; CPX #64
c += [0xA2, 0x00, 0xA9, 0x00, 0x18]                             # LDX #0; LDA #0; CLC
sm = at()
c += [0x7D, 0x00, 0x80, 0xE8, 0xE0, 0x40]; bne(sm)              # ADC $8000,X; INX; CPX #64
c += [0x8D, 0x02, 0x04, 0x48, 0xA5, 0x02, 0x29, 0x3F, 0xAA, 0x68, 0x9D, 0x00, 0xDF]  # sum -> $0402, $DF00 + (pass & 63)
c += [0xE6, 0x02, 0x4C, loop & 255, loop >> 8]                  # INC pass; JMP loop
assert len(c) <= 256
romh = bytearray(0x2000)
romh[:19] = bytes([0x78, 0xD8, 0xA2, 0xFF, 0x9A, 0xA2, 0x00, 0xBD, 0x00, 0xE1, 0x9D, 0x00, 0x08,
                   0xE8, 0xD0, 0xF7, 0x4C, 0x00, 0x08])         # SEI CLD, stack, copy $E100 -> $0800, JMP $0800
romh[0x20] = 0x40                                               # RTI for NMI/IRQ
romh[0x100:0x100 + len(c)] = bytes(c)
romh[0x1FFA:] = bytes([0x20, 0xE0, 0x00, 0xE0, 0x20, 0xE0])     # NMI, RESET, IRQ vectors
out = b"C64 CARTRIDGE   " + struct.pack(">IHHBB", 0x40, 0x0100, 32, 1, 0) + bytes(6) + b"SSTEST EASYFLASH".ljust(32, b"\0")
chip = lambda bank, load, data: b"CHIP" + struct.pack(">IHHHH", 0x2010, 2, bank, load, 0x2000) + bytes(data)
out += chip(0, 0x8000, bytes(0x2000)) + chip(0, 0xA000, romh)
for bank in range(1, 8):
    out += chip(bank, 0x8000, bytes([bank * 0x11]) * 0x2000)
open(sys.argv[1], "wb").write(out)
EOF

# geo.prg (GeoRAM 4 MiB, status bit 52): loop at $0813: page (block = pass,
# page = pass & 63, $DFFF/$DFFE) written with X ^ pass ^ sum, then the pages of
# pass-1 and pass-8 read back through $DE00 and added to the running sum (->
# $0400 + (pass & 31) and the border); ~300k clk_sys per pass
python3 - "$D/geo.prg" <<'EOF'
import sys
ORG = 0x080D
c = [0xA9, 0x00, 0x85, 0xFB, 0x85, 0xFC]                        # pass = sum = 0
def at(): return ORG + len(c)
def bne(t): c.extend([0xD0, (t - (at() + 2)) & 0xFF])
def select(): c.extend([0x8D, 0xFF, 0xDF, 0x29, 0x3F, 0x8D, 0xFE, 0xDF])   # STA $DFFF; AND #$3F; STA $DFFE
loop = at()
c += [0xA5, 0xFB]; select()                                     # block pass, page pass & 63
c += [0xA2, 0x00]
w = at()
c += [0x8A, 0x45, 0xFB, 0x45, 0xFC, 0x9D, 0x00, 0xDE, 0xE8]; bne(w)        # TXA; EOR pass; EOR sum; STA $DE00,X
for back in (1, 8):
    c += [0xA5, 0xFB, 0x38, 0xE9, back]; select()               # page of pass-back
    c += [0xA2, 0x00, 0x18, 0xA5, 0xFC]                         # LDX #0; CLC; LDA sum
    r = at()
    c += [0x7D, 0x00, 0xDE, 0xE8]; bne(r)                       # ADC $DE00,X; INX
    c += [0x85, 0xFC]
c += [0xA5, 0xFB, 0x29, 0x1F, 0xAA, 0xA5, 0xFC, 0x9D, 0x00, 0x04, 0x8D, 0x20, 0xD0]   # sum -> $0400 + (pass & 31), border
c += [0xE6, 0xFB, 0x4C, loop & 255, loop >> 8]                  # INC pass; JMP loop
assert loop == 0x0813
stub = bytes([0x01, 0x08, 0x0B, 0x08, 0x0A, 0x00, 0x9E]) + b"2061" + bytes(3)
open(sys.argv[1], "wb").write(stub + bytes(c))
EOF
