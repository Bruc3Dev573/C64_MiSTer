// Behavioral replacement of rtl/sdram.v (controller + MT48LC16M16 chip).
//
// Same interface and the same cycle timing as seen by the core: an access
// starts on the rising edge of ce, the write lands when the controller issues
// CMD_WRITE (q == STATE_CMD_CONT) and read data is captured in dout at
// q == STATE_READ, exactly where sdram.v latches sd_data. Refresh is ignored.
// The memory is a flat 32 MiB byte array (addr[24:0]).

module sdram (
	output     [12:0] sd_addr,
	inout      [15:0] sd_data,
	output     [ 1:0] sd_ba,
	output            sd_cs,
	output            sd_we,
	output            sd_ras,
	output            sd_cas,
	output            sd_clk,
	output     [ 1:0] sd_dqm,

	input             init,
	input             clk,

	input      [24:0] addr,
	input      [ 7:0] din,
	output     [ 7:0] dout,

	input             refresh,
	input             ce,
	input             we
);

localparam RASCAS_DELAY    = 3'd2;
localparam CAS_LATENCY     = 3'd2;
localparam STATE_CMD_CONT  = 3'd0 + RASCAS_DELAY;
localparam STATE_READ      = STATE_CMD_CONT + CAS_LATENCY + 1'd1;

assign sd_addr = 13'd0;
assign sd_data = 16'bZ;
assign sd_ba   = 2'd0;
assign sd_cs   = 1'b1;
assign sd_we   = 1'b1;
assign sd_ras  = 1'b1;
assign sd_cas  = 1'b1;
assign sd_clk  = 1'b0;
assign sd_dqm  = 2'b11;

reg [7:0] mem [1<<25] /*verilator public_flat_rw*/;

reg  [2:0] q = 0;
reg        last_ce = 0;
reg [24:0] a;
reg  [7:0] wrdata;
reg        wr;
reg  [7:0] dout_r = 0;

assign dout = dout_r;

always @(posedge clk) begin
	last_ce <= ce;

	if(q) q <= q + 3'd1;
	if(ce && !last_ce) begin
		q      <= 3'd1;
		a      <= addr;
		wr     <= we;
		wrdata <= din;
	end

	if(q == STATE_CMD_CONT && wr) mem[a] <= wrdata;
	if(q == STATE_READ) dout_r <= mem[a];
end

// The real controller (rtl/sdram.v) does not tolerate what this model does:
// a new ce edge while an access is in flight (q keeps counting, ACTIVE is
// sent mid-cycle), AUTO_REFRESH while an access is in flight, or ACTIVE
// within tRFC (~4 clk) of AUTO_REFRESH. Count and report them.
reg        last_ref = 0;
reg  [3:0] since_ref = 4'hF;
integer    ss_conflicts /*verilator public_flat_rd*/ = 0;
always @(posedge clk) begin
	last_ref <= refresh;
	if(since_ref != 4'hF) since_ref <= since_ref + 1'd1;
	if(refresh && !last_ref) since_ref <= 0;
	if((ce && !last_ce && (q != 0 || since_ref < 4'd4)) || (refresh && !last_ref && q != 0)) begin
		ss_conflicts <= ss_conflicts + 1;
		if(ss_conflicts < 8) $display("sdram conflict: %s (q=%0d, since_ref=%0d, addr=%h)",
			(refresh && !last_ref && q != 0) ? "refresh during access" : (q != 0) ? "ce during access" : "ce after refresh",
			q, since_ref, addr);
	end
end

endmodule
