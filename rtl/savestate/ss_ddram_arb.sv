// DDR3 arbiter between the 1541 track cache and the savestate engine (WP A2).
//
// DDRAM_CLK is clk_sys. The drives (c1541_multi -> c1541_track) own the port
// by default. While the engine runs a save or load (session) the port is
// handed over as soon as the drive side has no request and no read beat
// outstanding; the drive side then sees DDRAM_BUSY and waits (its DMA FSM
// holds its request, as Avalon allows). The engine does single 64-bit
// accesses (burst 1, no cache).
//
// Address map (64-bit word addresses, byte address = word * 8):
//   drive 8 G64 image  0x06000000 + offset  (bytes 0x30000000 + ...)
//   drive 9 G64 image  0x06040000 + offset  (bytes 0x30200000 + ...)
//   self-test scratch  0x07B00000 ..         (bytes 0x3D800000, 8 MiB, not declared to Main)
//   savestate slots    0x07C00000 ..         (bytes 0x3E000000, SS3E000000:800000, 4 x 8 MiB)
// The track offsets come from the G64 header loaded by Main (an image of at
// most a few hundred KiB, so offsets stay far below the 0x0D600000-byte gap).
// A corrupt header could still point anywhere: drive writes that fall in
// 0x3D800000-0x3FFFFFFF are dropped here (accepted, not written) so the
// track cache can never overwrite the scratch slot or a slot.

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

	// savestate engine
	input             e_session,     // engine busy: keep the port
	input             e_req,
	input             e_we,
	input      [28:0] e_addr,
	input      [63:0] e_wdata,
	input       [7:0] e_be,
	output            e_ack,         // write accepted / read data valid (e_rdata)
	output     [63:0] e_rdata,

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

// the engine holds address, data and byte enables until e_ack: no copies here
reg        own = 0;
reg        e_rd_r = 0, e_we_r = 0, e_wait = 0, e_wack = 0;
reg  [8:0] d_out = 0;               // drive read beats outstanding

wire guard = d_we & (d_addr >= 29'h07B00000);   // drive write into the slot window 0x3D800000-0x3FFFFFFF

assign DDRAM_BURSTCNT = own ? 8'd1    : d_burstcnt;
assign DDRAM_ADDR     = own ? e_addr  : d_addr;
assign DDRAM_DIN      = own ? e_wdata : d_din;
assign DDRAM_BE       = own ? e_be    : d_be;
assign DDRAM_RD       = own ? e_rd_r   : d_rd;
assign DDRAM_WE       = own ? e_we_r   : (d_we & ~guard);

assign d_busy       = own | (DDRAM_BUSY & ~guard);
assign d_dout_ready = ~own & DDRAM_DOUT_READY;
assign d_idle       = ~d_rd & ~d_we & (d_out == 0);
assign e_rdata      = DDRAM_DOUT;
assign e_ack        = e_wack | (own & e_wait & DDRAM_DOUT_READY);

always @(posedge clk) begin
	e_wack <= 0;

	if (~own) begin
		if (d_rd & ~DDRAM_BUSY) d_out <= d_out + d_burstcnt - (DDRAM_DOUT_READY ? 1'd1 : 1'd0);
		else if (DDRAM_DOUT_READY && d_out) d_out <= d_out - 1'd1;
		if (e_session & d_idle) own <= 1;
	end
	else begin
		if ((e_rd_r | e_we_r) & ~DDRAM_BUSY) begin
			e_rd_r <= 0;
			e_we_r <= 0;
			if (e_we_r) e_wack <= 1;
			else e_wait <= 1;
		end
		if (e_wait & DDRAM_DOUT_READY) e_wait <= 0;
		if (e_req & ~e_rd_r & ~e_we_r & ~e_wait & ~e_ack) begin
			e_rd_r <= ~e_we;
			e_we_r <= e_we;
		end
		if (~e_session & ~e_req & ~e_rd_r & ~e_we_r & ~e_wait) own <= 0;
	end
end

endmodule
