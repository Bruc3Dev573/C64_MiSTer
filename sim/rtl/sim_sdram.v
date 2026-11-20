// Behavioral replacement of rtl/sdram.v (controller + MT48LC16M16 chip).
//
// Same interface and the same cycle timing as seen by the core: an access
// starts on the rising edge of ce, the write lands when the controller issues
// CMD_WRITE (q == STATE_CMD_CONT) and read data is captured in dout at
// q == STATE_READ, exactly where sdram.v latches sd_data. Refresh is ignored.
// The memory is a flat 32 MiB byte array (addr[24:0]). The savestate engine
// transfers (ss_*) follow the sequencer of sdram.v clock for clock: the same
// start condition, written words taken every eight columns from ss_q 13
// (one column per clock), read words complete at ss_q 31 + 16k (one column
// every other clock), done at 273 (write) or 528 (read).

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
	input             we,

	input             ss_own,
	input             ss_req,
	input             ss_we,
	input      [24:0] ss_addr,
	input      [63:0] ss_din,
	output reg        ss_wtgl = 0,
	output reg [63:0] ss_dout = 0,
	output reg        ss_rtgl = 0,
	output reg        ss_dtgl = 0
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
reg        last_ref = 0;

assign dout = dout_r;

reg  [9:0] ss_q = 0;
reg        ss_seen = 0, ss_wr = 0, ss_init = 0;
reg [24:0] ss_a = 0;
reg  [3:0] ss_rfc = 0;
reg [55:0] ss_acc = 0, ss_wsh = 0;
wire       ss_go   = ss_own && (ss_req != ss_seen) && !q && !ss_q && !init && ss_init &&
                     ss_rfc >= 4'd5 && !(refresh && !last_ref);
wire [9:0] ss_off  = ss_q - 10'd13;
wire [7:0] ss_col  = ss_wr ? ss_off[7:0] : ss_off[8:1];
wire [9:0] ss_roff = ss_q - 10'd17;
wire [7:0] ss_rcol = ss_roff[8:1];
wire [7:0] ss_rb   = mem[{ss_a[24:8], ss_rcol}];

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

	if(ss_go) begin
		ss_q    <= 10'd1;
		ss_seen <= ss_req;
		ss_wr   <= ss_we;
		ss_a    <= ss_addr;
	end
	else if(ss_q) begin
		if(ss_q == (ss_wr ? 10'd273 : 10'd528)) begin
			ss_q    <= 0;
			ss_dtgl <= ~ss_dtgl;
		end
		else ss_q <= ss_q + 1'd1;
	end
	if((ss_q == 10'd1) || (ss_q == 10'd6) || (!init && !ss_q && refresh && !last_ref)) ss_rfc <= 0;
	else if(ss_rfc != 4'd15) ss_rfc <= ss_rfc + 1'd1;
	if(init) ss_init <= 0;
	else if(!ss_q && refresh && !last_ref) ss_init <= 1;

	if(ss_wr && ss_q >= 10'd13 && ss_q <= 10'd268) begin
		mem[{ss_a[24:8], ss_col}] <= ss_col[2:0] ? ss_wsh[7:0] : ss_din[7:0];
		if(!ss_col[2:0]) begin
			ss_wsh  <= ss_din[63:8];
			ss_wtgl <= ~ss_wtgl;
		end
		else ss_wsh <= ss_wsh >> 8;
	end
	if(!ss_wr && ss_q >= 10'd17 && ss_q <= 10'd527 && ss_q[0]) begin
		if(&ss_rcol[2:0]) begin
			ss_dout <= {ss_rb, ss_acc};
			ss_rtgl <= ~ss_rtgl;
		end
		else ss_acc <= {ss_rb, ss_acc[55:8]};
	end
end

// The real controller (rtl/sdram.v) does not tolerate what this model does:
// a new ce edge while an access or an engine transfer is in flight (q keeps
// counting, ACTIVE is sent mid-cycle), AUTO_REFRESH while an access is in
// flight, or ACTIVE within tRFC (~4 clk) of AUTO_REFRESH. Count and report
// them.
reg  [3:0] since_ref = 4'hF;
integer    ss_conflicts /*verilator public_flat_rd*/ = 0;
always @(posedge clk) begin
	last_ref <= refresh;
	if(since_ref != 4'hF) since_ref <= since_ref + 1'd1;
	if(refresh && !last_ref) since_ref <= 0;
	if((ce && !last_ce && (q != 0 || ss_q != 0 || since_ref < 4'd4)) || (refresh && !last_ref && q != 0)) begin
		ss_conflicts <= ss_conflicts + 1;
		if(ss_conflicts < 8) $display("sdram conflict: %s (q=%0d, ss_q=%0d, since_ref=%0d, addr=%h)",
			(refresh && !last_ref && q != 0) ? "refresh during access" : (ss_q != 0) ? "ce during engine transfer" :
			(q != 0) ? "ce during access" : "ce after refresh",
			q, ss_q, since_ref, addr);
	end
end

endmodule
