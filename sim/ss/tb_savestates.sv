// tb_savestates: savestate engine (rtl/savestate/savestates.sv) with the DDR3
// arbiter (ss_ddram_arb), a DDR3 model with random waitrequest, latency and
// readdatavalid gaps (write bursts beat by beat, read bursts queued) and a
// drive master hammering the port, the freeze controller (ss_freeze) in front
// of a model of the fpga64 pause sampling, a 75-bit test chain (three
// segments, one empty), a block RAM region with random latency (Color RAM),
// SDRAM regions (RAM, REU) behind a model of ss_sdram_port with random gaps
// and the REU page map.
//
//   iverilog -g2012 -I rtl/savestate -o tb sim/ss/tb_chain_defs.vh \
//       sim/ss/tb_savestates.sv rtl/savestate/*.sv && vvp tb
//
// Checks: save/load round trip (chain, RAM, Color RAM, REU pages), chain
// unchanged by a save, save/save CRC, CRC against a byte-wise reference
// (the engine does 8 bytes per clock), slot header protocol (cleared first,
// counter byte enables, STATESIZE of the words used), refusals that leave the
// machine untouched (CRC, config, version, empty slot, inhibit, REU record
// structure with a valid CRC), unknown TLV skipped, forced boundary (save
// abandoned, load proceeds), too big, REU pages: only written pages saved,
// a load zeroes the written pages the slot does not hold and leaves the
// others, the map follows; a format 1 slot (whole REU) loads and marks every
// page; DDR3 bursts: the drive master is served during engine sessions, every
// drive beat arrives, drive writes outside the drive window never land. The
// first slot is dumped to tb_slot.bin for sim/scripts/ss_slot.py (zlib CRC).

