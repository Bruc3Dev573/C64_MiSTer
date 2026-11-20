// tb_ss_transport: savestate SDRAM transport (D13) on the real controller.
//
// rtl/sdram.v (DQ register split for Verilator by scripts/sdram_dq.py) with
// the checked MT48LC16M16A2 model (sim_mt48lc16m16.sv), rtl/savestate/
// ss_sdram_port.sv on clk_sys = clk64 / 2 (aligned edges) and a model of the
// machine: a refresh pulse every 32 clk_sys (every 128 while it runs) and
// normal byte accesses on the C64 cycle grid, masked while the engine owns
// the SDRAM as c64.sv does.
//
// Checks: the power-on zero fill (clear) of a small lane window; normal
// accesses before, during (masked) and after engine ownership; engine read,
// write and zero transfers of 256 bytes in both lanes, all banks, random
// rows (data against a reference); normal reads of engine-written bytes and
// an engine read of machine-written bytes; zero violations of the chip
// checker in both ownership buckets (timing, bank state, back-to-back READs,
// tRAS max, refresh 64 ms window); no two READs on consecutive clocks (the
// board capture limit, sdram.v); the longest refresh gap and the clk_sys per
// read and per write transfer.

`timescale 1ns/1ps

module tb_ss_transport;

reg clk64 = 0, clk_sys = 0;
reg half = 0;
initial forever begin
	#7.9295 clk64 = 0;
	#7.9295 begin
		clk64   = 1;
		half    = ~half;
		clk_sys = half;
	end
end

integer errors = 0;
task check(input logic ok, input string what);
	if (ok !== 1'b1) begin
		errors = errors + 1;
		$display("FAIL: %s", what);
	end
endtask

// ------------------------------------------------------------ SDRAM controller + chip
wire [12:0] SDRAM_A;
wire [15:0] SDRAM_DQ;
wire  [1:0] SDRAM_BA;
wire        SDRAM_nCS, SDRAM_nWE, SDRAM_nRAS, SDRAM_nCAS, SDRAM_CLK, SDRAM_DQML, SDRAM_DQMH;
reg         init = 1;
reg         refresh = 0;
wire [24:0] m_addr;
wire  [7:0] m_din, sdram_data;
wire        m_ce, m_we;

wire        own, sd_req, sd_we, sd_wtgl, sd_rtgl, sd_dtgl;
wire [24:0] sd_addr;
wire [63:0] sd_din, sd_dout;

sdram sdram
(
	.sd_addr(SDRAM_A), .sd_data(SDRAM_DQ), .sd_ba(SDRAM_BA), .sd_cs(SDRAM_nCS), .sd_we(SDRAM_nWE),
	.sd_ras(SDRAM_nRAS), .sd_cas(SDRAM_nCAS), .sd_clk(SDRAM_CLK), .sd_dqm({SDRAM_DQMH, SDRAM_DQML}),
	.clk(clk64), .init(init), .refresh(refresh),
	.addr(m_addr), .ce(~own & m_ce), .we(m_we), .din(m_din), .dout(sdram_data),
	.ss_own(own), .ss_req(sd_req), .ss_we(sd_we), .ss_addr(sd_addr), .ss_din(sd_din),
	.ss_wtgl(sd_wtgl), .ss_dout(sd_dout), .ss_rtgl(sd_rtgl), .ss_dtgl(sd_dtgl)
);

sim_mt48lc16m16 chip
(
	.clk(SDRAM_CLK), .cke(1'b1), .cs_n(SDRAM_nCS), .ras_n(SDRAM_nRAS), .cas_n(SDRAM_nCAS), .we_n(SDRAM_nWE),
	.addr(SDRAM_A), .ba(SDRAM_BA), .dqm({SDRAM_DQMH, SDRAM_DQML}), .dq(SDRAM_DQ), .ss_own(own)
);

// READs one clk64 apart lose bits on the board (sdram.v): count them
integer rd_b2b = 0;
reg     rd_prev = 0;
wire    rd_now = !SDRAM_nCS && SDRAM_nRAS && !SDRAM_nCAS && SDRAM_nWE;
always @(posedge SDRAM_CLK) begin
	rd_prev <= rd_now;
	if (rd_prev && rd_now) rd_b2b <= rd_b2b + 1;
end

// ------------------------------------------------------------ port
reg         enable = 0, clear = 0;
wire        clear_done, ready, rvalid, wtake;
reg         req = 0, we = 0, zero = 0;
reg  [24:0] addr = 0;
wire [63:0] rdata;
reg  [63:0] wq [0:31];
reg   [4:0] wq_rd = 0;
wire [63:0] wdata = wq[wq_rd];

ss_sdram_port #(.CLR_BASE(25'h1000000), .CLR_XFERS(17'd64)) port
(
	.clk(clk_sys), .refresh(refresh), .enable(enable), .clear(clear), .clear_done(clear_done),
	.req(req), .we(we), .zero(zero), .addr(addr), .ready(ready), .rvalid(rvalid), .rdata(rdata),
	.wtake(wtake), .wdata(wdata),
	.own(own), .sd_req(sd_req), .sd_we(sd_we), .sd_addr(sd_addr), .sd_din(sd_din),
	.sd_wtgl(sd_wtgl), .sd_rtgl(sd_rtgl), .sd_dtgl(sd_dtgl), .sd_dout(sd_dout)
);

// every read transfer gives 32 words, every write transfer takes 32: the
// indexes are back at 0 between transfers
reg  [63:0] rbuf [0:31];
reg   [4:0] rb_wr = 0;
integer     rcnt = 0, takes = 0, cyc = 0;
always @(posedge clk_sys) begin
	cyc <= cyc + 1;
	if (rvalid) begin
		rbuf[rb_wr] <= rdata;
		rb_wr <= rb_wr + 1'd1;
		rcnt  <= rcnt + 1;
	end
	if (wtake) begin
		wq_rd <= wq_rd + 1'd1;
		takes <= takes + 1;
	end
end

// ------------------------------------------------------------ machine model
// refresh pulse at phase 8 of each 32 clk_sys (every fourth while running);
// one normal byte access at phase 12 or 20 when a test asks for one, or a
// read at phase 12 of every 32 while bg (the machine in reset during the
// power-on fill: its VIC reads go on, masked while the port owns the SDRAM)
reg  [4:0] ph = 0;
reg  [1:0] rf = 0;
reg        running = 1, bg = 0;
reg        m_go = 0, m_wr = 0, m_done = 0;
reg [24:0] m_a = 0;
reg  [7:0] m_d = 0, m_q = 0;
reg  [2:0] m_wait = 0;
reg        m_cep = 0, masked_ce = 0;
assign m_ce   = m_cep;
assign m_addr = m_a;
assign m_we   = m_wr;
assign m_din  = m_d;
always @(posedge clk_sys) begin
	ph      <= ph + 1'd1;
	refresh <= 0;
	m_cep   <= 0;
	m_done  <= 0;
	if (ph == 5'd7) begin
		rf <= rf + 1'd1;
		if (!running || rf == 0) refresh <= 1;
	end
	if (bg && ph == 5'd11) m_cep <= 1;
	if (m_go && (ph == 5'd11 || ph == 5'd19)) begin
		m_cep  <= 1;
		m_go   <= 0;
		m_wait <= 3'd5;
		if (own) masked_ce <= 1;
	end
	if (m_wait != 0) begin
		m_wait <= m_wait - 1'd1;
		if (m_wait == 3'd1) begin
			m_q    <= sdram_data;
			m_done <= 1;
		end
	end
end

task normal(input bit wr, input [24:0] a, input [7:0] d, output [7:0] q);
	begin
		@(posedge clk_sys);
		m_a  <= a;
		m_wr <= wr;
		m_d  <= d;
		m_go <= 1;
		@(posedge clk_sys);
		while (!m_done) @(posedge clk_sys);
		q = m_q;
	end
endtask

// ------------------------------------------------------------ engine driver
integer r_xfers = 0, r_clocks = 0, w_xfers = 0, w_clocks = 0, r0 = 0, t0 = 0;
task xfer(input bit w, input bit z, input [24:0] a);
	integer c0;
	begin
		@(posedge clk_sys);
		while (!ready) @(posedge clk_sys);
		c0 = cyc;
		r0 = rcnt;
		t0 = takes;
		req  <= 1;
		we   <= w;
		zero <= z;
		addr <= a;
		@(posedge clk_sys);
		req <= 0;
		@(posedge clk_sys);
		while (ready) @(posedge clk_sys);
		while (!ready) @(posedge clk_sys);
		@(posedge clk_sys);
		if (w) begin w_xfers = w_xfers + 1; w_clocks = w_clocks + (cyc - c0); end
		else   begin r_xfers = r_xfers + 1; r_clocks = r_clocks + (cyc - c0); end
	end
endtask

// reference: bytes the test wrote, by controller byte address
reg [7:0] ref_mem [int];
function [24:0] rnd_row(input integer s);   // a 256-byte row start in a random lane and bank
	rnd_row = {s[0], s[1], s[3:2], s[16:4], 8'd0};
endfunction

function automatic longint total(input integer owner);
	integer kk;
	begin
		total = 0;
		for (kk = 0; kk < 13; kk = kk + 1) total = total + chip.violations[owner][kk];   // sim_mt48lc16m16 NERR
	end
endfunction

integer i, n, seed;
reg [24:0] a, a_norm;
reg  [7:0] q, exp_b;
reg        ok;
reg [24:0] rows [0:63];

initial begin
	// power on as in c64.sv: the zero fill is requested from the start with the
	// machine running in reset (refresh every 128 clk_sys, its reads masked),
	// so the port owns the SDRAM while the controller still initializes: the
	// first transfer has to wait for the init and one normal AUTO REFRESH (chip
	// "initialization" check); after the last transfer the port lets go on a
	// refresh pulse, before the machine's next ce at phase 12
	for (i = 0; i < 65 * 256; i = i + 1) chip.mem[25'h1000000 + i] = 8'hA5;
	running = 1;
	bg      = 1;
	clear   = 1;
	repeat (40) @(posedge clk_sys);
	init = 0;
	while (!clear_done) @(posedge clk_sys);
	clear = 0;
	while (own) @(posedge clk_sys);
	check(ph >= 5'd10 && ph <= 5'd11, $sformatf("SDRAM released after a refresh pulse, before the machine's ce (phase %0d)", ph));
	repeat (200) @(posedge clk_sys);   // the machine's reads reach the controller again
	bg = 0;
	repeat (40) @(posedge clk_sys);
	ok = 1;
	for (i = 0; i < 64 * 256; i = i + 1) if (chip.mem[25'h1000000 + i] !== 8'h00) ok = 0;
	check(ok, "zero fill of the REU lane window (64 transfers)");
	check(chip.mem[25'h1004000] == 8'hA5 && !own, "zero fill stops at its end, SDRAM released");

	// normal accesses, machine running
	running = 1;
	seed = 7;
	for (i = 0; i < 40; i = i + 1) begin
		a = {$random(seed)} & 25'h1FFFFFF;
		if (i == 0) a_norm = a;
		exp_b = $random(seed);
		normal(1, a, exp_b, q);
		normal(0, a, 0, q);
		check(q === exp_b, $sformatf("normal write/read %h", a));
		ref_mem[a] = exp_b;
	end

	// the machine stops, the engine takes the SDRAM
	running = 0;
	enable  = 1;
	@(posedge clk_sys);
	while (!own) @(posedge clk_sys);

	// a machine access while owned is masked (never reaches the controller)
	normal(1, 25'h0000123, 8'h77, q);
	check(masked_ce && chip.mem[25'h0000123] !== 8'h77, "machine access masked while the engine owns the SDRAM");

	// write transfers: random rows, both lanes, all banks, random data
	for (n = 0; n < 48; n = n + 1) begin
		rows[n] = rnd_row($random(seed));
		for (i = 0; i < 32; i = i + 1) wq[i] = {$random(seed), $random(seed)};
		for (i = 0; i < 256; i = i + 1) ref_mem[rows[n] + i] = wq[i / 8][(i % 8) * 8 +: 8];
		xfer(1, 0, rows[n]);
		check(takes - t0 == 32, "write transfer takes 32 words");
	end
	// zero transfers over some of them
	for (n = 0; n < 8; n = n + 1) begin
		for (i = 0; i < 256; i = i + 1) ref_mem[rows[n * 5] + i] = 8'h00;
		xfer(1, 1, rows[n * 5]);
		check(takes == t0, "zero transfer takes no word");
	end
	// read them back
	for (n = 0; n < 48; n = n + 1) begin
		xfer(0, 0, rows[n]);
		check(rcnt - r0 == 32, "read transfer gives 32 words");
		ok = 1;
		for (i = 0; i < 256; i = i + 1) if (rbuf[i / 8][(i % 8) * 8 +: 8] !== ref_mem[rows[n] + i]) ok = 0;
		for (i = 0; i < 256; i = i + 1) if (chip.mem[rows[n] + i] !== ref_mem[rows[n] + i]) ok = 0;
		check(ok, $sformatf("engine data of row %h", rows[n]));
	end
	// the other lane of a written row is untouched (DQM)
	ok = 1;
	for (n = 0; n < 48; n = n + 1)
		for (i = 0; i < 256; i = i + 1) begin
			a = (rows[n] ^ 25'h1000000) + i;
			if (ref_mem.exists(a) && chip.mem[a] !== ref_mem[a]) ok = 0;
		end
	check(ok, "the other DQ lane is masked on engine writes");
	// an engine read of a row with a byte the machine wrote
	xfer(0, 0, {a_norm[24:8], 8'd0});
	check(rbuf[a_norm[7:3]][a_norm[2:0] * 8 +: 8] === ref_mem[a_norm], "engine read of a machine-written byte");
	repeat (2000) @(posedge clk_sys);   // owned and idle: the machine refresh keeps going

	// the engine releases, the machine runs again and reads engine data
	enable = 0;
	@(posedge clk_sys);
	while (own) @(posedge clk_sys);
	running = 1;
	for (n = 0; n < 16; n = n + 1) begin
		a = rows[n * 3] + ({$random(seed)} & 8'hFF);
		normal(0, a, 0, q);
		check(q === ref_mem[a], $sformatf("normal read of engine data %h", a));
	end
	repeat (200) @(posedge clk_sys);

	$display("tb_ss_transport: %0d read transfers, %0d clk_sys each; %0d write/zero transfers, %0d clk_sys each (256 bytes)",
		r_xfers, r_clocks / r_xfers, w_xfers, w_clocks / w_xfers);
	$display("tb_ss_transport: longest refresh gap normal %0d clk64, engine %0d clk64; violations normal %0d engine %0d",
		chip.max_gap[0], chip.max_gap[1], total(0), total(1));
	check(total(0) == 0 && total(1) == 0, "no SDRAM violation (strict checker, both owners)");
	check(rd_b2b == 0, "no READs on consecutive clocks");
	check(chip.max_gap[1] <= 600, "engine refresh gap below 600 clk64 (two refreshes per transfer)");
	if (errors == 0) $display("tb_ss_transport: PASS");
	else $display("tb_ss_transport: FAIL (%0d errors)", errors);
	$finish;
end

initial begin
	#100000000;
	$display("tb_ss_transport: FAIL (timeout)");
	$finish;
end

endmodule
