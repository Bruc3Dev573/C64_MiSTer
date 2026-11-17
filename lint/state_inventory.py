#!/usr/bin/env python3
"""B7 - state coverage lint.

Lists every storage element of the design (flip-flops and inferred memories)
from a Verilator XML dump and checks that each one is classified for the
savestate work:

  arch      architectural state, saved in the chain (needs a 'segment')
  region    memory walked through a port (RAM, Color RAM, ...), saved as region
  rebuilt   not saved, rebuilt after load (needs a 'reason')
  ignored   not machine state: debug, OSD, overlays, host side (needs a 'reason')

Classes come from a YAML file (savestate/state_classes.yaml). Each rule is a
glob on "<instance path>.<variable>" and the first matching rule wins ('*'
matches any text including dots, '?' one character; brackets are literal, so
generate scopes are written as in the path, e.g. drives[0]):

  - match: "emu.fpga64.cia1.*"
    class: arch
    segment: CIA1
  - match: "emu.drv_ovl.*"
    class: ignored
    reason: OSD overlay, recomputed every frame

Usage:
  verilator --xml-only --xml-output design.xml ...same files as the sim...
  state_inventory.py design.xml [--classes savestate/state_classes.yaml]
                     [--csv inventory.csv] [--md report.md] [--fail-unclassified]

Exit code 1 with --fail-unclassified when something is not classified, or when
a rule is malformed. Variables written in clocked blocks only with blocking
assignments are reported as kind 'ff?' (they are usually temporaries that do
not hold state, but a human decides).
"""
import argparse
import collections
import csv
import re
import sys
import xml.etree.ElementTree as ET

CLASSES = {'arch', 'region', 'rebuilt', 'ignored'}


def load_types(root):
    types = {}
    for tt in root.iter('typetable'):
        for t in tt:
            types[t.get('id')] = t
    return types


def const_val(node):
    """Value of a Verilator <const name="32'h3fff"> node."""
    name = node.get('name', '0')
    if "'" not in name:
        return int(name)
    base_val = name.split("'", 1)[1].lstrip('s')
    base, digits = base_val[0], base_val[1:]
    radix = {'h': 16, 'd': 10, 'b': 2, 'o': 8}[base]
    return int(digits.replace('_', ''), radix)


def dtype_shape(types, dtype_id, depth=0):
    """(bit width of one element, number of elements)."""
    t = types.get(dtype_id)
    if t is None or depth > 16:
        return 1, 1
    tag = t.tag
    if tag == 'basicdtype':
        if t.get('left') is not None:
            return abs(int(t.get('left')) - int(t.get('right'))) + 1, 1
        name = t.get('name')
        return {'integer': 32, 'int': 32, 'byte': 8, 'shortint': 16,
                'longint': 64}.get(name, 1), 1
    if tag in ('unpackarraydtype', 'packarraydtype'):
        rng = t.find('range')
        n = 1
        if rng is not None:
            c = [const_val(x) for x in rng if x.tag == 'const']
            if len(c) == 2:
                n = abs(c[0] - c[1]) + 1
        w, m = dtype_shape(types, t.get('sub_dtype_id'), depth + 1)
        if tag == 'packarraydtype':
            return w * n, m
        return w, m * n
    if tag in ('refdtype', 'typedefdtype', 'enumdtype', 'constdtype'):
        sub = t.get('sub_dtype_id') or t.get('refDTypep')
        if sub:
            return dtype_shape(types, sub, depth + 1)
        return 1, 1
    if tag == 'structdtype':
        return sum(dtype_shape(types, m.get('sub_dtype_id'), depth + 1)[0]
                   for m in t.findall('memberdtype')), 1
    return 1, 1


def demangle(name):
    """Undo Verilator's escaping of non-identifier characters (__0XX)."""
    return re.sub(r'__0([0-9a-fA-F]{2})', lambda m: chr(int(m.group(1), 16)), name)


def lhs_vars(node):
    """Variable names written by an assignment target expression."""
    if node.tag == 'varref':
        return [node.get('name')]
    if node.tag in ('sel', 'arraysel', 'structsel', 'wordsel'):
        return lhs_vars(node[0]) if len(node) else []
    if node.tag == 'concat':
        out = []
        for ch in node:
            out += lhs_vars(ch)
        return out
    return []


