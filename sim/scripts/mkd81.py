#!/usr/bin/env python3
"""Tiny .D81 with one PRG file, for the 1581 tests.

  mkd81.py out.d81 NAME file.prg

80 tracks of 40 sectors: header at 40/0, BAM at 40/1 and 40/2, directory at
40/3, the file on track 39 from sector 0 on (interleave 1, as the 1581 DOS
allocates next to the directory track). The image is read back before it is
written.
"""
import sys

TRACKS, SPT = 80, 40


def offset(t, s):
    return ((t - 1) * SPT + s) * 256


def chain(img, t, s):
    out, seen = b'', set()
    while t:
        assert 1 <= t <= TRACKS and s < SPT and (t, s) not in seen, (t, s)
        seen.add((t, s))
        o = offset(t, s)
        nt, ns = img[o], img[o + 1]
        out += img[o + 2:o + 256] if nt else img[o + 2:o + ns + 1]
        t, s = nt, ns
    return out


def directory(img):
    t, s = img[offset(40, 0)], img[offset(40, 0) + 1]
    while t:
        o = offset(t, s)
        for e in range(o, o + 256, 32):
            if img[e + 2] == 0x82:   # closed PRG
                yield img[e + 5:e + 21].rstrip(b'\xa0').decode('latin-1'), img[e + 3], img[e + 4]
        t, s = img[o], img[o + 1]


def build(name, data):
    img = bytearray(TRACKS * SPT * 256)
    blocks = [data[i:i + 254] for i in range(0, len(data), 254)] or [b'']
    assert len(blocks) <= SPT, 'shortcut: the file must fit track 39 (40 blocks), spread it over more tracks for bigger tests'
    places = [(39, s) for s in range(len(blocks))]
    for i, (blk, (t, s)) in enumerate(zip(blocks, places)):
        o = offset(t, s)
        nxt = places[i + 1] if i + 1 < len(places) else (0, len(blk) + 1)
        img[o:o + 2] = bytes(nxt)
        img[o + 2:o + 2 + len(blk)] = blk
    used = {40: {0, 1, 2, 3}, 39: {s for _, s in places}}
    # header: first directory sector, format 'D', disk name, ID, DOS '3D'
    h = offset(40, 0)
    img[h:h + 4] = bytes([40, 3, 0x44, 0])
    img[h + 4:h + 0x1D] = b'A10 TEST'.ljust(16, b'\xa0') + b'\xa0\xa0A1\xa03D\xa0\xa0'
    # BAM: 40/1 holds tracks 1-40, 40/2 tracks 41-80 (6 bytes each: free count, 40-bit map)
    for k, nxt in enumerate(((40, 2), (0, 0xFF))):
        b = offset(40, 1 + k)
        img[b:b + 8] = bytes(nxt) + bytes([0x44, 0xBB]) + b'A1' + bytes([0xC0, 0])
        for t in range(1 + 40 * k, 41 + 40 * k):
            free = [s for s in range(SPT) if s not in used.get(t, ())]
            e = b + 0x10 + 6 * (t - 1 - 40 * k)
            img[e:e + 6] = bytes([len(free)]) + sum(1 << s for s in free).to_bytes(5, 'little')
    # directory: one closed PRG
    d = offset(40, 3)
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
