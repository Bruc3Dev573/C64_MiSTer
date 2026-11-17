////////////////////////////////////////////////////////////////////////////////
//
//  C1351 Mouse
//  (C) 2019 Sorgelig
//
//  This program is free software; you can redistribute it and/or modify it
//  under the terms of the GNU General Public License as published by the Free
//  Software Foundation; either version 2 of the License, or (at your option)
//  any later version.
//
//  This program is distributed in the hope that it will be useful, but WITHOUT
//  ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
//  FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License for
//  more details.
//
//  You should have received a copy of the GNU General Public License along
//  with this program; if not, write to the Free Software Foundation, Inc.,
//  51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
//
////////////////////////////////////////////////////////////////////////////////

// Savestate (WP A7, segment INPUT): x, y, lfsr on the chain (bit 0 leaves
// first: lfsr, x, y). The pot noise LFSR steps with the machine (stop);
// movements made while paused still move the pointer, they only wait while
// the engine owns the machine (ss_hold), then they are applied.
module c1351
(
	input        clk_sys,
	input        reset,

	input [24:0] ps2_mouse,
	
	output [7:0] potX,
	output [7:0] potY,
	output [1:0] button,

	input        stop,
	input        ss_en,
	input        ss_hold,
	input        ss_si,
	output       ss_so
);

reg [16:0] lfsr;
reg  [5:0] x;
reg  [5:0] y;

wire [28:0] ss_q = {y, x, lfsr};
wire [28:0] ss_d = {ss_si, ss_q[28:1]};
assign ss_so = ss_q[0];

always @(posedge clk_sys) begin
	if (ss_en) lfsr <= ss_d[16:0];
	else if (~stop) lfsr <= {(lfsr[0] ^ lfsr[2] ^ !lfsr), lfsr[16:1]};
end

assign potX = ~{1'b0, x, lfsr[0]};
assign potY = ~{1'b0, y, lfsr[8]};
assign button = ps2_mouse[1:0];

always @(posedge clk_sys) begin
	reg old_status;

	if (ss_en) {y, x} <= ss_d[28:17];
	else if (~ss_hold) begin
		old_status <= ps2_mouse[24];

		if(reset) begin
			x <= 0;
			y <= 0;
		end else begin
			if(old_status != ps2_mouse[24]) begin
				x <= x + ps2_mouse[13:8];
				y <= y + ps2_mouse[21:16];
			end
		end
	end
end

endmodule