def is_clocked(always):
    st = always.find('sentree')
    if st is None:
        return False
    return any(si.get('edgeType') in ('POS', 'NEG', 'BOTH')
               for si in st.iter('senitem'))


def module_scope_vars(mod):
    """{name: var} declared in the module outside always blocks and
    functions/tasks (a function argument named like a register, e.g. the
    's' select input of a ghdl mux function, must not shadow it)."""
    out = {}
    stack = list(mod)
    while stack:
        n = stack.pop()
        if n.tag in ('always', 'func', 'task'):
            continue
        if n.tag == 'var':
            out.setdefault(n.get('name'), n)
        stack.extend(list(n))
    return out


def scan_module(mod):
    """[(var element, kind, name)] of state written in clocked processes
    ('ff' or 'ff?').

    A variable declared inside an always block is resolved there first, so
    block-local variables with the same name in different processes (e.g.
    several 'reg old_x' or 'integer to' in c64.sv) stay separate entries;
    the second and later ones get a '#2', '#3' suffix in source order."""
    mvars = module_scope_vars(mod)
    written = collections.OrderedDict()   # id(var) -> [var, kind]
    for alw in mod.iter('always'):
        if not is_clocked(alw):
            continue
        local = {}
        for v in alw.iter('var'):
            local.setdefault(v.get('name'), v)
        for a in alw.iter():
            if a.tag not in ('assigndly', 'assign'):
                continue
            if len(a) < 2:
                continue
            kind = 'ff' if a.tag == 'assigndly' else 'ff?'
            for name in lhs_vars(a[1]):
                v = local.get(name, mvars.get(name))
                if v is None:
                    continue
                e = written.setdefault(id(v), [v, kind])
                if e[1] != 'ff':
                    e[1] = kind
    by_name = collections.defaultdict(list)
    for v, kind in written.values():
        by_name[v.get('name')].append((v, kind))

    def line(v):
        try:
            return int(v.get('loc', '').split(',')[1])
        except (IndexError, ValueError):
            return 0
    out = []
    for name, lst in by_name.items():
        lst.sort(key=lambda e: line(e[0]))
        for i, (v, kind) in enumerate(lst):
            out.append((v, kind, name if i == 0 else '%s#%d' % (name, i + 1)))
    return out


def unmangle_hier(hier):
    """Verilator 'hier' attribute -> readable path (generate scopes kept)."""
    return hier.replace('__BRA__', '[').replace('__KET__', ']').replace('__DOT__', '.')


def walk_cells(cell, prefix, out):
    # 'hier' includes generate block scopes (drives[0], chip[1], ...) that
    # the cell name alone loses; without it two instances share one path
    if cell.get('hier'):
        path = unmangle_hier(cell.get('hier'))
    else:
        path = prefix + cell.get('name') if prefix else cell.get('name')
    out.append((path, cell.get('submodname')))
    for ch in cell.findall('cell'):
        walk_cells(ch, path + '.', out)


def inventory(xml_path, top_alias=None):
    root = ET.parse(xml_path).getroot()
    types = load_types(root)
    files = {f.get('id'): f.get('filename') for f in root.iter('file')}

    modules = {}
    for mod in root.iter('module'):
        modules[mod.get('name')] = (mod, scan_module(mod))

    insts = []
    cells = root.find('cells')
    for c in cells.findall('cell'):
        walk_cells(c, '', insts)

    rows = []
    for path, modname in insts:
        if modname not in modules:
            continue
        mod, written = modules[modname]
        if top_alias and '.' not in path:
            path = top_alias
        elif top_alias:
            path = top_alias + path[path.index('.'):]
        for v, kind, name in sorted(written, key=lambda e: e[2]):
            if name.startswith('__V'):
                continue
            width, depth = dtype_shape(types, v.get('dtype_id'))
            if depth > 1:
                kind = 'mem'
            loc = v.get('loc', '')
            fid, line = (loc.split(',') + ['', ''])[:2]
            rows.append({
                'path': path + '.' + demangle(v.get('origName') or name).lstrip('\\').replace('.', '/')
                        + (name[name.index('#'):] if '#' in name else ''),
                'module': mod.get('origName') or modname,
                'kind': kind,
                'width': width,
                'depth': depth,
                'bits': width * depth,
                'source': '%s:%s' % (files.get(fid, fid), line),
            })
    return rows