`timescale 1ns/1ps

module tb_savestates #(parameter [2:0] LIVE_T = 3'b111);   // 3'b001: segment C not instrumented

reg clk = 0;
always #5 clk = ~clk;

integer errors = 0;
task check(input cond, input [8*72-1:0] what);
	if (cond !== 1'b1) begin
		errors = errors + 1;
		$display("FAIL: %0s", what);
	end
endtask

// ------------------------------------------------------------ engine
reg         save = 0, load = 0, hold = 0, sd_count = 1, inhibit = 0;
reg  [28:0] slot_addr = 29'h07C00000;
reg  [31:0] config_mask = 32'h00000123;
localparam [`SS_REGION_COUNT:0] P_BASE = 1 | (1 << (`SS_RGN_RAM + 1)) | (1 << (`SS_RGN_COLORRAM + 1));
localparam [`SS_REGION_COUNT:0] P_REU  = P_BASE | (1 << (`SS_RGN_REU_RAM + 1));
reg [`SS_REGION_COUNT:0] rgn_present = P_BASE;
reg  [24:0] reu_bytes = 0;
wire        busy, done, result_load, freeze_req, freeze_ack, freeze_forced;
wire  [3:0] result;
wire [31:0] last_crc;
wire        chain_en, chain_so, chain_si, loading, load_done;
wire  [7:0] rgn_tag, rgn_wdata;
wire [23:0] rgn_addr;
wire        rgn_req, rgn_we;
reg   [7:0] rgn_rdata = 0;
reg         rgn_ack = 0;
wire        sd_req, sd_we, sd_zero;
reg         sd_rvalid = 0, sd_wtake = 0;
reg  [63:0] sd_rdata = 0;
wire [63:0] sd_wdata;
wire        sd_ready;
wire [11:0] map_addr;
wire        map_we, map_wdata;
reg         map_q = 0;
wire [28:0] e_addr;
wire  [7:0] e_burstcnt, e_be;
wire        e_rd, e_we, e_busy, e_dout_ready;
wire [63:0] e_din;

// slots of 2 MiB (the DDR3 model windows)
savestates #(.BUILD_HASH(32'hCAFE0001), .SLOT_BYTES(32'h200000), .SETTLE(20), .WDOG_BITS(16),
             .LIVE({29'd0, LIVE_T})) eng
(
	.clk(clk), .reset(1'b0),
	.save(save), .load(load), .slot_addr(slot_addr), .hold(hold), .sd_count(sd_count), .inhibit(inhibit),
	.busy(busy), .done(done), .result(result), .result_load(result_load), .last_crc(last_crc),
	.freeze_req(freeze_req), .freeze_ack(freeze_ack), .freeze_forced(freeze_forced),
	.config_mask(config_mask), .rgn_present(rgn_present), .reu_bytes(reu_bytes),
	.chain_en(chain_en), .chain_so(chain_so), .chain_si(chain_si), .loading(loading), .load_done(load_done),
	.rgn_tag(rgn_tag), .rgn_addr(rgn_addr), .rgn_req(rgn_req), .rgn_we(rgn_we), .rgn_wdata(rgn_wdata),
	.rgn_rdata(rgn_rdata), .rgn_ack(rgn_ack),
	.sd_req(sd_req), .sd_we(sd_we), .sd_zero(sd_zero), .sd_ready(sd_ready), .sd_rvalid(sd_rvalid),
	.sd_rdata(sd_rdata), .sd_wtake(sd_wtake), .sd_wdata(sd_wdata),
	.map_addr(map_addr), .map_q(map_q), .map_we(map_we), .map_wdata(map_wdata),
	.ddr_addr(e_addr), .ddr_burstcnt(e_burstcnt), .ddr_rd(e_rd), .ddr_we(e_we), .ddr_wdata(e_din), .ddr_be(e_be),
	.ddr_busy(e_busy), .ddr_rdata(DDRAM_DOUT), .ddr_rvalid(e_dout_ready)
);

// ------------------------------------------------------------ chain (75 bits)
reg  [69:0] segA = 0;
reg   [4:0] segC = 0;
wire [69:0] dA;
wire  [4:0] dC;
wire        soA, soB, soC;
wire  [0:0] dB;
// a segment that is not live is not on the chain: A takes the engine output directly
ss_chain_seg #(.W(70)) sA(.q(segA), .scan_in(LIVE_T[2] ? soB : chain_so), .d(dA), .scan_out(soA));
ss_chain_seg #(.W(0))  sB(.q(1'b0), .scan_in(soC), .d(dB), .scan_out(soB));
ss_chain_seg #(.W(5))  sC(.q(segC), .scan_in(chain_so), .d(dC), .scan_out(soC));
assign chain_si = soA;
always @(posedge clk) if (chain_en) begin segA <= dA; if (LIVE_T[2]) segC <= dC; end

// ------------------------------------------------------------ freeze: fpga64 model
// pause sampled every 32 clocks (sample = 'refresh'), machine idle at random
reg  [4:0] phase = 0;
reg        sample = 0, c64_pause = 0;
reg  [2:0] idle = 3'b111;
reg        idle_rand = 1;      // idle bits toggle randomly
wire       pause_in;
wire [2:0] block;
always @(posedge clk) begin
	phase  <= phase + 1'd1;
	sample <= (phase == 5'd7);
	if (phase == 5'd7) c64_pause <= pause_in;
	if (idle_rand) idle <= {$random} % 8 == 0 ? 3'b111 : $random;
end
ss_freeze #(.N(3), .WDOG_BITS(12)) frz
(
	.clk(clk), .req(freeze_req), .user_pause(1'b0), .run_ok(1'b1), .sample(sample), .c64_pause(c64_pause),
	.idle(idle), .pause(pause_in), .ack(freeze_ack), .forced(freeze_forced), .block(block)
);
// the machine must never run while the engine works on it
always @(posedge clk) if ((chain_en || rgn_req || sd_req || map_we) && !c64_pause) check(0, "state access while the machine runs");
// a non-forced ack must come from a sample with all blocks idle
reg idle_at_sample = 0;
always @(posedge clk) if (phase == 5'd7) idle_at_sample <= &idle;

// ------------------------------------------------------------ memories
localparam REU_MAX = 32768;          // 8 pages of 4 KiB
reg [7:0] ram  [0:65535];
reg [7:0] cram [0:1023];
reg [7:0] reu  [0:REU_MAX-1];
reg       map  [0:4095];

// Color RAM: byte region, random latency
reg [3:0] rlat = 0;
reg       rpend = 0;
always @(posedge clk) begin
	rgn_ack <= 0;
	if (rgn_req) begin
		rpend <= 1;
		rlat  <= $random;
		if (rgn_tag != 8'h02) check(0, "byte access to a region that is not a block RAM");
	end
	else if (rpend) begin
		if (rlat == 0) begin
			rpend   <= 0;
			rgn_ack <= 1;
			if (rgn_we) cram[rgn_addr[9:0]] <= rgn_wdata & 8'h0F;
			rgn_rdata <= cram[rgn_addr[9:0]];
		end
		else rlat <= rlat - 1'd1;
	end
end

// SDRAM regions: model of ss_sdram_port (ready, 32 words per transfer with
// random gaps, a write word taken from sd_wdata at most every other clock,
// the last read word and ready may come on the same clock)
reg        p_busy = 0, p_we = 0, p_zero = 0, p_hold = 0;
reg  [7:0] p_tag = 0;
reg [23:0] p_off = 0;
reg  [5:0] p_n = 0;
reg  [2:0] p_gap = 0;
integer    sd_xfers = 0, sd_bad = 0;
assign sd_ready = ~p_busy & ~p_hold;

function [7:0] sd_rd(input [7:0] t, input [23:0] a);
	sd_rd = (t == 8'h01) ? ram[a[15:0]] : (t == 8'h09 && a < REU_MAX) ? reu[a[14:0]] : 8'hXX;
endfunction
task sd_wr(input [7:0] t, input [23:0] a, input [7:0] d);
	begin
		if (t == 8'h01) ram[a[15:0]] = d;
		else if (t == 8'h09 && a < REU_MAX) reu[a[14:0]] = d;
		else sd_bad = sd_bad + 1;
	end
endtask

reg rdy_d = 0;   // ready on the clock the engine decided (sd_req is registered)
always @(posedge clk) begin : port_model
	integer b;
	reg [63:0] w;
	sd_rvalid <= 0;
	sd_wtake  <= 0;
	rdy_d     <= sd_ready;
	p_hold    <= ({$random} % 6 == 0);
	if (sd_req) begin
		if (!rdy_d) check(0, "SDRAM transfer requested while the port is busy");
		if (rgn_tag != 8'h01 && rgn_tag != 8'h09) check(0, "SDRAM transfer of a region not in SDRAM");
		if (rgn_addr[7:0] != 0) check(0, "SDRAM transfer not 256-byte aligned");
		p_busy <= 1;
		p_we   <= sd_we;
		p_zero <= sd_zero;
		p_tag  <= rgn_tag;
		p_off  <= rgn_addr;
		p_n    <= 0;
		p_gap  <= 3'd2;
		sd_xfers = sd_xfers + 1;
		if (sd_we & ~sd_zero) begin
			// as ss_sdram_port: the first word is taken with the request
			for (b = 0; b < 8; b = b + 1) sd_wr(rgn_tag, rgn_addr + b, sd_wdata[b*8 +: 8]);
			sd_wtake <= 1;
			p_n      <= 1;
		end
	end
	else if (p_busy) begin
		if (p_gap) p_gap <= p_gap - 1'd1;
		else if (p_n == 6'd32) p_busy <= 0;
		else begin
			if (!p_we) begin
				for (b = 0; b < 8; b = b + 1) w[b*8 +: 8] = sd_rd(p_tag, p_off + {p_n[4:0], 3'd0} + b);
				sd_rvalid <= 1;
				sd_rdata  <= w;
				// the last word may come with ready (the done toggle one clk64 after it)
				if (p_n == 6'd31 && ({$random} % 2)) p_busy <= 0;
			end
			else begin
				w = p_zero ? 64'd0 : sd_wdata;
				for (b = 0; b < 8; b = b + 1) sd_wr(p_tag, p_off + {p_n[4:0], 3'd0} + b, w[b*8 +: 8]);
				if (!p_zero) sd_wtake <= 1;
			end
			p_n   <= p_n + 1'd1;
			p_gap <= 3'd1 + {$random} % 3;   // a word taken at most every other clock
		end
	end
end

// REU page map: q of map_addr one clock later (the engine registers map_addr)
always @(posedge clk) begin
	if (map_we) map[map_addr] <= map_wdata;
	map_q <= map[map_addr];
end

// ------------------------------------------------------------ DDR3 + arbiter + drive master
wire  [7:0] DDRAM_BURSTCNT, DDRAM_BE;
wire [28:0] DDRAM_ADDR;
wire        DDRAM_RD, DDRAM_WE;
wire [63:0] DDRAM_DIN;
reg         DDRAM_BUSY = 0, DDRAM_DOUT_READY = 0;
reg  [63:0] DDRAM_DOUT = 0;

reg   [7:0] d_burstcnt = 1;
reg  [28:0] d_addr = 29'h06000000;
reg         d_rd = 0, d_we = 0;
reg  [63:0] d_din = 0;
wire        d_busy, d_dout_ready, d_idle;

ss_ddram_arb arb
(
	.clk(clk),
	.d_burstcnt(d_burstcnt), .d_addr(d_addr), .d_rd(d_rd), .d_we(d_we), .d_din(d_din), .d_be(8'hFF),
	.d_busy(d_busy), .d_dout_ready(d_dout_ready), .d_idle(d_idle),
	.e_burstcnt(e_burstcnt), .e_addr(e_addr), .e_rd(e_rd), .e_we(e_we), .e_din(e_din), .e_be(e_be),
	.e_busy(e_busy), .e_dout_ready(e_dout_ready),
	.DDRAM_BUSY(DDRAM_BUSY), .DDRAM_BURSTCNT(DDRAM_BURSTCNT), .DDRAM_ADDR(DDRAM_ADDR),
	.DDRAM_DOUT(DDRAM_DOUT), .DDRAM_DOUT_READY(DDRAM_DOUT_READY),
	.DDRAM_RD(DDRAM_RD), .DDRAM_WE(DDRAM_WE), .DDRAM_DIN(DDRAM_DIN), .DDRAM_BE(DDRAM_BE)
);

// DDR model: slot window 0x07C00000 + 5 x 2 MiB (words), drive window small
localparam [28:0] SW = 29'h07C00000;
localparam        SWN = 5 * 32'h40000;
reg [63:0] slotmem [0:SWN-1];
reg [63:0] drvmem  [0:4095];
integer    drive_slot_writes = 0;
reg        hdr_cleared_first = 1;
reg        first_write_seen = 0;
reg [28:0] wb_addr = 0;
integer    wb_left = 0;
reg [28:0] rq_addr [0:15];
integer    rq_n [0:15];
integer    rq_wr = 0, rq_rd = 0, rq_lat = 0;
integer    max_burst = 0;

function [63:0] be_merge(input [63:0] old, input [63:0] d, input [7:0] be);
	integer i;
	begin
		be_merge = old;
		for (i = 0; i < 8; i = i + 1) if (be[i]) be_merge[i*8 +: 8] = d[i*8 +: 8];
	end
endfunction
function in_slot(input [28:0] a);
	in_slot = (a >= SW) && (a < SW + SWN);
endfunction

always @(posedge clk) begin : ddr_model
	reg [28:0] a;
	DDRAM_DOUT_READY <= 0;
	DDRAM_DOUT <= {$random, $random};   // readdata is valid only with readdatavalid
	if (!DDRAM_BUSY && DDRAM_WE) begin
		if (wb_left == 0) begin
			wb_addr = DDRAM_ADDR;
			wb_left = DDRAM_BURSTCNT;
			if (DDRAM_BURSTCNT > max_burst) max_burst = DDRAM_BURSTCNT;
		end
		a = wb_addr;
		if (in_slot(a)) begin
			slotmem[a - SW] <= be_merge(slotmem[a - SW], DDRAM_DIN, DDRAM_BE);
			if (!arb.own) drive_slot_writes = drive_slot_writes + 1;
			if (busy && !first_write_seen) begin
				first_write_seen = 1;
				if (a != slot_addr || DDRAM_DIN != 0) hdr_cleared_first = 0;
			end
		end
		else drvmem[a[11:0]] <= DDRAM_DIN;
		wb_addr = wb_addr + 1;
		wb_left = wb_left - 1;
	end
	if (!DDRAM_BUSY && DDRAM_RD) begin
		rq_addr[rq_wr % 16] = DDRAM_ADDR;
		rq_n[rq_wr % 16]    = DDRAM_BURSTCNT;
		rq_wr = rq_wr + 1;
	end
	if (rq_rd != rq_wr) begin
		if (rq_lat) rq_lat = rq_lat - 1;
		else if ({$random} % 4 != 0) begin
			a = rq_addr[rq_rd % 16];
			DDRAM_DOUT_READY <= 1;
			DDRAM_DOUT <= in_slot(a) ? slotmem[a - SW] : drvmem[a[11:0]];
			rq_addr[rq_rd % 16] = a + 1;
			rq_n[rq_rd % 16] = rq_n[rq_rd % 16] - 1;
			if (rq_n[rq_rd % 16] == 0) begin
				rq_rd  = rq_rd + 1;
				rq_lat = 2 + {$random} % 6;
			end
		end
	end
	DDRAM_BUSY <= ({$random} % 5 == 0);
end

// drive master: random bursts and writes, some outside the drive window (dropped)
reg     drv_on = 1;
integer dr_left = 0, drv_req_beats = 0, drv_got_beats = 0, drv_served_in_session = 0;
always @(posedge clk) begin
	if (d_rd & ~d_busy) begin
		d_rd <= 0;
		dr_left <= d_burstcnt;
		drv_req_beats = drv_req_beats + d_burstcnt;
		if (busy) drv_served_in_session = drv_served_in_session + 1;
	end
	if (d_we & ~d_busy) d_we <= 0;
	if (d_dout_ready) drv_got_beats = drv_got_beats + 1;
	if (d_dout_ready && dr_left) dr_left <= dr_left - 1;
	if (drv_on && !d_rd && !d_we && dr_left == 0 && ({$random} % 40 == 0)) begin
		if ($random % 2) begin
			d_rd <= 1; d_burstcnt <= 1 + {$random} % 8; d_addr <= 29'h06000000 + ({$random} % 256);
		end
		else begin
			d_we <= 1; d_din <= {$random, $random};
			d_addr <= ({$random} % 3 == 0) ? SW + ({$random} % 16) : 29'h06000000 + ({$random} % 256);
		end
	end
end

// ------------------------------------------------------------ helpers
reg [69:0] refA;
reg  [4:0] refC;
reg  [7:0] ref_ram  [0:65535];
reg  [7:0] ref_cram [0:1023];
reg  [7:0] ref_reu  [0:REU_MAX-1];
reg        ref_map  [0:4095];
integer i;
reg  [3:0] last_result;
reg        saw_load_done;
always @(posedge clk) if (load_done) saw_load_done = 1;

task fill(input integer seed);
	integer s;
	begin
		s = seed;
		segA = {$random(s), $random(s), $random(s)};
		segC = $random(s);
		for (i = 0; i < 65536; i = i + 1) ram[i] = $random(s);
		for (i = 0; i < 1024; i = i + 1) cram[i] = $random(s) & 8'h0F;
		// an absent REU is outside the state: a load cannot bring it back
		if (rgn_present[`SS_RGN_REU_RAM + 1]) for (i = 0; i < REU_MAX; i = i + 1) reu[i] = $random(s);
	end
