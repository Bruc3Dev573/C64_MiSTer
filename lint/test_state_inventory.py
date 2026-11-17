#!/usr/bin/env python3
"""Self-test of state_inventory.py on a tiny design (needs verilator)."""
import os
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import state_inventory as si  # noqa: E402

DESIGN = r'''
module leaf(input clk, input [3:0] d, output reg [3:0] q);
  reg [7:0] mem [0:15];
  reg [3:0] tmp;
  always @(posedge clk) begin
    q <= d;
    mem[d] <= {d, d};
    tmp = d;
  end
endmodule
module top(input clk, input [3:0] d, output [3:0] q0, output [3:0] q1, output [2:0] q2);
  reg en;
  always @(posedge clk) en <= ~en;
  // a function argument with the name of a register must not change its width
  function [2:0] f(input [2:0] en); f = ~en; endfunction
  assign q2 = f(d[2:0]);
  always @(posedge clk) begin reg [1:0] old; old <= d[1:0]; end
  always @(posedge clk) begin reg [2:0] old; old <= d[2:0]; end
  genvar i;
  generate for (i = 0; i < 2; i = i + 1) begin : g
    leaf l(.clk(clk), .d(d), .q());
  end endgenerate
  wire c = clk;
  leaf a(.clk(clk), .d(d), .q(q0));
  leaf b(.clk(c), .d(d & {4{en}}), .q(q1));
endmodule
'''

RULES = '''
- match: "emu.g[1].*"
  class: arch
  segment: TEST1
- match: "emu.a.*"
  class: arch
  segment: TEST
- match: "emu.*.mem"
  class: region
  segment: TESTMEM
'''


def main():
    with tempfile.TemporaryDirectory() as t:
        v = os.path.join(t, 'd.v')
        x = os.path.join(t, 'd.xml')
        r = os.path.join(t, 'r.yaml')
        open(v, 'w').write(DESIGN)
        open(r, 'w').write(RULES)
        subprocess.check_call(['verilator', '--xml-only', '--xml-output', x, '-Wno-fatal',
                               '-Wno-lint', '-Wno-style', '--top-module', 'top', v])
        rows = si.inventory(x, 'emu')
        got = {(row['path'], row['kind'], row['bits']) for row in rows}
        want = {('emu.en', 'ff', 1), ('emu.old', 'ff', 2), ('emu.old#2', 'ff', 3),
                ('emu.g[0].l.q', 'ff', 4), ('emu.g[0].l.mem', 'mem', 128), ('emu.g[0].l.tmp', 'ff?', 4),
                ('emu.g[1].l.q', 'ff', 4), ('emu.g[1].l.mem', 'mem', 128), ('emu.g[1].l.tmp', 'ff?', 4),
                ('emu.a.q', 'ff', 4), ('emu.a.mem', 'mem', 128), ('emu.a.tmp', 'ff?', 4),
                ('emu.b.q', 'ff', 4), ('emu.b.mem', 'mem', 128), ('emu.b.tmp', 'ff?', 4)}
        assert got == want, 'inventory mismatch:\n got  %s\n want %s' % (sorted(got), sorted(want))
        rules, errors = si.load_rules(r)
        assert not errors, errors
        si.classify(rows, rules)
        cls = {row['path']: row['class'] for row in rows}
        assert cls['emu.a.q'] == 'arch' and cls['emu.a.mem'] == 'arch', cls
        assert cls['emu.b.mem'] == 'region' and cls['emu.b.q'] == '' and cls['emu.en'] == '', cls
        # brackets are literal: g[1] matches only the second generate scope
        assert cls['emu.g[1].l.q'] == 'arch' and cls['emu.g[0].l.q'] == '', cls
    print('state_inventory self-test OK')


if __name__ == '__main__':
    main()
