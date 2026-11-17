// Savestate access to the SDRAM while the machine is frozen (WP A2).
//
// The C64 RAM, REU and GeoRAM live in the SDRAM behind the io_cycle /
// ext_cycle / cart mux of c64.sv. While the machine is paused none of them
// issues an access (sysCycle is held at CYCLE_EXT4: io_cycle, ext_cycle and
// ram_ce are low), but the refresh keeps running: fpga64 raises 'refresh'
// every 32 clk_sys (rfsh_cycle stays 0 while paused). This port takes the
// SDRAM mux (own) and places one byte access on each slot of the normal C64
// grid that is not the refresh slot: ce high in the C64 cycle phases of
// VIC0, CPU0/4/8/C, EXT0 or DMA0, with the same spacing (8 clk64 = one full
// sdram.v cycle) as a turbo CPU. With the request/ack handshake of the
// engine every second slot is used: 4 bytes per 32 clocks, 64 KiB in ~17 ms.
//
// Timing (clk64 = 2 x clk_sys, aligned): ce rises after edge T, sdram.v sees
// it at T+0.5 and latches read data at T+3 (STATE_READ); the data is taken at
// T+4, when the next access may start. Writes land at STATE_CMD_CONT.

module ss_sdram_port
(
	input             clk,
	input             refresh,     // fpga64 refresh pulse (clk_sys)
	input             enable,      // machine frozen for the savestate engine

	input             req,         // one access, held until ack
	input             we,
	input      [24:0] addr,
	input       [7:0] wdata,
	output reg        ack = 0,
	output reg  [7:0] rdata = 0,

	output reg        own = 0,     // take the SDRAM mux
	output reg        ce = 0,
	output reg        sd_we = 0,
	output reg [24:0] sd_addr = 0,
	output reg  [7:0] sd_din = 0,
	input       [7:0] sd_dout
);

reg [4:0] ph = 0;          // clk_sys since refresh: idx = 8 + ph of the C64 cycle
reg       ph_ok = 0;
reg       busy = 0;
reg [2:0] wait_n = 0;

always @(posedge clk) begin
	ph  <= refresh ? 5'd1 : ph + 1'd1;
	ack <= 0;
	ce  <= 0;

	if (~enable) ph_ok <= 0;
	else if (refresh) ph_ok <= 1;

	own <= enable & ph_ok;

	if (busy) begin
		wait_n <= wait_n - 1'd1;
		if (wait_n == 1) begin
			busy  <= 0;
			ack   <= 1;
			rdata <= sd_dout;
		end
	end
	// ph 3, 7, ..., 27: ce in idx 12, 16, 20, 24, 28, 0, 4 (never idx 8, refresh)
	else if (req & ~ack & own & (ph[1:0] == 2'd3) & (ph != 5'd31)) begin
		ce      <= 1;
		sd_we   <= we;
		sd_addr <= addr;
		sd_din  <= wdata;
		busy    <= 1;
		wait_n  <= 3'd4;
	end
end

endmodule