endtask

task snap;
	begin
		refA = segA; refC = segC;
		for (i = 0; i < 65536; i = i + 1) ref_ram[i] = ram[i];
		for (i = 0; i < 1024; i = i + 1) ref_cram[i] = cram[i];
		for (i = 0; i < REU_MAX; i = i + 1) ref_reu[i] = reu[i];
		for (i = 0; i < 4096; i = i + 1) ref_map[i] = map[i];
	end
endtask

function same_as_snap(input dummy);
	integer k;
	begin
		same_as_snap = (segA === refA) && (segC === refC || !LIVE_T[2]);
		for (k = 0; k < 65536; k = k + 1) if (ram[k] !== ref_ram[k]) same_as_snap = 0;
		for (k = 0; k < 1024; k = k + 1) if (cram[k] !== ref_cram[k]) same_as_snap = 0;
		for (k = 0; k < REU_MAX; k = k + 1) if (reu[k] !== ref_reu[k]) same_as_snap = 0;
		for (k = 0; k < 4096; k = k + 1) if (map[k] !== ref_map[k]) same_as_snap = 0;
	end
endfunction

task op(input is_load, input [28:0] addr);
	begin
		@(posedge clk);
		slot_addr <= addr;
		save <= ~is_load;
		load <= is_load;
		saw_load_done = 0;
		first_write_seen = 0;
		@(posedge clk);
		save <= 0;
		load <= 0;
		@(posedge clk);
		while (!done) @(posedge clk);
		last_result = result;
		@(posedge clk);
		while (freeze_req) @(posedge clk);   // engine released the machine
		repeat (40) @(posedge clk);
	end
