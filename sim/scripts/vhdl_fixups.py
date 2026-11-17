#!/usr/bin/env python3
"""Make Quartus-flavoured VHDL acceptable to GHDL (used by the sim/lint flows).

The sources in rtl/ are never modified: the flows copy them to a build
directory and run this script on the copies. Every fixup is semantics
preserving for synthesis and for 0/1 simulation:

  * case statements on std_logic_vector without "when others" get one
    ("when others => null;"), GHDL rejects them as missing choices;
  * "label: work.ent" instantiations get the missing "entity" keyword.
"""
import re
import sys

CASE_OPEN = re.compile(r'^\s*case\b.*\bis\b', re.I)
CASE_END = re.compile(r'^(\s*)end\s+case\b', re.I)
OTHERS = re.compile(r'^\s*when\s+others\b', re.I)
INST = re.compile(r'^(\s*\w+\s*:\s*)(work\.\w+)', re.I)


def strip_comment(line):
    return line.split('--', 1)[0]


def fix(text):
    out = []
    stack = []  # one entry per open case: has "when others" been seen
    for line in text.splitlines(keepends=True):
        code = strip_comment(line)
        m = CASE_END.match(code)
        if m and stack:
            if not stack.pop():
                nl = '\r\n' if line.endswith('\r\n') else '\n'
                out.append(m.group(1) + '\twhen others => null;' + nl)
        elif CASE_OPEN.match(code):
            stack.append(False)
        elif OTHERS.match(code) and stack:
            stack[-1] = True
        line = INST.sub(lambda mm: mm.group(1) + 'entity ' + mm.group(2), line)
        out.append(line)
    return ''.join(out)


if __name__ == '__main__':
    for path in sys.argv[1:]:
        with open(path, newline='') as f:
            src = f.read()
        new = fix(src)
        if new != src:
            with open(path, 'w', newline='') as f:
                f.write(new)
