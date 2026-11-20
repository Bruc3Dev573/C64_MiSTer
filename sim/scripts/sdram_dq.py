#!/usr/bin/env python3
"""Copy rtl/sdram.v for Verilator: separate the registered DQ value and enable.

Verilator 5.020 cannot lower a procedural assignment of Z. The controller's
state machine stays intact; only the tristate DQ register is rewritten into a
registered value/enable pair and a continuous tristate assignment.

    sdram_dq.py rtl/sdram.v out/sdram.v
"""
import pathlib
import re
import sys

s = pathlib.Path(sys.argv[1]).read_text()
s, n = re.subn(r'inout\s+reg(\s+\[15:0\]\s+sd_data)', r'inout wire\1', s)
assert n == 1, "SDRAM DQ declaration changed"
for old, new in (
    ("reg bt;", "reg [15:0] sim_dq_out;\nreg sim_dq_oe;\nassign sd_data = sim_dq_oe ? sim_dq_out : 16'bz;\nreg bt;"),
    ("sd_data <= 16'bZ;", "sim_dq_oe <= 0;"),
    ("if(wr) sd_data <= {wrdata, wrdata};", "if(wr) begin sim_dq_out <= {wrdata, wrdata}; sim_dq_oe <= 1; end"),
    ("if(ss_wr) sd_data <= {ss_byte, ss_byte};", "if(ss_wr) begin sim_dq_out <= {ss_byte, ss_byte}; sim_dq_oe <= 1; end"),
):
    assert s.count(old) == 1, "SDRAM DQ assignment changed: " + old
    s = s.replace(old, new)
pathlib.Path(sys.argv[2]).write_text(s)