def load_rules(path):
    import yaml
    with open(path) as f:
        rules = yaml.safe_load(f) or []
    errors = []
    for i, r in enumerate(rules):
        c = r.get('class')
        if 'match' not in r or c not in CLASSES:
            errors.append('rule %d: needs match and class in %s' % (i, sorted(CLASSES)))
        elif c == 'arch' and not r.get('segment'):
            errors.append('rule %d (%s): arch needs a segment' % (i, r['match']))
        elif c in ('rebuilt', 'ignored') and not r.get('reason'):
            errors.append('rule %d (%s): %s needs a reason' % (i, r['match'], c))
    return rules, errors


def glob_re(pattern):
    """Glob with '*' and '?' only: brackets are literal, so generate scopes
    can be written as they appear in paths (drives[0], chip[1])."""
    rx = ''.join('.*' if c == '*' else '.' if c == '?' else re.escape(c) for c in pattern)
    return re.compile(rx + r'\Z', re.S)


def classify(rows, rules):
    used = collections.Counter()
    pats = [glob_re(r['match']) for r in rules]
    for row in rows:
        row['class'] = ''
        row['segment'] = ''
        row['reason'] = ''
        for i, r in enumerate(rules):
            if pats[i].match(row['path']):
                row['class'] = r['class']
                seg = r.get('segment', '')
                row['segment'] = '+'.join(seg) if isinstance(seg, list) else seg
                row['reason'] = r.get('reason', '')
                used[i] += 1
                break
    return [r for i, r in enumerate(rules) if not used[i]]


