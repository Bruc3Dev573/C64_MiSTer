#!/usr/bin/env python3
"""Make Quartus-flavoured Verilog/SystemVerilog acceptable to Verilator.

Runs on copies in the build directory, rtl/ is never modified.

  * "wire [w] name [N] = '{...};" constant tables become localparams
    (Quartus accepts an initialized unpacked wire array, Verilator does not);
  * "function f(wire x)" arguments become "input";
  * variables declared with an initializer inside a procedural block
    ("reg [7:0] counter = 0;" inside an always block): Verilator rejects the
    mix of the implicit blocking init and the non-blocking updates. Zero
    initializers are dropped (the sim is built with --x-initial 0, the FPGA
    power-up value); non-zero ones are hoisted to module scope right before
    the always block, which keeps the power-up value;
  * port names on instances of modules converted from VHDL by GHDL are
    matched case-insensitively to the ports GHDL emitted (VHDL is case
    insensitive, Verilog is not), the module name too (GHDL lower-cases
    entity names), and std_logic inputs left unconnected get the default
    value of the VHDL port declaration (lost in the conversion; e.g. T65
    BCD_en := '1'). Generated Verilog and fixed-up VHDL are found through the
    GEN_DIR and VHDL_DIR environment variables.
"""
import glob
import os
import re
import sys

TABLE = re.compile(r"^(\s*)wire\s+(signed\s+)?(\[[^\]]*\])\s*(\w+)\s*(\[[^\]]*\])\s*=")
DECL = re.compile(r"^(\s+)(reg|logic|integer|bit)\b(\s*(?:signed\s*)?(?:\[[^\]]*\])?\s*)(.*?);(.*)$")
ZERO = re.compile(r"^\s*(0+|\d*'[bdhBDHsS]*0+|'0)\s*$")
PROC = re.compile(r'^\s*(always\w*|initial)\b')


def gen_ports():
    """module(lower) -> {port(lower): emitted name}"""
    mods = {}
    for f in glob.glob(os.path.join(os.environ.get('GEN_DIR', '.'), '*.v')):
        for m in re.finditer(r'^module\s+(\w+)\s*\(([^;]*)\);', open(f).read(), re.M):
            ports = {}
            for p in m.group(2).split(','):
                p = p.strip()
                if p:
                    ports[p.lstrip('\\').lower()] = p
            mods[m.group(1).lower()] = ports
    return mods


def vhdl_defaults():
    """entity(lower) -> {port(lower): verilog constant} for std_logic inputs with a default"""
    ents = {}
    for f in glob.glob(os.path.join(os.environ.get('VHDL_DIR', '.'), '*.vhd')):
        text = re.sub(r'--[^\n]*', '', open(f).read())
        for m in re.finditer(r'\bentity\s+(\w+)\s+is(.*?)\bend\b', text, re.S | re.I):
            d = {}
            for pm in re.finditer(r"(\w+)\s*:\s*in\s+std_logic\s*:=\s*'([01])'", m.group(2), re.I):
                d[pm.group(1).lower()] = "1'b" + pm.group(2)
            ents[m.group(1).lower()] = d
    return ents


MODS = gen_ports()
DEFAULTS = vhdl_defaults()
INST_START = re.compile(r'^(\s*)(\w+)(\s+(?:#\s*\(.*\)\s*)?\w+\s*\(?\s*)$')


def fix_instance(lines, mod):
    """lines of one instance of a converted module: port case + defaults"""
    ports = MODS[mod]
    text = ''.join(lines)
    def port(mm):
        name = ports.get(mm.group(1).lower(), mm.group(1))
        return '.' + name + (' (' if name.startswith('\\') else '(')
    text = re.sub(r'\.([A-Za-z_]\w*)\s*\(', port, text)
    connected = {c.lstrip('\\').lower() for c in re.findall(r'\.(\\?\w+)\s*\(', text)}
    missing = [(p, v) for p, v in DEFAULTS.get(mod, {}).items() if p not in connected and p in ports]
    if missing:
        i = text.index('(', text.index(mod) + len(mod)) if '#' not in text.split('(')[0] else text.index('(', text.index(')') + 1)
        ins = ''.join(f"\n\t.{ports[p]}({v}), // VHDL default, added by sim fixup" for p, v in missing)
        text = text[:i + 1] + ins + text[i + 1:]
    return text


def split_top(s):
    parts, depth, cur = [], 0, ''
    for ch in s:
        if ch in '([{':
            depth += 1
        elif ch in ')]}':
            depth -= 1
        if ch == ',' and depth == 0:
            parts.append(cur)
            cur = ''
        else:
            cur += ch
    parts.append(cur)
    return parts


def fix(text, path):
    out = []
    in_proc = False
    depth = 0
    opened = False
    proc_at = 0          # index in out where the current always/initial starts
    inst = None
    inst_mod = None
    for line in text.splitlines(keepends=True):
        nl = '\r\n' if line.endswith('\r\n') else '\n'
        code = line.split('//', 1)[0]
        if TABLE.match(line):
            line = TABLE.sub(lambda mm: f"{mm.group(1)}localparam logic {mm.group(2) or ''}{mm.group(3)} {mm.group(4)} {mm.group(5)} =", line)
        if re.match(r'^\s*function\b', code):
            line = re.sub(r'([(,]\s*)wire\b', r'\1input', line)
        if not in_proc and PROC.match(code):
            in_proc, depth, opened, proc_at = True, 0, False, len(out)
        if in_proc:
            n_begin = len(re.findall(r'\bbegin\b', code))
            depth += n_begin
            opened = opened or n_begin > 0
            m = DECL.match(code.rstrip('\r\n'))
            if m and depth > 0 and '=' in m.group(4):
                ind, kind, rng, decls = m.group(1), m.group(2), m.group(3), m.group(4)
                keep, hoist = [], []
                for d in split_top(decls):
                    if '=' in d:
                        name, val = d.split('=', 1)
                        if ZERO.match(val):
                            keep.append(name.strip())
                        else:
                            hoist.append(d.strip())
                    else:
                        keep.append(d.strip())
                line = f"{ind}{kind}{rng}{', '.join(keep)};{nl}" if keep else nl
                if hoist:
                    out.insert(proc_at, f"{kind}{rng}{', '.join(hoist)}; // hoisted by sim fixup{nl}")
                    proc_at += 1
            depth -= len(re.findall(r'\bend\b', code))
            if depth <= 0 and (opened or ';' in code):
                in_proc = False
        m = INST_START.match(code) if not inst else None
        if m and m.group(2).lower() in MODS and m.group(2) not in ('module', 'always', 'assign'):
            line = m.group(1) + m.group(2).lower() + line[len(m.group(1)) + len(m.group(2)):]
            inst, inst_mod = [], m.group(2).lower()
        if inst is not None:
            inst.append(line)
            if re.search(r'\)\s*;', code):
                out.append(fix_instance(inst, inst_mod))
                inst = None
            continue
        out.append(line)
    return ''.join(out)


if __name__ == '__main__':
    for path in sys.argv[1:]:
        with open(path, newline='') as f:
            src = f.read()
        new = fix(src, path)
        if new != src:
            with open(path, 'w', newline='') as f:
                f.write(new)
