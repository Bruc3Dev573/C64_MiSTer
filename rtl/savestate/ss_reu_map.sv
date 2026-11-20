// REU pages written since power on (D13): one bit per 4 KiB page of the
// SDRAM REU lane (byte addresses 0x1000000-0x1FFFFFF, DQ lane 1). A bit is
// set by every write of the machine into the lane (REU DMA, REU file load,
// any other writer: c64.sv feeds the SDRAM mux while the engine does not
// own it) and kept across every core reset, as the REU keeps its data. The
// savestate engine reads it to save only the written pages and writes it
// when a load restores (1) or zeroes (0) a page. All zero at FPGA
// configuration, when c64.sv zero-fills the lane: zero is the power-on
// content of a page whose bit is 0.

module ss_reu_map
(
	input             clk,

	input             trk_we,       // the machine writes the REU lane
	input      [11:0] trk_page,

	input             eng_we,       // savestate engine (the machine is frozen)
	input      [11:0] eng_page,
	input             eng_bit,
	input      [11:0] rd_page,
	output reg        q = 0         // bit of rd_page, one clock later
);

reg map [0:4095];

integer i;
initial for (i = 0; i < 4096; i = i + 1) map[i] = 1'b0;

always @(posedge clk) begin
	if (eng_we | trk_we) map[eng_we ? eng_page : trk_page] <= eng_we ? eng_bit : 1'b1;
	q <= map[rd_page];
end

endmodule
