// Savestate scan chain: segment helpers (SystemVerilog).
//
// The machine state travels on ONE serial chain in clk_sys (contract in
// savestate/map.yaml). Each chip WP turns its own registers into a piece of
// that chain: one 2:1 mux per flip-flop, no shadow copy, no wide bus.
//
//   engine.chain_so -> [last segment] -> ... -> [VIC] -> [CPU] -> engine.chain_si
//
// The first segment of map.yaml (CPU) sits next to the engine input, so its
// bit 0 is the first bit that leaves the chain: bit k of a segment is chain
// bit (SS_<SEG>_OFFSET + k), i.e. field offsets of map.yaml are bit indexes of
// the segment vector 'q' below. While scan_en is high the chip is frozen
// (c64_pause / freeze_ack) and every clock moves the whole chain by one bit;
// the engine moves it by exactly SS_CHAIN_BITS per save (rotation: the state
// is left as it was) or per load (the slot bits are shifted in).
//
// Instrumenting a chip (pattern, one always block per register group):
//
//   wire [W-1:0] ss_q = {reg_c, reg_b, reg_a};   // reg_a[0] leaves first
//   wire [W-1:0] ss_d;
//   ss_chain_seg #(.W(W)) ss_seg(.q(ss_q), .scan_in(ss_si), .d(ss_d), .scan_out(ss_so));
//   always @(posedge clk) begin
//       if (ss_scan_en) {reg_c, reg_b, reg_a} <= ss_d;   // priority over all
//       else begin ... normal logic ... end              // other assignments
//   end
//
// Registers in several always blocks: split the segment in sub-segments
// chained inside the module (ss_si -> seg1 -> seg2 -> ss_so). Loose state that
// lives in the top (no module of its own) uses ss_chain_reg. A segment with no
// bits yet (map.yaml reservation) is a plain wire: ss_chain_seg #(.W(0)).

module ss_chain_seg #(parameter W = 1)
(
	input  [(W>0?W:1)-1:0] q,        // current value of the segment registers
	input                  scan_in,  // from the next segment (towards the engine output)
	output [(W>0?W:1)-1:0] d,        // value to load when scan_en
	output                 scan_out  // to the previous segment (towards the engine input)
);

generate
	if (W == 0) begin : empty
		assign d        = 1'b0;
		assign scan_out = scan_in;
	end
	else if (W == 1) begin : one
		assign d        = scan_in;
		assign scan_out = q[0];
	end
	else begin : many
		assign d        = {scan_in, q[W-1:1]};
		assign scan_out = q[0];
	end
endgenerate

endmodule

// A register that only exists for the chain or keeps loose top-level state:
// normal write port (we/din) plus the chain. INIT is the power-on value.
module ss_chain_reg #(parameter W = 1, parameter [W-1:0] INIT = '0)
(
	input              clk,
	input              scan_en,
	input              scan_in,
	output             scan_out,
	input              we,
	input      [W-1:0] din,
	output reg [W-1:0] q = INIT
);

wire [W-1:0] d;
ss_chain_seg #(.W(W)) seg(.q(q), .scan_in(scan_in), .d(d), .scan_out(scan_out));

always @(posedge clk) begin
	if (scan_en) q <= d;
	else if (we) q <= din;
end

endmodule
