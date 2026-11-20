//
// sdram.v
//
// sdram controller implementation for the MiST board
// http://code.google.com/p/mist-board/
// 
// Copyright (c) 2013 Till Harbaum <till@harbaum.org> 
// 
// This source file is free software: you can redistribute it and/or modify 
// it under the terms of the GNU General Public License as published 
// by the Free Software Foundation, either version 3 of the License, or 
// (at your option) any later version. 
// 
// This source file is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of 
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the 
// GNU General Public License for more details.
// 
// You should have received a copy of the GNU General Public License 
// along with this program.  If not, see <http://www.gnu.org/licenses/>. 
//

module sdram (

	// interface to the MT48LC16M16 chip
	output reg [12:0]	sd_addr,    // 13 bit multiplexed address bus
	inout  reg [15:0]	sd_data,
	output reg [ 1:0]	sd_ba,      // two banks
	output 				sd_cs,      // a single chip select
	output 				sd_we,      // write enable
	output 				sd_ras,     // row address select
	output 				sd_cas,     // columns address select
	output 				sd_clk,
	output 		[1:0]	sd_dqm,

	// cpu/chipset interface
	input 		 		init,			// init signal after FPGA config to initialize RAM
	input 		 		clk,			// sdram is accessed at up to 128MHz
	
	input      [24:0] addr,       // 25 bit byte address
	input      [ 7:0] din,
	output     [ 7:0]	dout,

	input 		 		refresh,    // refresh cycle
	input 		 		ce,         // cpu/chipset access
	input 		 		we,         // cpu/chipset requests write

	// Savestate engine transfers (rtl/savestate/ss_sdram_port.sv), only while
	// ss_own (the machine is frozen for the engine and c64.sv masks ce): 256
	// bytes of one DQ lane in one row. AUTO REFRESH, ACTIVE, then 256 single
	// column READs or WRITEs on consecutive columns, the last one with
	// auto-precharge. Handshake by toggles, sampled on clk_sys (clk64 / 2,
	// aligned edges).
	input             ss_own,
	input             ss_req,      // toggle: start a transfer
	input             ss_we,
	input      [24:0] ss_addr,     // [24] lane, [23] column 8, [22:21] bank, [20:8] row ([7:0] = 0)
	input      [63:0] ss_din,      // next word to write: byte k of the transfer is byte k%8 of word k/8
	output reg        ss_wtgl,     // toggle: ss_din taken
	output reg [63:0] ss_dout,     // last word read
	output reg        ss_rtgl,     // toggle: ss_dout holds the next word read
	output reg        ss_dtgl      // toggle: transfer done, every bank precharged
);

initial begin
	ss_wtgl = 0;
	ss_dout = 0;
	ss_rtgl = 0;
	ss_dtgl = 0;
end

// no burst configured
localparam RASCAS_DELAY   = 3'd2;   // tRCD>=20ns -> 2 cycles@64MHz
localparam BURST_LENGTH   = 3'b000; // 000=none, 001=2, 010=4, 011=8
localparam ACCESS_TYPE    = 1'b0;   // 0=sequential, 1=interleaved
localparam CAS_LATENCY    = 3'd2;   // 2/3 allowed
localparam OP_MODE        = 2'b00;  // only 00 (standard operation) allowed
localparam NO_WRITE_BURST = 1'b1;   // 0= write burst enabled, 1=only single access write

