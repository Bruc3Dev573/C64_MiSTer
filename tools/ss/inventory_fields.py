#!/usr/bin/env python3
"""A1 helper - scan-chain fields of each segment from the state inventory.

Reads lint/build/inventory.csv (lint/run_inventory.sh) and prints, for each
arch segment, the 'fields' list for savestate/map.yaml: one field per
register (name, bits) in inventory order (instance, then variable), which is
the chain order proposed by A1. Chip WPs may reorder or rename fields; the
B7 lint only checks that the bits of the fields match the arch bits.

  inventory_fields.py [--csv lint/build/inventory.csv] [SEGMENT...]

A memory classified with several segments (segment: [SID1, SID2]) is split
evenly: the first part of its elements goes to the first segment.
"""
import argparse
import collections
import csv
import os
import re
import sys

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..'))

# path prefix stripped from field names, per segment (longest match first);
# the value replaces the prefix
PREFIXES = {
    'CPU': [('emu.fpga64.cpu.cpu.', 't65_'), ('emu.fpga64.cpu.', '')],
    'VIC': [('emu.fpga64.vic.', '')],
    'CIA1': [('emu.fpga64.cia1.', '')],
    'CIA2': [('emu.fpga64.cia2.', '')],
    'SID1': [('emu.fpga64.sid.chip[0].', ''), ('emu.fpga64.sid.', 'top_')],
    'SID2': [('emu.fpga64.sid.chip[1].', ''), ('emu.fpga64.sid.', 'top_')],
    'REU': [('emu.reu.', '')],
    'CART': [('emu.cartridge.', ''), ('emu.', 'digimax_')],
    'TAPE': [('emu.tape.', ''), ('emu.', 'top_')],
    'INPUT': [('emu.fpga64.keyboard.', 'kbd_'), ('emu.mouse.', 'mouse_'), ('emu.', 'joykey_')],
    'DRV8_1541': [('emu.iec_drive.c1541.drives[0].c1541_drv.', ''), ('emu.iec_drive.c1541.', 'multi_')],
    'DRV9_1541': [('emu.iec_drive.c1541.drives[1].c1541_drv.', '')],
    'DRV8_1581': [('emu.iec_drive.c1581.drives[0].c1581_drv.', ''), ('emu.iec_drive.c1581.', 'multi_')],
    'DRV9_1581': [('emu.iec_drive.c1581.drives[1].c1581_drv.', '')],
    'OPL3': [('emu.opl_inst.opl3.', 'sw_'), ('emu.opl_inst.', '')],
    'SYS': [('emu.fpga64.buslogic.', 'buslogic_'), ('emu.fpga64.', '')],
    'TOP': [('emu.', '')],
    'RTC': [('emu.rtcF83.', ''), ('emu.', 'top_')],
}

# readable names for anonymous ghdl nets and '#n' block variables
RENAME = {
    'emu.fpga64.cia2_pai_iec': 'cia2_pai_7_6',
    'emu.to': 'joykey_to',
    'emu.to#2': 'disk_access_to',
    'emu.to#3': 'use_tape_to',
    'emu.to#4': 'use_rtc_to',
    'emu.act': 'joykey_act',
    'emu.act#2': 'digimax_act',
}


def field_name(seg, path):
    if path in RENAME:
        rel = RENAME[path]
    else:
        rel = path
        for pre, rep in sorted(PREFIXES.get(seg, []), key=lambda p: -len(p[0])):
            if path.startswith(pre):
                rel = rep + path[len(pre):]
                break
        else:
            if rel.startswith('emu.'):
                rel = rel[4:]
    n = re.sub(r'[^a-z0-9]+', '_', rel.lower()).strip('_')
    n = re.sub(r'(?<=[a-z_])(\d+)/', r'\1_', n)
    if n[0].isdigit():
        n = 'n' + n
    return n


def fields(rows):
    out = collections.OrderedDict()
    for r in rows:
        if r['class'] != 'arch' or not r['segment']:
            continue
        segs = r['segment'].split('+')
        bits = int(r['bits']) // len(segs)
        for s in segs:
            lst = out.setdefault(s, [])
            name = field_name(s, r['path'])
            used = {f[0] for f in lst}
            base, k = name, 2
            while name in used:
                name = '%s_%d' % (base, k)
                k += 1
            lst.append((name, bits, r['path']))
    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__.split('\n')[1])
    ap.add_argument('--csv', default=os.path.join(ROOT, 'lint', 'build', 'inventory.csv'))
    ap.add_argument('segments', nargs='*')
    a = ap.parse_args()
    rows = list(csv.DictReader(open(a.csv)))
    for seg, lst in fields(rows).items():
        if a.segments and seg not in a.segments:
            continue
        total = sum(f[1] for f in lst)
        print('  # %s: %d bits, %d words' % (seg, total, -(-total // 64)))
        print('    fields:')
        for name, bits, path in lst:
            print('      - {name: %s, bits: %d}' % (name, bits))
    return 0


if __name__ == '__main__':
    sys.exit(main())
