#!/usr/bin/env python3
"""Write a TAP v1 file of N pulses: a pilot tone, or pulses of varied length.

usage: mktap.py out.tap [pulses] [value|rand]

The KERNAL LOAD sits in its leader/sync search reading these pulses through
the CIA FLAG line and timing them with CIA timers, which is what the pause
and savestate tests need (motor on, pulses flowing, FLAG IRQs) without the
minutes of simulation a complete load would cost. Default 5000 pulses of
0x30 (384 C64 cycles each, ~1.9 s of tape).

"rand": pulse lengths 0x20..0x5F from a fixed LCG. A pilot tone hides any
bug that skips or repeats whole pulses (every pulse is the same); with
varied lengths the cassette line differs as soon as the tape position does.
"""
import struct
import sys

out = sys.argv[1]
n = int(sys.argv[2]) if len(sys.argv) > 2 else 5000
v = sys.argv[3] if len(sys.argv) > 3 else "0x30"
if v == "rand":
    x, b = 12345, bytearray()
    for _ in range(n):
        x = (x * 1103515245 + 12345) & 0x7FFFFFFF
        b.append(0x20 + (x >> 16) % 0x40)
    data = bytes(b)
else:
    data = bytes([int(v, 0)]) * n
with open(out, 'wb') as f:
    f.write(b'C64-TAPE-RAW' + bytes([1, 0, 0, 0]) + struct.pack('<I', len(data)) + data)
