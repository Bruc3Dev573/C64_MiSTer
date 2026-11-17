#!/usr/bin/env python3
"""Tiny .D64 with one PRG file, for the drive tests.

  mkd64.py out.d64 NAME file.prg

35 tracks: BAM at 18/0, directory at 18/1, the file from track 17 on with
the DOS interleave of 10 (tracks 17, 16, ... as the 1541 DOS allocates them).
The image is read back with d64_prg.py before it is written.
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from d64_prg import SECTORS, chain, directory, offset   # noqa: E402

TRACKS = 35


def build(name, data):
    img = bytearray(sum(SECTORS[:TRACKS]) * 256)
    used = {18: {0, 1}}
    blocks = [data[i:i + 254] for i in range(0, len(data), 254)] or [b'']
    places, track, sector = [], 17, 0
    for _ in blocks:
        if len(used.get(track, ())) == SECTORS[track - 1]:
            track -= 1
            sector = 0
        while sector in used.get(track, ()):
            sector = (sector + 1) % SECTORS[track - 1]
        used.setdefault(track, set()).add(sector)
        places.append((track, sector))
        sector = (sector + 10) % SECTORS[track - 1]
    for i, (blk, (t, s)) in enumerate(zip(blocks, places)):
        o = offset(t, s)
        nxt = places[i + 1] if i + 1 < len(places) else (0, len(blk) + 1)
        img[o:o + 2] = bytes(nxt)
        img[o + 2:o + 2 + len(blk)] = blk
    # BAM: link to the directory, format 'A', free map, disk name and ID
    b = offset(18, 0)
    img[b:b + 4] = bytes([18, 1, 0x41, 0])
    for t in range(1, TRACKS + 1):
        free = [s for s in range(SECTORS[t - 1]) if s not in used.get(t, ())]
        bits = sum(1 << s for s in free)
        img[b + 4 * t:b + 4 * t + 4] = bytes([len(free), bits & 0xFF, (bits >> 8) & 0xFF, bits >> 16])
    img[b + 0x90:b + 0xAB] = b'A8 TEST'.ljust(16, b'\xa0') + b'\xa0\xa0A8\xa02A\xa0\xa0\xa0\xa0'
    # directory: one closed PRG
    d = offset(18, 1)
    img[d:d + 2] = bytes([0, 0xFF])
    entry = bytes([0x82, places[0][0], places[0][1]]) + name.upper().encode('latin-1')[:16].ljust(16, b'\xa0')
    img[d + 2:d + 2 + len(entry)] = entry
    img[d + 30:d + 32] = bytes([len(blocks) & 0xFF, len(blocks) >> 8])
    return bytes(img)


def main():
    if len(sys.argv) != 4:
        print(__doc__.strip())
        return 2
    data = open(sys.argv[3], 'rb').read()
    img = build(sys.argv[2], data)
    files = list(directory(img))
    assert [f[0] for f in files] == [sys.argv[2].upper()], files
    assert chain(img, files[0][1], files[0][2]) == data, 'file does not read back'
    open(sys.argv[1], 'wb').write(img)
    print('%s: %s, %d blocks from %d/%d' % (sys.argv[1], files[0][0], (len(data) + 253) // 254, files[0][1], files[0][2]))
    return 0


if __name__ == '__main__':
    sys.exit(main())
