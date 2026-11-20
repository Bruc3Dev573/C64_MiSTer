#!/usr/bin/env python3
"""Check and dump a C64_MiSTer savestate slot (format of rtl/savestate/savestates.sv).

  ss_slot.py slot.ss                      header, TLV list, CRC check (zlib)
  ss_slot.py slot.ss --region 1 ram.bin   write the payload of tag 1 to ram.bin
  ss_slot.py slot.ss --reu reu.bin        16 MiB REU image: REU_RAM (format 1) or the
                                          REU_PAGES records (format 2), zero elsewhere
  ss_slot.py slot.ss --chain-bits 75      expected (live) chain length
  ss_slot.py slot.ss --fields CPU         field values of a chain segment (hex)

Exit status 0 when the slot is well formed and its CRC matches.
"""
import argparse
import os
import struct
import sys
import zlib

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..', 'tools', 'ss'))
try:
    from ss_map import MAP
except ImportError:  # pragma: no cover
    MAP = None

TAG_NAMES = {0x40: 'CHAIN'}
TAG_REU, TAG_PAGES, PAGE, REU_BYTES = 0x09, 0x15, 4096, 1 << 24
if MAP:
    for r in MAP['regions']:
        TAG_NAMES[r['tag']] = r['name']
        if 'pages_tag' in r:
            TAG_PAGES, REU_BYTES = r['pages_tag'], r['bytes']
            TAG_NAMES[TAG_PAGES] = 'REU_PAGES'
    PAGE = MAP['format']['reu_page_bytes']
REC = 8 + PAGE   # record word + page


def pages(data, off, length):
    """[(page index, data offset)] of a REU_PAGES payload, and its errors."""
    recs, errors, last = [], [], -1
    if length % REC:
        return recs, ['REU_PAGES length %d not a multiple of %d' % (length, REC)]
    for at in range(off, off + length, REC):
        rec = struct.unpack_from('<Q', data, at)[0]
        page = rec & 0xFFFFFFFF
        if rec >> 32 != PAGE or page <= last or page >= REU_BYTES // PAGE:
            errors.append('REU_PAGES record %#x at %#x: bad length, order or index' % (rec, at))
            break
        recs.append((page, at + 8))
        last = page
    return recs, errors


def parse(data, chain_bits=None):
    errors = []
    if len(data) < 24:
        return None, ['slot shorter than the headers']
    w = lambda i: struct.unpack_from('<Q', data, i * 8)[0]
    w0, w1, w2 = w(0), w(1), w(2)
    info = {
        'statesize': w0 >> 32, 'counter': w0 & 0xFFFFFFFF,
        'version': w1 & 0xFFFF, 'chain_bits': (w1 >> 16) & 0xFFFF, 'build_hash': w1 >> 32,
        'crc': w2 & 0xFFFFFFFF, 'config_mask': w2 >> 32, 'tlv': [],
    }
    words = info['statesize'] // 2
    if info['statesize'] & 1 or words * 8 > len(data) or words < 4:
        errors.append('bad STATESIZE %#x for %d bytes' % (info['statesize'], len(data)))
        return info, errors
    if chain_bits is not None and info['chain_bits'] != chain_bits:
        errors.append('chain bits %d, expected %d' % (info['chain_bits'], chain_bits))
    ptr = 3
    end = None
    while ptr < words:
        hdr = w(ptr)
        tag, length = hdr & 0xFF, hdr >> 32
        if tag == 0:
            if length:
                errors.append('end marker with length %d' % length)
            end = ptr
            break
        n = (length + 7) // 8
        if ptr + 1 + n > words:
            errors.append('TLV tag %#x runs past STATESIZE' % tag)
            break
        info['tlv'].append((tag, length, (ptr + 1) * 8))
        if tag == TAG_PAGES:
            if info['version'] < 2:
                errors.append('REU_PAGES in a format %d slot' % info['version'])
            errors += pages(data, (ptr + 1) * 8, length)[1]
        ptr += 1 + n
    if end is None:
        errors.append('no end marker')
    else:
        crc = zlib.crc32(data[24:(end + 1) * 8]) & 0xFFFFFFFF
        info['crc_calc'] = crc
        if crc != info['crc']:
            errors.append('CRC %08x, header says %08x' % (crc, info['crc']))
    return info, errors


def fields(data, info, seg_name):
    """{field: value} of a map.yaml segment, from the CHAIN region: word w of
    the region holds the bits of map word w from bit 0 (padded layout)."""
    seg = next((s for s in MAP['segments'] if s['name'] == seg_name), None)
    chain = next((off for tag, _, off in info['tlv'] if tag == 0x40), None)
    if seg is None or chain is None:
        return None
    bits = 0
    for i in range(seg['words']):
        bits |= struct.unpack_from('<Q', data, chain + (seg['addr'] + i) * 8)[0] << (64 * i)
    return {f['name']: (bits >> f['offset']) & ((1 << f['bits']) - 1) for f in seg['fields']}


def main():
    ap = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    ap.add_argument('slot')
    ap.add_argument('--region', nargs=2, action='append', metavar=('TAG', 'FILE'), default=[])
    ap.add_argument('--reu', metavar='FILE', help='write the REU as a 16 MiB image (absent pages zero)')
    ap.add_argument('--chain-bits', type=int, default=None, help='expected live chain bits (default: not checked)')
    ap.add_argument('-q', '--quiet', action='store_true')
    ap.add_argument('--fields', metavar='SEG', action='append', default=[], help='print the fields of a chain segment')
    a = ap.parse_args()
    data = open(a.slot, 'rb').read()
    info, errors = parse(data, a.chain_bits)
    if info and not a.quiet:
        print('STATESIZE %d words32, counter %d, format %d, chain %d bits, build %08x, config %08x, crc %08x' % (
            info['statesize'], info['counter'], info['version'], info['chain_bits'], info['build_hash'],
            info['config_mask'], info['crc']))
        for tag, length, off in info['tlv']:
            print('  tag %#04x %-10s %8d bytes at %#x' % (tag, TAG_NAMES.get(tag, '?'), length, off))
    for t, path in a.region:
        t = int(t, 0)
        for tag, length, off in (info or {}).get('tlv', []):
            if tag == t:
                open(path, 'wb').write(data[off:off + length])
                break
        else:
            errors.append('no region with tag %#x' % t)
    if a.reu and info:
        img = bytearray(REU_BYTES)
        for tag, length, off in info['tlv']:
            if tag == TAG_REU:
                img[:length] = data[off:off + length]
            elif tag == TAG_PAGES:
                for page, at in pages(data, off, length)[0]:
                    img[page * PAGE:(page + 1) * PAGE] = data[at:at + PAGE]
        open(a.reu, 'wb').write(img)
    for s in a.fields:
        f = fields(data, info, s) if info and MAP else None
        if f is None:
            errors.append('no segment %s or no CHAIN region' % s)
            continue
        for k, v in f.items():
            print('%s.%s = %#x' % (s, k, v))
    for e in errors:
        print('ERROR:', e)
    if not errors and not a.quiet:
        print('OK')
    return 1 if errors else 0


if __name__ == '__main__':
    sys.exit(main())
