// DDR3 arbiter between the 1541 track cache and the savestate engine (WP A2, D13).
//
// DDRAM_CLK is clk_sys. Two Avalon masters share the port at burst
// granularity: the drives (c1541_multi -> c1541_track: burst reads, single
// writes) and the savestate engine (32-word burst reads into its FIFO, burst
// writes out of it, single header words). The owner keeps the port while the
// other side does not request. When the other side requests, ownership moves
// as soon as the owner has nothing accepted left (no write burst under way,
// no read beat outstanding, no command accepted on this clock); a command of
// the owner that was not accepted yet waits for its next turn. Both sides
// requesting all the time alternate burst by burst, so neither starves. A
// request of the side that does not own the port sees busy and holds, as
// Avalon allows (the drive DMA FSM holds its request; the drives issue none
// while the machine is stopped, A8).
//
// Address map (64-bit word addresses, byte address = word * 8; D13):
//   savestate scratch  0x052E0000 ..  (bytes 0x29700000, 21 MiB, self-test, not declared to Main)
//   savestate slots    0x05580000 ..  (bytes 0x2AC00000, SS2AC00000:1500000, 4 x 21 MiB)
//   drive 8 G64 image  0x06000000 + offset  (bytes 0x30000000 + ...)
//   drive 9 G64 image  0x06040000 + offset  (bytes 0x30200000 + ...)
// The track offsets come from the G64 header loaded by Main (an image of at
// most a few hundred KiB). A corrupt header could still point anywhere:
// drive writes outside the drive image window 0x30000000-0x30FFFFFF are
// accepted and dropped, so the track cache never writes a slot, the scratch
// slot or any other DDR3 user.

module ss_ddram_arb
(
	input             clk,

	// drive track cache (Avalon master)
	input       [7:0] d_burstcnt,
	input      [28:0] d_addr,
	input             d_rd,
	input             d_we,
	input      [63:0] d_din,
	input       [7:0] d_be,
	output            d_busy,
	output            d_dout_ready,
	output            d_idle,        // nothing requested, no read beat outstanding

	// savestate engine (Avalon master)
	input       [7:0] e_burstcnt,
	input      [28:0] e_addr,
	input             e_rd,
	input             e_we,
	input      [63:0] e_din,
	input       [7:0] e_be,
	output            e_busy,
	output            e_dout_ready,

	// DDR3
	input             DDRAM_BUSY,
	output      [7:0] DDRAM_BURSTCNT,
	output     [28:0] DDRAM_ADDR,
	input      [63:0] DDRAM_DOUT,
	input             DDRAM_DOUT_READY,
	output            DDRAM_RD,
	output            DDRAM_WE,
	output     [63:0] DDRAM_DIN,
	output      [7:0] DDRAM_BE
);

reg        own = 0;                 // 1: the engine owns the port
reg  [8:0] d_out = 0, e_out = 0;    // read beats outstanding
reg  [7:0] d_wl = 0, e_wl = 0;      // beats left of an accepted write burst

wire guard = d_we & (d_addr[28:21] != 8'h30);   // drive write outside 0x30000000-0x30FFFFFF

assign DDRAM_BURSTCNT = own ? e_burstcnt : d_burstcnt;
assign DDRAM_ADDR     = own ? e_addr     : d_addr;
assign DDRAM_DIN      = own ? e_din      : d_din;
assign DDRAM_BE       = own ? e_be       : d_be;
assign DDRAM_RD       = own ? e_rd       : d_rd;
assign DDRAM_WE       = own ? e_we       : (d_we & ~guard);

assign d_busy       = own | (DDRAM_BUSY & ~guard);
assign e_busy       = ~own | DDRAM_BUSY;
assign d_dout_ready = ~own & DDRAM_DOUT_READY;
assign e_dout_ready = own & DDRAM_DOUT_READY;
assign d_idle       = ~d_rd & ~d_we & (d_out == 0);

// a command or write beat accepted on this clock
wire d_acc  = ~own & ((d_rd & ~DDRAM_BUSY) | (d_we & (guard | ~DDRAM_BUSY)));
wire e_acc  =  own & (e_rd | e_we) & ~DDRAM_BUSY;
wire d_done = ~d_acc & (d_out == 0) & (d_wl == 0);
wire e_done = ~e_acc & (e_out == 0) & (e_wl == 0);

always @(posedge clk) begin
	if (~own) begin
		if (d_rd & ~DDRAM_BUSY) d_out <= d_out + d_burstcnt - (DDRAM_DOUT_READY ? 1'd1 : 1'd0);
		else if (DDRAM_DOUT_READY && d_out) d_out <= d_out - 1'd1;
		if (d_we & ~guard & ~DDRAM_BUSY) d_wl <= (d_wl ? d_wl : d_burstcnt) - 1'd1;
		if (e_rd | e_we) begin
			if (d_done) own <= 1;
		end
	end
	else begin
		if (e_rd & ~DDRAM_BUSY) e_out <= e_out + e_burstcnt - (DDRAM_DOUT_READY ? 1'd1 : 1'd0);
		else if (DDRAM_DOUT_READY && e_out) e_out <= e_out - 1'd1;
		if (e_we & ~DDRAM_BUSY) e_wl <= (e_wl ? e_wl : e_burstcnt) - 1'd1;
		if (d_rd | d_we) begin
			if (e_done) own <= 0;
		end
	end
end

endmodule
