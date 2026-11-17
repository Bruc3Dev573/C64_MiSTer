#!/usr/bin/env python3
"""Convert an Altera .mif to a $readmemh file (one word per line).

usage: mif2hex.py in.mif out.hex
Handles "addr : d d d ;" (srec style, several words per line), "[a..b] : d;"
ranges and HEX/DEC/UNS/BIN radix. Unlisted words are 0.
"""
import re
import sys

RADIX = {'HEX': 16, 'DEC': 10, 'UNS': 10, 'BIN': 2, 'OCT': 8}


def main(src, dst):
    text = open(src).read()
    text = re.sub(r'--[^\n]*', '', text)
    text = re.sub(r'%[^%]*%', '', text)
    hdr, body = re.split(r'CONTENT\s+BEGIN', text, flags=re.I)

    def h(key, default=None):
        m = re.search(key + r'\s*=\s*(\w+)\s*;', hdr, re.I)
        return m.group(1) if m else default

    depth = int(h('DEPTH'))
    width = int(h('WIDTH'))
    ar = RADIX[h('ADDRESS_RADIX', 'HEX').upper()]
    dr = RADIX[h('DATA_RADIX', 'HEX').upper()]
    mem = [0] * depth
    body = re.split(r'\bEND\b', body, flags=re.I)[0]
    for stmt in body.split(';'):
        stmt = stmt.strip()
        if not stmt:
            continue
        addr, data = stmt.split(':', 1)
        words = [int(w, dr) for w in data.split()]
        addr = addr.strip()
        m = re.match(r'\[\s*(\w+)\s*\.\.\s*(\w+)\s*\]', addr)
        if m:
            a, b = int(m.group(1), ar), int(m.group(2), ar)
            for i in range(a, b + 1):
                mem[i] = words[(i - a) % len(words)]
        else:
            a = int(addr, ar)
            for i, w in enumerate(words):
                mem[a + i] = w
    digits = (width + 3) // 4
    with open(dst, 'w') as f:
        for w in mem:
            f.write('%0*x\n' % (digits, w))


if __name__ == '__main__':
    main(sys.argv[1], sys.argv[2])