localparam MODE = { 3'b000, NO_WRITE_BURST, OP_MODE, CAS_LATENCY, ACCESS_TYPE, BURST_LENGTH}; 

// ---------------------------------------------------------------------
// ------------------------ cycle state machine ------------------------
// ---------------------------------------------------------------------

localparam STATE_CMD_START = 3'd0;   // state in which a new command can be started
localparam STATE_CMD_CONT  = STATE_CMD_START  + RASCAS_DELAY; // command can be continued
localparam STATE_READ      = STATE_CMD_CONT + CAS_LATENCY + 1'd1;
localparam STATE_LAST      = 3'd7;   // last state in cycle

reg [2:0] q /* synthesis noprune */;
reg last_ce, last_refresh;
always @(posedge clk) begin
	last_ce <= ce;
	last_refresh <= refresh;

	// start a new cycle in rising edge of ce
	if(ce && !last_ce) q <= 3'd1;
	if(q || reset) q <= q + 3'd1;
end

// ---------------------------------------------------------------------
// --------------------------- startup/reset ---------------------------
// ---------------------------------------------------------------------

// wait 1ms (32 clkref cycles) after FPGA config is done before going
// into normal operation. Initialize the ram in the last 16 reset cycles (cycles 15-0)
initial reset = 5'h1f;

reg [4:0] reset;
always @(posedge clk) begin
	if(init)	reset <= 5'h1f;
	else if((q == STATE_LAST) && (reset != 0)) reset <= reset - 5'd1;
end

// ---------------------------------------------------------------------
// ------------------ generate ram control signals ---------------------
// ---------------------------------------------------------------------

// all possible commands
localparam CMD_NOP             = 3'b111;
localparam CMD_ACTIVE          = 3'b011;
localparam CMD_READ            = 3'b101;
localparam CMD_WRITE           = 3'b100;
localparam CMD_BURST_TERMINATE = 3'b110;
localparam CMD_PRECHARGE       = 3'b010;
localparam CMD_AUTO_REFRESH    = 3'b001;
localparam CMD_LOAD_MODE       = 3'b000;

reg [2:0] sd_cmd;   // current command sent to sd ram

// drive control signals according to current command
assign sd_cs  = 0;
assign sd_ras = sd_cmd[2];
assign sd_cas = sd_cmd[1];
assign sd_we  = sd_cmd[0];
assign sd_dqm = sd_addr[12:11];

reg bt;
reg [15:0] dout_r;

assign dout = bt ? dout_r[15:8] : dout_r[7:0];

// ---------------------------------------------------------------------
// ------------------ savestate engine transfers -----------------------
// ---------------------------------------------------------------------

// ss_q: 1 and 6 AUTO REFRESH, 11 ACTIVE (tRFC 5 after each), then the 256
// columns of the row, the last with auto-precharge. WRITE at 13..268, one
// per clk64 (the data leaves the output register as for a single WRITE),
// done at 273 (tWR 2 + tRP 2). READ every other clk64 at 13, 15, ..., 523,
// read data in dout_r three clocks after each READ (CAS 2, as STATE_READ),
// lane byte into the word one clock later, done at 528: READs one clk64
// apart lost bits on the board (the next column's data reached the DQ input
// register at the capture edge, a pad-timing effect the command-level
// checker cannot see), so each READ has the bus to itself for two clocks
// like the single READ of the normal path. A row stays open 513 clk64 at
// most (8.1 us, tRAS max 120 us); two AUTO REFRESH per transfer keep 8192
// within 64 ms with read transfers back to back (one per ~267 clk64 on
// average); refresh edges of the machine arriving during a transfer are
// dropped. The sequencer starts only while ss_own, with the normal cycle
// idle (q 0), at least 5 clk64 (tRFC) after the last AUTO REFRESH, not on
// the clock where the normal path issues one and once the normal path has
// issued one since the init (with the transfer's own, the two the chip needs
// before its first ACTIVE): with ss_own low ss_q stays 0 and the normal path
// below is the original controller.
localparam [9:0] SS_RF2 = 10'd6, SS_ACT = 10'd11, SS_COL0 = 10'd13, SS_WLAST = 10'd268, SS_RLAST = 10'd523;

reg  [9:0] ss_q = 0;
reg        ss_seen = 0, ss_wr = 0, ss_bt = 0, ss_init = 0;
reg  [3:0] ss_rfc = 0;      // clk64 since the last AUTO REFRESH, saturating
reg [55:0] ss_acc = 0;      // bytes 0-6 of the word being read
reg [55:0] ss_wsh = 0;      // bytes 1-7 of the word being written
wire       ss_go   = ss_own && (ss_req != ss_seen) && !q && !ss_q && !reset && ss_init &&
                     ss_rfc >= 4'd5 && !(refresh && !last_refresh);
wire [9:0] ss_off  = ss_q - SS_COL0;
wire       ss_cmd  = ss_q >= SS_COL0 && (ss_wr ? ss_q <= SS_WLAST : ss_q <= SS_RLAST && ss_q[0]);
wire       ss_last = ss_q == (ss_wr ? SS_WLAST : SS_RLAST);
wire [7:0] ss_col  = ss_wr ? ss_off[7:0] : ss_off[8:1];   // column of the WRITE/READ at ss_q
wire [9:0] ss_roff = ss_q - 10'd17;
wire [7:0] ss_rcol = ss_roff[8:1];                         // column whose byte leaves dout_r at ss_q 17, 19, ..., 527
wire [7:0] ss_byte = ss_col[2:0] ? ss_wsh[7:0] : ss_din[7:0];

always @(posedge clk) begin
	if(ss_go) begin
		ss_q    <= 10'd1;
		ss_seen <= ss_req;
		ss_wr   <= ss_we;
		ss_bt   <= ss_addr[24];
	end
	else if(ss_q) begin
		if(ss_q == (ss_wr ? SS_WLAST : SS_RLAST) + 10'd5) begin
			ss_q    <= 0;
			ss_dtgl <= ~ss_dtgl;
		end
		else ss_q <= ss_q + 1'd1;
	end

	if((ss_q == 10'd1) || (ss_q == SS_RF2) || (!reset && !ss_q && refresh && !last_refresh)) ss_rfc <= 0;
	else if(ss_rfc != 4'd15) ss_rfc <= ss_rfc + 1'd1;
	if(reset) ss_init <= 0;
	else if(!ss_q && refresh && !last_refresh) ss_init <= 1;

	// write: a new word at columns 0, 8, ..., 248
	if(ss_wr && ss_cmd) begin
		if(!ss_col[2:0]) begin
			ss_wsh  <= ss_din[63:8];
			ss_wtgl <= ~ss_wtgl;
		end
		else ss_wsh <= ss_wsh >> 8;
	end

	// read: the lane byte of every column, a word every eight
	if(!ss_wr && ss_q >= 10'd17 && ss_q <= 10'd527 && ss_q[0]) begin
		if(&ss_rcol[2:0]) begin
			ss_dout <= {ss_bt ? dout_r[15:8] : dout_r[7:0], ss_acc};
			ss_rtgl <= ~ss_rtgl;
		end
		else ss_acc <= {ss_bt ? dout_r[15:8] : dout_r[7:0], ss_acc[55:8]};
	end
end

always @(posedge clk) begin
	reg [8:0] caddr;
	reg [7:0] wrdata;
	reg       wr;

	sd_cmd  <= CMD_NOP;
	sd_data <= 16'bZ;

	if(q == STATE_READ || (!ss_wr && ss_q >= 10'd16 && ss_q <= 10'd526 && !ss_q[0])) dout_r <= sd_data;

	if(reset) begin
		sd_ba <= 0;
		if(q == STATE_CMD_START) begin
			if(reset == 13) begin
				sd_cmd <= CMD_PRECHARGE;
				sd_addr <= 13'b0010000000000;
			end
			if(reset == 2) begin
				sd_cmd <= CMD_LOAD_MODE;
				sd_addr <= MODE;
			end
		end
	end
	else if(ss_q) begin
		if(ss_q == 10'd1 || ss_q == SS_RF2) sd_cmd <= CMD_AUTO_REFRESH;
		if(ss_q == SS_ACT) begin
			sd_cmd  <= CMD_ACTIVE;
			sd_ba   <= ss_addr[22:21];
			sd_addr <= ss_addr[20:8];
		end
		if(ss_cmd) begin
			if(ss_wr) sd_data <= {ss_byte, ss_byte};
			sd_cmd  <= ss_wr ? CMD_WRITE : CMD_READ;
			sd_addr <= {~ss_bt & ss_wr, ss_bt & ss_wr, ss_last, 1'b0, ss_addr[23], ss_col};
		end
	end
	else begin
		if(refresh && !last_refresh) sd_cmd <= CMD_AUTO_REFRESH;

		if(ce && !last_ce) begin
			sd_cmd  <= CMD_ACTIVE;
			sd_ba   <= addr[22:21];
			sd_addr <= addr[20:8];
			caddr   <= {addr[23], addr[7:0]};
			bt      <= addr[24];
			wr      <= we;
			wrdata  <= din;
		end
		if(q == STATE_CMD_CONT) begin
			if(wr) sd_data <= {wrdata, wrdata};
			sd_cmd  <= wr ? CMD_WRITE : CMD_READ;
			sd_addr <= {~bt & wr, bt & wr, 2'b10, caddr};
		end
	end
end

altddio_out
#(
	.extend_oe_disable("OFF"),
	.intended_device_family("Cyclone V"),
	.invert_output("OFF"),
	.lpm_hint("UNUSED"),
	.lpm_type("altddio_out"),
	.oe_reg("UNREGISTERED"),
	.power_up_high("OFF"),
	.width(1)
)
sdramclk_ddr
(
	.datain_h(1'b0),
	.datain_l(1'b1),
	.outclock(clk),
	.dataout(sd_clk),
	.aclr(1'b0),
	.aset(1'b0),
	.oe(1'b1),
	.outclocken(1'b1),
	.sclr(1'b0),
	.sset(1'b0)
);

endmodule
