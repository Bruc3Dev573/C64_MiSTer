// xorshift noise source of the 1541 GCR read logic (c1541_direct_gcr).
// Savestate (WP A8): it steps on the drive clock enable, so it stops with the
// machine, and its value travels on the chain (ss_en shifts, bit 0 out first).
module random_xor (
	input clock,
	input reset,
	input ce,
	input [31:0] seed,
	output reg [31:0] lfsr,

	input ss_en,
	input ss_si,
	output ss_so
);

assign ss_so = lfsr[0];

always @(posedge clock) begin
	if (ss_en) begin
		lfsr <= {ss_si, lfsr[31:1]};
	end else if (reset) begin
		// initialize with non-zero seed
		lfsr <= (seed != 0) ? seed : 32'h1234abcd;
	end else if (ce) begin
		lfsr <=  ((lfsr ^ (lfsr << 13)) ^ ((lfsr ^ (lfsr << 13)) >> 17)) ^
		        (((lfsr ^ (lfsr << 13)) ^ ((lfsr ^ (lfsr << 13)) >> 17)) << 5);
		end
end

endmodule
