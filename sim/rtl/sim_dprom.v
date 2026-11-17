// Behavioral replacement of rtl/dprom.vhd (the VHDL entity is black-boxed in
// the GHDL conversion). INIT_FILE is the .mif path used by Quartus; the build
// converts every .mif to "<path>.hex" under the run directory.

module dprom #(
	parameter INIT_FILE  = "",
	parameter ADDR_WIDTH = 14,
	parameter DATA_WIDTH = 8
)(
	input                       wrclock,
	input      [ADDR_WIDTH-1:0] wraddress,
	input      [DATA_WIDTH-1:0] data,
	input                       wren,
	input                       rdclock,
	input      [ADDR_WIDTH-1:0] rdaddress,
	output     [DATA_WIDTH-1:0] q,
	input                       cs
);

reg [DATA_WIDTH-1:0] ram [1<<ADDR_WIDTH];
reg [DATA_WIDTH-1:0] q0 = 0;

initial if (INIT_FILE != "") $readmemh({INIT_FILE, ".hex"}, ram);

always @(posedge wrclock) if (wren) ram[wraddress] <= data;
always @(posedge rdclock) q0 <= ram[rdaddress];

assign q = cs ? q0 : {DATA_WIDTH{1'b1}};

endmodule
