#!/usr/bin/env python3
"""List or extract the PRG files of a .D64 image (35/40 tracks, no error bytes).

  d64_prg.py Disk1.d64                 list the directory
  d64_prg.py Disk1.d64 outdir [NAME..] write NAME.prg (all PRGs without names)
"""
import os
import sys

SECTORS = [21] * 17 + [19] * 7 + [18] * 6 + [17] * 10


def offset(track, sector):
    return (sum(SECTORS[:track - 1]) + sector) * 256


def chain(img, track, sector):
    out = bytearray()
    seen = set()
    while track:
        if (track, sector) in seen:
            raise ValueError('sector loop at %d/%d' % (track, sector))
        seen.add((track, sector))
        s = img[offset(track, sector):offset(track, sector) + 256]
        track, sector = s[0], s[1]
        out += s[2:256] if track else s[2:sector + 1]
    return bytes(out)


def directory(img):
    track, sector = 18, 1
    while track:
        s = img[offset(track, sector):offset(track, sector) + 256]
        for i in range(0, 256, 32):   # 8 entries, bytes 0-1 of the first are the sector link
            e = s[i + 2:i + 32]
            if e[0] & 7 == 2:   # PRG
                yield e[3:19].rstrip(b'\xa0').decode('latin-1'), e[1], e[2]
        track, sector = s[0], s[1]


def main():
    img = open(sys.argv[1], 'rb').read()
    files = list(directory(img))
    if len(sys.argv) < 3:
        for name, t, s in files:
            print('%-16s %d/%d' % (name, t, s))
        return 0
    want = set(n.lower() for n in sys.argv[3:])
    os.makedirs(sys.argv[2], exist_ok=True)
    for name, t, s in files:
        if not want or name.lower() in want:
            open(os.path.join(sys.argv[2], name.lower().replace(' ', '_') + '.prg'), 'wb').write(chain(img, t, s))
    return 0


if __name__ == '__main__':
    sys.exit(main())