endtask

// byte-wise CRC-32 of words 3 .. STATESIZE/2-1 (the engine does 8 bytes per clock)
function [31:0] crc_ref(input [28:0] base);
	reg [31:0] c;
	reg [63:0] w;
	integer n, b, k, words;
	begin
		c = 32'hFFFFFFFF;
		words = slotmem[base][63:33];
		for (n = 3; n < words; n = n + 1) begin
			w = slotmem[base + n];
			for (b = 0; b < 8; b = b + 1) begin
				c = c ^ w[b*8 +: 8];
				for (k = 0; k < 8; k = k + 1) c = c[0] ? ((c >> 1) ^ 32'hEDB88320) : (c >> 1);
			end
		end
		crc_ref = ~c;
	end
endfunction

localparam [28:0] S0 = 29'h07C00000, S1 = 29'h07C40000, S2 = 29'h07C80000, S3 = 29'h07CC0000, S4 = 29'h07D00000;
reg [31:0] crc_a, cnt0;
reg [63:0] w0, w2;
integer f, nwords, p, k, kr, rec, n1;
reg ok;

initial begin
	for (i = 0; i < SWN; i = i + 1) slotmem[i] = 0;
	for (i = 0; i < 4096; i = i + 1) begin drvmem[i] = 0; map[i] = 0; end
	repeat (10) @(posedge clk);

	// 1. save, machine unchanged, header and CRC
	fill(1);
	snap;
	op(0, S0);
	check(last_result == 0, "1 save ok");
	check(same_as_snap(0), "1 save leaves chain and memories unchanged");
	check(hdr_cleared_first, "1 header cleared by the first slot write");
	w0 = slotmem[0];
	check(w0[31:0] == 1, "1 change counter = 1");
	check(slotmem[1] == {32'hCAFE0001, LIVE_T[2] ? 16'd75 : 16'd70, 16'd2}, "1 payload header w1 (format 2, live chain bits)");
	check(slotmem[2][63:32] == config_mask, "1 config mask");
	check(slotmem[2][31:0] == crc_ref(0), "1 CRC (8 bytes per clock) matches the byte-wise reference");
	check(last_crc == slotmem[2][31:0], "1 last_crc");
	check(slotmem[3] == {32'd1024, 24'd0, 8'h40}, "1 first TLV is CHAIN, 1024 bytes");
	check(slotmem[3 + 1] == refA[63:0], "1 chain word 0 = segment A bits 63:0");
	check(slotmem[3 + 2] == {58'd0, refA[69:64]}, "1 chain word 1 = segment A bits 69:64");
	check(slotmem[3 + 11] == (LIVE_T[2] ? {59'd0, refC} : 64'd0), "1 chain word 10 = segment C (0 when not live)");
	nwords = 4 + (1 + 128) + (1 + 8192) + (1 + 128);
	check(w0[63:32] == 2 * nwords, "1 STATESIZE");
	check(slotmem[3 + 129] == {32'd65536, 24'd0, 8'h01}, "1 RAM TLV after CHAIN");
	check(slotmem[3 + 130 + 100] == {ram[807], ram[806], ram[805], ram[804], ram[803], ram[802], ram[801], ram[800]},
	      "1 RAM word 100 (SDRAM transfer data)");
	check(slotmem[nwords - 1] == 0, "1 end marker");
	f = $fopen("tb_slot.bin", "wb");
	for (i = 0; i < nwords; i = i + 1) begin : dump
		integer b;
		for (b = 0; b < 8; b = b + 1) $fwrite(f, "%c", slotmem[i][b*8 +: 8]);
	end
	$fclose(f);
	crc_a = last_crc;

	// 2. save again: same CRC, counter 2
	op(0, S1);
	check(last_result == 0 && last_crc == crc_a, "2 save/save CRC equal");
	check(slotmem[S1 - S0][31:0] == 2, "2 change counter = 2");

	// 3. load restores everything
	fill(2);
	check(!same_as_snap(0), "3 state changed before the load");
	op(1, S0);
	check(last_result == 0, "3 load ok");
	check(saw_load_done, "3 load_done pulse");
	check(same_as_snap(0), "3 load restores chain, RAM and Color RAM");

	// 4. save/load/save CRC
	op(0, S2);
	check(last_result == 0 && last_crc == crc_a, "4 save after load: same CRC");

	// 5. damaged slot: CRC error, nothing touched
	fill(3);
	snap;
	slotmem[S1 - S0 + 3 + 129 + 100] = slotmem[S1 - S0 + 3 + 129 + 100] ^ 64'h100;
	op(1, S1);
	check(last_result == 6, "5 damaged slot refused (CRC)");
	check(same_as_snap(0), "5 refused load leaves the machine alone");

	// 6. other configuration
	config_mask = 32'h00000124;
	op(1, S0);
	check(last_result == 5, "6 other config refused");
	check(same_as_snap(0), "6 machine untouched");
	config_mask = 32'h00000123;

	// 7. other format version / chain length
	slotmem[S2 - S0 + 1] = slotmem[S2 - S0 + 1] ^ 64'h10000;
	op(1, S2);
	check(last_result == 4, "7 other chain length refused");
	check(same_as_snap(0), "7 machine untouched");
	slotmem[S2 - S0 + 1] = slotmem[S2 - S0 + 1] ^ 64'h10000 ^ 64'h4;   // chain length back, format 2 -> 6
	op(1, S2);
	check(last_result == 4, "7 other format version refused");
	check(same_as_snap(0), "7 machine untouched");

	// 8. empty slot
	op(1, S3);
	check(last_result == 3, "8 empty slot refused");

	// 9. unknown TLV is skipped: insert tag 0x7E (12 bytes) before the end marker of slot 0
	slotmem[nwords - 1] = {32'd12, 24'd0, 8'h7E};
	slotmem[nwords]     = 64'h1111111111111111;
	slotmem[nwords + 1] = 64'h2222222222222222;
	slotmem[nwords + 2] = 0;
	w0 = 2 * (nwords + 3);
	slotmem[0]          = {w0[31:0], slotmem[0][31:0]};
	slotmem[2]          = {slotmem[2][63:32], crc_ref(0)};
	fill(4);
	op(1, S0);
	check(last_result == 0, "9 slot with an unknown TLV loads");
	fill(1);   // values of the first save
	snap;
	fill(6);
	op(1, S0);
	check(same_as_snap(0), "9 unknown TLV skipped, state restored");

	// 10. inhibit
	inhibit = 1;
	op(0, S3);
	check(last_result == 7, "10 inhibit refuses");
	inhibit = 0;

	// 11. REU of 8 pages (32 KiB stands in for 512 KiB): pages 1, 4, 6 written
	rgn_present = P_REU;
	reu_bytes   = 25'd32768;
	fill(7);
	for (p = 0; p < 4096; p = p + 1) map[p] = (p == 1 || p == 4 || p == 6);
	snap;
	op(0, S3);
	check(last_result == 0 && same_as_snap(0), "11 save with REU pages, machine unchanged");
	kr = 3 + 129 + 8193 + 129;   // REU TLV word in the slot
	k  = S3 - S0 + kr;
	check(slotmem[k] == {32'd3 * 32'd4104, 24'd0, 8'h15}, "11 REU_PAGES TLV after Color RAM: 3 records");
	ok = 1;
	for (rec = 0; rec < 3; rec = rec + 1) begin
		p = (rec == 0) ? 1 : (rec == 1) ? 4 : 6;
		if (slotmem[k + 1 + rec * 513] != {32'd4096, 32'd0 + p}) ok = 0;
		for (i = 0; i < 512; i = i + 1)
			if (slotmem[k + 2 + rec * 513 + i] != {reu[p*4096 + i*8 + 7], reu[p*4096 + i*8 + 6], reu[p*4096 + i*8 + 5],
			    reu[p*4096 + i*8 + 4], reu[p*4096 + i*8 + 3], reu[p*4096 + i*8 + 2], reu[p*4096 + i*8 + 1], reu[p*4096 + i*8]})
				ok = 0;
	end
	check(ok, "11 records: page index and page data, increasing");
	check(slotmem[k + 1 + 3 * 513] == 0, "11 end marker after the last record");
	check(slotmem[S3 - S0][63:32] == 2 * (kr + 2 + 3 * 513), "11 STATESIZE counts the records only");
	check(slotmem[S3 - S0 + 2][31:0] == crc_ref(S3 - S0), "11 CRC with records");
	// the machine writes pages 0, 3, 4 and 7 afterwards; pages 2 and 5 never
	n1 = 0;
	for (p = 0; p < 8; p = p + 1) begin
		if (p == 0 || p == 3 || p == 4 || p == 7) begin
			map[p] = 1;
			for (i = 0; i < 4096; i = i + 1) reu[p*4096 + i] = 8'hEE;
		end
	end
	for (i = 0; i < 4096; i = i + 1) begin reu[2*4096 + i] = 8'h5A; reu[5*4096 + i] = 8'h5B; end   // unwritten pages: left alone
	for (i = 0; i < 4096; i = i + 1) begin ref_reu[2*4096 + i] = 8'h5A; ref_reu[5*4096 + i] = 8'h5B; end
	for (p = 0; p < 8; p = p + 1) if (p == 0 || p == 3 || p == 7) for (i = 0; i < 4096; i = i + 1) ref_reu[p*4096 + i] = 8'h00;
	op(1, S3);
	check(last_result == 0, "11 load with REU pages");
	check(same_as_snap(0), "11 pages restored, written pages not in the slot zeroed, the others untouched, map as saved");
	op(0, S4);
	check(last_result == 0 && slotmem[S4 - S0 + 2][31:0] == slotmem[S3 - S0 + 2][31:0], "11 save after the load equals the slot");

	// 12. REU record structure damaged with a valid CRC: page order swapped
	snap;
	w0 = slotmem[S4 - S0 + kr + 1];
	slotmem[S4 - S0 + kr + 1] = slotmem[S4 - S0 + kr + 1 + 513];
	slotmem[S4 - S0 + kr + 1 + 513] = w0;
	slotmem[S4 - S0 + 2] = {slotmem[S4 - S0 + 2][63:32], crc_ref(S4 - S0)};
	for (p = 0; p < 4096; p = p + 1) map[p] = (p == 2);
	snap;
	op(1, S4);
	check(last_result == 6, "12 REU records out of order refused (structure)");
	check(same_as_snap(0), "12 refused load leaves REU, map and machine alone");

	// 13. format 1 slot: the whole REU under REU_RAM loads and marks every page
	fill(12);
	for (p = 0; p < 4096; p = p + 1) map[p] = 0;
	snap;
	// slot S4: header, CHAIN, RAM, Color RAM as in S3, then REU_RAM 32 KiB, end
	for (i = 1; i < kr; i = i + 1) slotmem[S4 - S0 + i] = slotmem[S3 - S0 + i];
	slotmem[S4 - S0 + 1] = {slotmem[S3 - S0 + 1][63:16], 16'd1};
	slotmem[S4 - S0 + kr] = {32'd32768, 24'd0, 8'h09};
	for (i = 0; i < 4096; i = i + 1)
		slotmem[S4 - S0 + kr + 1 + i] = {ref_reu[i*8 + 7], ref_reu[i*8 + 6], ref_reu[i*8 + 5], ref_reu[i*8 + 4],
		                                ref_reu[i*8 + 3], ref_reu[i*8 + 2], ref_reu[i*8 + 1], ref_reu[i*8]};
	slotmem[S4 - S0 + kr + 1 + 4096] = 0;
	w0 = 2 * (kr + 2 + 4096);
	slotmem[S4 - S0] = {w0[31:0], 32'd9};
	// chain and RAM of S3 (fill(7)): the reference is what S3 holds
	fill(7);
	snap;
	for (i = 0; i < REU_MAX; i = i + 1) ref_reu[i] = slotmem[S4 - S0 + kr + 1 + i / 8][(i % 8) * 8 +: 8];
	for (p = 0; p < 8; p = p + 1) ref_map[p] = 1;
	slotmem[S4 - S0 + 2] = {slotmem[S4 - S0 + 2][63:32], crc_ref(S4 - S0)};
	fill(13);
	for (p = 0; p < 4096; p = p + 1) map[p] = 0;
	op(1, S4);
	check(last_result == 0, "13 format 1 slot (whole REU) loads");
	check(same_as_snap(0), "13 whole REU restored, every page marked written");

	// 14. REU larger than the slot
	reu_bytes = 25'h1000000;
	op(0, S3);
	check(last_result == 2, "14 16 MiB REU does not fit a 2 MiB slot");
	rgn_present = P_BASE;
	reu_bytes   = 0;
	for (p = 0; p < 4096; p = p + 1) map[p] = 0;

	// 15. no SD copy: the change counter is not written
	w0 = slotmem[S1 - S0];
	sd_count = 0;
	op(0, S1);
	check(last_result == 0 && slotmem[S1 - S0][31:0] == w0[31:0], "15 counter kept without SD copy");
	sd_count = 1;

	// 16. forced boundary: idle never true at a sample
	idle_rand = 0;
	@(posedge clk);
	#1 idle = 3'b101;
	w0 = slotmem[S2 - S0];
	w2 = slotmem[S2 - S0 + 2];
	op(0, S2);
	check(last_result == 1, "16 forced save abandoned");
	check(slotmem[S2 - S0] == w0 && slotmem[S2 - S0 + 2] == w2, "16 slot untouched by the forced save");
	check(block == 3'b101, "16 watchdog records the blocking idle bit");
	fill(9);
	snap;
	op(1, S1);
	check(last_result == 0, "16 forced load proceeds");
	idle_rand = 1;

	// 17. hold keeps the machine frozen after the operation
	hold = 1;
	@(posedge clk) save <= 1;
	@(posedge clk) save <= 0;
	@(posedge clk);
	while (!done) @(posedge clk);
	repeat (200) @(posedge clk);
	check(freeze_req && c64_pause, "17 hold keeps the freeze");
	hold = 0;
	repeat (200) @(posedge clk);
	check(!c64_pause, "17 released after hold");

	drv_on = 0;
	repeat (400) @(posedge clk);
	check(drive_slot_writes == 0, "drive writes outside the drive window never land");
	check(drv_got_beats == drv_req_beats, "every drive read beat arrives");
	check(drv_served_in_session > 0, "the drive is served during engine sessions (burst arbitration)");
	check(max_burst == 32, "engine write bursts of 32 words");
	check(sd_bad == 0, "SDRAM transfers stay inside their regions");
	$display("tb_savestates: %0d SDRAM transfers, %0d drive requests served during sessions", sd_xfers, drv_served_in_session);

	if (errors == 0) $display("tb_savestates: PASS");
	else $display("tb_savestates: FAIL (%0d errors)", errors);
	$finish;
end

// non-forced freezes only on an all-idle sample
reg ack_d = 0;
always @(posedge clk) begin
	ack_d <= freeze_ack;
	if (freeze_ack && !ack_d && !freeze_forced && !idle_at_sample) check(0, "ack without all idle at the sample");
end

initial begin
	#400000000;
	$display("tb_savestates: FAIL (timeout)");
	$finish;
end

endmodule
