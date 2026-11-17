#!/usr/bin/env python3
"""Write the PRG of the savestate acceptance (sim/tests/savestate.sh).

  mkfill.py out.prg

BASIC stub "10 SYS2061" and machine code at $080D that fills the screen
($0400-$07E7) with 'X' and the Color RAM ($D800-$DBE7) with red, then
jumps into the KERNAL keyboard wait loop at $E5CD (standard KERNAL), the
loop the CPU is in at READY: after a savestate load restores READY's RAM the
CPU keeps idling there.
"""
import sys

stub = bytes([0x0B, 0x08, 0x0A, 0x00, 0x9E]) + b'2061' + bytes([0x00, 0x00, 0x00])
code = bytes([
    0xA2, 0x00,              # LDX #0
    0xA9, 0x18,              # L1: LDA #$18 ('X')
    0x9D, 0x00, 0x04,        # STA $0400,X
    0x9D, 0x00, 0x05,        # STA $0500,X
    0x9D, 0x00, 0x06,        # STA $0600,X
    0x9D, 0xE8, 0x06,        # STA $06E8,X
    0xA9, 0x02,              # LDA #2 (red)
    0x9D, 0x00, 0xD8,        # STA $D800,X
    0x9D, 0x00, 0xD9,        # STA $D900,X
    0x9D, 0x00, 0xDA,        # STA $DA00,X
    0x9D, 0xE8, 0xDA,        # STA $DAE8,X
    0xE8,                    # INX
    0xD0, 0xE1,              # BNE L1
    0x4C, 0xCD, 0xE5,        # JMP $E5CD
])
assert 0x0801 + len(stub) == 0x080D
open(sys.argv[1], 'wb').write(bytes([0x01, 0x08]) + stub + code)