def check_map(rows, rules, map_path):
    """Check rules and inventory against savestate/map.yaml.

    Returns (errors, mismatches, table): errors for unknown segment/region
    names or regions too small for their memories; mismatches where the arch
    bits of a segment differ from the bits of its 'fields' in the map; table
    rows (segment, inventory bits, map bits, words) for the report. A rule
    may list several segments (segment: [SID1, SID2]) for a memory whose
    elements are split evenly between them in order."""
    import yaml
    with open(map_path) as f:
        m = yaml.safe_load(f)
    segs = collections.OrderedDict((x['name'], x) for x in m['segments'])
    regs = {x['name']: x for x in m['regions']}
    errors = []
    for i, r in enumerate(rules):
        names = r.get('segment') or []
        names = names if isinstance(names, list) else [names]
        known = regs if r.get('class') == 'region' else segs
        for n in names:
            if r.get('class') in ('arch', 'region') and n not in known:
                errors.append('rule %d (%s): %s %s is not in %s' % (
                    i, r['match'], 'region' if known is regs else 'segment', n, map_path))
    inv = collections.Counter()
    need = collections.Counter()
    for row in rows:
        names = row['segment'].split('+') if row['segment'] else []
        if row['class'] == 'arch' and names:
            if row['bits'] % len(names):
                errors.append('%s: %d bits do not split evenly over %s' % (row['path'], row['bits'], row['segment']))
            for n in names:
                inv[n] += row['bits'] // len(names)
        elif row['class'] == 'region' and names:
            need[names[0]] += row['depth'] * ((row['width'] + 7) // 8)
    for n, b in need.items():
        if n in regs and b > regs[n]['bytes']:
            errors.append('region %s: memories need %d bytes, map reserves %d' % (n, b, regs[n]['bytes']))
    table, mismatches = [], []
    for n, x in segs.items():
        fb = sum(f['bits'] for f in (x.get('fields') or []))
        table.append((n, inv[n], fb, x['words']))
        if inv[n] != fb:
            mismatches.append('segment %s: %d arch bits in the inventory, %d bits of fields in the map' % (n, inv[n], fb))
    return errors, mismatches, table


def module_of(path, depth):
    inst = path.rsplit('.', 1)[0]
    return '.'.join(inst.split('.')[:depth])


def write_md(rows, unused, out, group_depth, seg_table=None):
    by = collections.OrderedDict()
    for r in rows:
        by.setdefault(module_of(r['path'], group_depth), []).append(r)
    total_bits = sum(r['bits'] for r in rows if r['kind'] != 'mem')
    lines = ['# State inventory', '',
             'Flip-flop bits: %d; memories: %d (%d bits); unclassified entries: %d' % (
                 total_bits,
                 sum(1 for r in rows if r['kind'] == 'mem'),
                 sum(r['bits'] for r in rows if r['kind'] == 'mem'),
                 sum(1 for r in rows if not r['class'])), '',
             '| Instance | FF bits | Memories | arch | region | rebuilt | ignored | unclassified |',
             '| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |']
    for k, rs in by.items():
        cnt = collections.Counter()
        for r in rs:
            cnt[r['class'] or 'unclassified'] += r['bits']
        lines.append('| `%s` | %d | %d | %d | %d | %d | %d | %d |' % (
            k, sum(r['bits'] for r in rs if r['kind'] != 'mem'),
            sum(1 for r in rs if r['kind'] == 'mem'),
            cnt['arch'], cnt['region'], cnt['rebuilt'], cnt['ignored'], cnt['unclassified']))
    if seg_table:
        lines += ['', '## Scan-chain segments (inventory vs map.yaml fields)', '',
                  '| Segment | arch bits | fields bits | words | |', '| --- | ---: | ---: | ---: | --- |']
        for n, ib, fb, w in seg_table:
            lines.append('| %s | %d | %d | %d | %s |' % (
                n, ib, fb, w, '' if ib == fb else 'MISMATCH'))
        lines.append('| total | %d | %d | %d | |' % (
            sum(t[1] for t in seg_table), sum(t[2] for t in seg_table), sum(t[3] for t in seg_table)))
    if unused:
        lines += ['', '## Rules that match nothing', '']
        lines += ['- `%s`' % r['match'] for r in unused]
    lines += ['', '## Unclassified', '']
    for r in rows:
        if not r['class']:
            lines.append('- `%s` %s %d bit%s (%s)' % (
                r['path'], r['kind'], r['bits'], '' if r['bits'] == 1 else 's', r['source']))
    with open(out, 'w') as f:
        f.write('\n'.join(lines) + '\n')


def main():
    ap = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    ap.add_argument('xml')
    ap.add_argument('--classes')
    ap.add_argument('--top-alias', default='emu', help='name used for the top instance in paths')
    ap.add_argument('--csv')
    ap.add_argument('--md')
    ap.add_argument('--group-depth', type=int, default=3)
    ap.add_argument('--map', help='savestate/map.yaml: check segment/region names and fields bits')
    ap.add_argument('--fail-unclassified', action='store_true',
                    help='exit 1 on unclassified entries and on fields/inventory mismatches')
    a = ap.parse_args()

    rows = inventory(a.xml, a.top_alias)
    rules, errors = (load_rules(a.classes) if a.classes else ([], []))
    unused = classify(rows, rules)
    mismatches, seg_table = [], None
    if a.map and not errors:
        map_errors, mismatches, seg_table = check_map(rows, rules, a.map)
        errors += map_errors

    if a.csv:
        with open(a.csv, 'w', newline='') as f:
            w = csv.DictWriter(f, fieldnames=['path', 'module', 'kind', 'width', 'depth', 'bits',
                                              'class', 'segment', 'reason', 'source'])
            w.writeheader()
            w.writerows(rows)
    if a.md:
        write_md(rows, unused, a.md, a.group_depth, seg_table)

    uncl = [r for r in rows if not r['class']]
    print('storage elements: %d (%d FF bits, %d memories), unclassified: %d, unused rules: %d' % (
        len(rows), sum(r['bits'] for r in rows if r['kind'] != 'mem'),
        sum(1 for r in rows if r['kind'] == 'mem'), len(uncl), len(unused)))
    for e in errors:
        print('error: ' + e, file=sys.stderr)
    for e in mismatches:
        print('%s: %s' % ('error' if a.fail_unclassified else 'warning', e), file=sys.stderr)
    if errors or (a.fail_unclassified and (uncl or mismatches)):
        sys.exit(1)


if __name__ == '__main__':
    main()
