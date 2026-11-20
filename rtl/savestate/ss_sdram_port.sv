// Savestate access to the SDRAM while the machine is frozen (WP A2, D13).
//
// The engine moves the SDRAM regions (RAM, REU, GeoRAM, cartridge RAM and
// EasyFlash flash) in transfers of 256 bytes of one DQ lane and one row,
// run by the engine sequencer of rtl/sdram.v (two AUTO REFRESH, one ACTIVE,
// 256 columns: ~273 clk64 per write transfer, ~528 per read transfer, READs
// every other clk64). This port takes the
// SDRAM once the machine is frozen for the engine and a refresh pulse has
// passed, so no access of the machine is in flight (own: c64.sv masks the
// machine's ce, sdram.v starts transfers only while own), starts the
// transfers and moves their words: 32 read words (rvalid), 32 write words
// taken from wdata (wtake pops the engine FIFO, the next word must be on
// wdata the clock after), or zeros. It keeps the SDRAM until the transfer in
// flight is done.
//
// clear: once after FPGA configuration c64.sv zero-fills the REU lane
// (CLR_BASE, CLR_XFERS transfers) with the machine held in reset (its cycle
// grid runs, its ce masked): the defined power-on content of the REU, which
// a load restores to the pages a slot does not hold
// (docs/SAVESTATE_DECISIONS.md D13). After the last transfer the port keeps
// the SDRAM until the next refresh pulse, so the machine gets it back where
// its ce is low (the refresh slot) and no access starts mid-cycle. sdram.v
// starts the first transfer only after a normal AUTO REFRESH following its
// init.
//
// The toggles of sdram.v (clk64) are sampled on clk_sys: both clocks come
// from the same PLL with aligned edges, a toggle changes at most every 8
// clk64.

module ss_sdram_port #(
	parameter [24:0] CLR_BASE  = 25'h1000000,  // REU lane (c64.sv REU_ADDR)
	parameter [16:0] CLR_XFERS = 17'd65536     // 16 MiB
)
(
	input             clk,          // clk_sys
	input             refresh,      // fpga64 refresh pulse
	input             enable,       // machine frozen for the savestate engine
	input             clear,        // power-on zero fill, held until clear_done
	output reg        clear_done = 0,

	input             req,          // start a transfer (only while ready)
	input             we,
	input             zero,         // write zeros, no word taken
	input      [24:0] addr,         // 256-byte aligned
	output            ready,        // owned, no transfer in flight
	output reg        rvalid = 0,   // a read word
	output reg [63:0] rdata = 0,
	output reg        wtake = 0,    // the word on wdata was taken: the next one from the next clock
	input      [63:0] wdata,

	output reg        own = 0,      // the engine owns the SDRAM
	output reg        sd_req = 0,   // toggle
	output reg        sd_we = 0,
	output reg [24:0] sd_addr = 0,
	output reg [63:0] sd_din = 0,
	input             sd_wtgl,
	input             sd_rtgl,
	input             sd_dtgl,
	input      [63:0] sd_dout
);

reg        ph_ok = 0, busy = 0, zfill = 0, clr_hold = 0;
reg        wseen = 0, rseen = 0, dseen = 0;
reg  [5:0] taken = 0;               // write words put on sd_din in this transfer
reg [16:0] clr_n = 0;               // clear transfers started
wire       clr_run = clear & ~clear_done;
wire       hold    = enable | clr_run | clr_hold;
wire       clr_go  = clr_run & own & ~busy & (clr_n != CLR_XFERS);
wire       eng_go  = req & ready;

assign ready = own & ~busy & ~clr_run;

always @(posedge clk) begin
	rvalid <= 0;
	wtake  <= 0;

	if (~hold) ph_ok <= 0;
	else if (refresh) ph_ok <= 1;
	own <= (hold & ph_ok) | busy;
	if (refresh) clr_hold <= 0;

	if (sd_rtgl != rseen) begin
		rseen  <= sd_rtgl;
		rvalid <= 1;
		rdata  <= sd_dout;
	end

	// sdram.v took sd_din: the next word (32 per transfer)
	if (sd_wtgl != wseen) begin
		wseen <= sd_wtgl;
		if (~zfill && taken != 6'd32) begin
			sd_din <= wdata;
			wtake  <= 1;
			taken  <= taken + 1'd1;
		end
	end

	if (sd_dtgl != dseen) begin
		dseen <= sd_dtgl;
		busy  <= 0;
		if (clr_run && clr_n == CLR_XFERS) begin
			clear_done <= 1;
			clr_hold   <= 1;   // released on the next refresh pulse
		end
	end

	if (eng_go | clr_go) begin
		busy    <= 1;
		sd_req  <= ~sd_req;
		sd_we   <= clr_go | we;
		sd_addr <= clr_go ? CLR_BASE + {clr_n[16:0], 8'd0} : addr;
		zfill   <= clr_go | zero;
		taken   <= 6'd1;
		if (clr_go | zero | ~we) sd_din <= 64'd0;
		else begin
			sd_din <= wdata;
			wtake  <= 1;
		end
		if (clr_go) clr_n <= clr_n + 1'd1;
	end
end

endmodule
