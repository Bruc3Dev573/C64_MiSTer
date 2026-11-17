// tb_savestates: savestate engine (rtl/savestate/savestates.sv) with the DDR3
// arbiter (ss_ddram_arb), a DDR3 model with random waitrequest/latency and a
// drive master hammering the port, the freeze controller (ss_freeze) in front
// of a model of the fpga64 pause sampling, a 75-bit test chain (three
// segments, one empty) and byte regions with random latency.
//
//   iverilog -g2012 -I rtl/savestate -o tb sim/ss/tb_chain_defs.vh \
//       sim/ss/tb_savestates.sv rtl/savestate/*.sv && vvp tb
//
// Checks: save/load round trip (chain, RAM, Color RAM, optional REU region),
// chain unchanged by a save, save/save CRC, slot header protocol (cleared
// first, counter byte enables), refusals that leave the machine untouched
// (CRC, config, version, empty slot, inhibit), unknown TLV skipped, forced
// boundary (save abandoned, load proceeds), REU too big, drive cache never
// writes the slot window. The slot is dumped to tb_slot.bin for
// sim/scripts/ss_slot.py (CRC cross-check with zlib).

`timescale 1ns/1ps

module tb_savestates #(parameter [2:0] LIVE_T = 3'b111);   // 3'b001: segment C not instrumented

reg clk = 0;
always #5 clk = ~clk;

integer errors = 0;
task check(input cond, input [8*64-1:0] what);
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
wire [28:0] e_addr;
wire [63:0] e_wdata, e_rdata;
wire  [7:0] e_be;
wire        e_req, e_we, e_ack;

savestates #(.BUILD_HASH(32'hCAFE0001), .SETTLE(20), .WDOG_BITS(16), .LIVE({29'd0, LIVE_T})) eng
(
	.clk(clk), .reset(1'b0),
	.save(save), .load(load), .slot_addr(slot_addr), .hold(hold), .sd_count(sd_count), .inhibit(inhibit),
	.busy(busy), .done(done), .result(result), .result_load(result_load), .last_crc(last_crc),
	.freeze_req(freeze_req), .freeze_ack(freeze_ack), .freeze_forced(freeze_forced),
	.config_mask(config_mask), .rgn_present(rgn_present), .reu_bytes(reu_bytes),
	.chain_en(chain_en), .chain_so(chain_so), .chain_si(chain_si), .loading(loading), .load_done(load_done),
	.rgn_tag(rgn_tag), .rgn_addr(rgn_addr), .rgn_req(rgn_req), .rgn_we(rgn_we), .rgn_wdata(rgn_wdata),
	.rgn_rdata(rgn_rdata), .rgn_ack(rgn_ack),
	.ddr_addr(e_addr), .ddr_wdata(e_wdata), .ddr_be(e_be), .ddr_req(e_req), .ddr_we(e_we),
	.ddr_rdata(e_rdata), .ddr_ack(e_ack)
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
always @(posedge clk) if ((chain_en || rgn_req) && !c64_pause) check(0, "state access while the machine runs");
// a non-forced ack must come from a sample with all blocks idle
reg idle_at_sample = 0;
always @(posedge clk) if (phase == 5'd7) idle_at_sample <= &idle;

// ------------------------------------------------------------ regions
reg [7:0] ram  [0:65535];
reg [7:0] cram [0:1023];
reg [7:0] reu  [0:8191];
reg [3:0] rlat = 0;
reg       rpend = 0;
always @(posedge clk) begin
	rgn_ack <= 0;
	if (rgn_req) begin
		rpend <= 1;
		rlat  <= $random;
		if (rgn_tag != 8'h01 && rgn_tag != 8'h02 && rgn_tag != 8'h09) check(0, "access to a region not present");
	end
	else if (rpend) begin
		if (rlat == 0) begin
			rpend   <= 0;
			rgn_ack <= 1;
			case (rgn_tag)
				8'h01: begin if (rgn_we) ram[rgn_addr[15:0]]  <= rgn_wdata; rgn_rdata <= ram[rgn_addr[15:0]]; end
				8'h02: begin if (rgn_we) cram[rgn_addr[9:0]]  <= rgn_wdata & 8'h0F; rgn_rdata <= cram[rgn_addr[9:0]]; end
				8'h09: begin if (rgn_we) reu[rgn_addr[12:0]]  <= rgn_wdata; rgn_rdata <= reu[rgn_addr[12:0]]; end
			endcase
		end
		else rlat <= rlat - 1'd1;
	end
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
	.e_session(busy), .e_req(e_req), .e_we(e_we), .e_addr(e_addr), .e_wdata(e_wdata), .e_be(e_be),
	.e_ack(e_ack), .e_rdata(e_rdata),
	.DDRAM_BUSY(DDRAM_BUSY), .DDRAM_BURSTCNT(DDRAM_BURSTCNT), .DDRAM_ADDR(DDRAM_ADDR),
	.DDRAM_DOUT(DDRAM_DOUT), .DDRAM_DOUT_READY(DDRAM_DOUT_READY),
	.DDRAM_RD(DDRAM_RD), .DDRAM_WE(DDRAM_WE), .DDRAM_DIN(DDRAM_DIN), .DDRAM_BE(DDRAM_BE)
);

// DDR model: slot window 0x07C00000 + 4 x 2 MiB (words), drive window small
reg [63:0] slotmem [0:(5*29'h40000)-1];
reg [63:0] drvmem  [0:4095];
integer    rd_left = 0;
reg [28:0] rd_addr = 0;
integer    rd_lat = 0;
integer    slot_writes = 0;
integer    drive_slot_writes = 0;
reg        hdr_cleared_first = 1;
reg        first_write_seen = 0;

function [63:0] be_merge(input [63:0] old, input [63:0] d, input [7:0] be);
	integer i;
	begin
		be_merge = old;
		for (i = 0; i < 8; i = i + 1) if (be[i]) be_merge[i*8 +: 8] = d[i*8 +: 8];
	end
endfunction

wire in_slot = (DDRAM_ADDR >= 29'h07C00000) && (DDRAM_ADDR < 29'h07C00000 + 5*29'h40000);

always @(posedge clk) begin
	DDRAM_DOUT_READY <= 0;
	DDRAM_DOUT <= {$random, $random};   // readdata is valid only with readdatavalid
	if (!DDRAM_BUSY && DDRAM_WE) begin
		if (in_slot) begin
			slotmem[DDRAM_ADDR - 29'h07C00000] <= be_merge(slotmem[DDRAM_ADDR - 29'h07C00000], DDRAM_DIN, DDRAM_BE);
			if (!arb.own) drive_slot_writes = drive_slot_writes + 1;
			if (busy && !first_write_seen) begin
				first_write_seen = 1;
				if (DDRAM_ADDR != slot_addr || DDRAM_DIN != 0) hdr_cleared_first = 0;
			end
		end
		else drvmem[DDRAM_ADDR[11:0]] <= DDRAM_DIN;
	end
	if (!DDRAM_BUSY && DDRAM_RD) begin
		rd_left <= DDRAM_BURSTCNT;
		rd_addr <= DDRAM_ADDR;
		rd_lat  <= 2 + {$random} % 6;
	end
	else if (rd_left) begin
		if (rd_lat) rd_lat <= rd_lat - 1;
		else if ({$random} % 4 != 0) begin
			DDRAM_DOUT_READY <= 1;
			DDRAM_DOUT <= (rd_addr >= 29'h07C00000 && rd_addr < 29'h07C00000 + 5*29'h40000) ?
			              slotmem[rd_addr - 29'h07C00000] : drvmem[rd_addr[11:0]];
			rd_addr <= rd_addr + 1'd1;
			rd_left <= rd_left - 1;
		end
	end
	// waitrequest at random, never while a read burst is returning
	DDRAM_BUSY <= ({$random} % 5 == 0);
end

// drive master: random bursts and writes, some into the slot window (must be dropped)
reg drv_on = 1;
integer dr_left = 0;
always @(posedge clk) begin
	if (d_rd & ~d_busy) begin d_rd <= 0; dr_left <= d_burstcnt; end
	if (d_we & ~d_busy) d_we <= 0;
	if (d_dout_ready && dr_left) dr_left <= dr_left - 1;
	if (drv_on && !d_rd && !d_we && dr_left == 0 && ({$random} % 40 == 0)) begin
		if ($random % 2) begin
			d_rd <= 1; d_burstcnt <= 1 + {$random} % 8; d_addr <= 29'h06000000 + ({$random} % 256);
		end
		else begin
			d_we <= 1; d_din <= {$random, $random};
			d_addr <= ({$random} % 3 == 0) ? 29'h07C00000 + ({$random} % 16) : 29'h06000000 + ({$random} % 256);
		end
	end
end

// ------------------------------------------------------------ helpers
reg [69:0] refA;
reg  [4:0] refC;
reg  [7:0] ref_ram  [0:65535];
reg  [7:0] ref_cram [0:1023];
reg  [7:0] ref_reu  [0:8191];
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
		for (i = 0; i < 8192; i = i + 1) reu[i] = $random(s);
	end
endtask

task snap;
	begin
		refA = segA; refC = segC;
		for (i = 0; i < 65536; i = i + 1) ref_ram[i] = ram[i];
		for (i = 0; i < 1024; i = i + 1) ref_cram[i] = cram[i];
		for (i = 0; i < 8192; i = i + 1) ref_reu[i] = reu[i];
	end
endtask

function same_as_snap(input dummy);
	integer k;
	begin
		same_as_snap = (segA === refA) && (segC === refC || !LIVE_T[2]);
		for (k = 0; k < 65536; k = k + 1) if (ram[k] !== ref_ram[k]) same_as_snap = 0;
		for (k = 0; k < 1024; k = k + 1) if (cram[k] !== ref_cram[k]) same_as_snap = 0;
		for (k = 0; k < reu_bytes && k < 8192; k = k + 1) if (reu[k] !== ref_reu[k]) same_as_snap = 0;
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

localparam [28:0] S0 = 29'h07C00000, S1 = 29'h07C40000, S2 = 29'h07C80000, S3 = 29'h07CC0000;
reg [31:0] crc_a, crc_b;
reg [63:0] w0, w2;
integer f, nwords;

initial begin
	for (i = 0; i < 5*29'h40000; i = i + 1) slotmem[i] = 0;
	for (i = 0; i < 4096; i = i + 1) drvmem[i] = 0;
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
	check(slotmem[1] == {32'hCAFE0001, LIVE_T[2] ? 16'd75 : 16'd70, 16'd1}, "1 payload header w1 (live chain bits)");
	check(slotmem[2][63:32] == config_mask, "1 config mask");
	check(slotmem[2][31:0] == crc_ref(0), "1 CRC matches the tb reference");
	check(last_crc == slotmem[2][31:0], "1 last_crc");
	check(slotmem[3] == {32'd1024, 24'd0, 8'h40}, "1 first TLV is CHAIN, 1024 bytes");
	check(slotmem[3 + 1] == refA[63:0], "1 chain word 0 = segment A bits 63:0");
	check(slotmem[3 + 2] == {58'd0, refA[69:64]}, "1 chain word 1 = segment A bits 69:64");
	check(slotmem[3 + 11] == (LIVE_T[2] ? {59'd0, refC} : 64'd0), "1 chain word 10 = segment C (0 when not live)");
	nwords = 4 + (1 + 128) + (1 + 8192) + (1 + 128);
	check(w0[63:32] == 2 * nwords, "1 STATESIZE");
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

	// 11. optional REU region round trip (4 KiB stands in for 512 KiB)
	rgn_present = P_REU;
	reu_bytes   = 25'd4096;
	fill(7);
	snap;
	op(0, S3);
	check(last_result == 0, "11 save with REU");
	check(slotmem[S3 - S0 + 3 + 129 + 8193 + 129] == {32'd4096, 24'd0, 8'h09}, "11 REU TLV after Color RAM");
	fill(8);
	op(1, S3);
	check(last_result == 0 && same_as_snap(0), "11 REU region restored");

	// 12. REU larger than the slot
	reu_bytes = 25'h1000000;
	op(0, S3);
	check(last_result == 2, "12 16 MiB REU does not fit a 2 MiB slot");
	rgn_present = P_BASE;
	reu_bytes   = 0;

	// 13. no SD copy: the change counter is not written
	w0 = slotmem[S1 - S0];
	sd_count = 0;
	op(0, S1);
	check(last_result == 0 && slotmem[S1 - S0][31:0] == w0[31:0], "13 counter kept without SD copy");
	sd_count = 1;

	// 14. forced boundary: idle never true at a sample
	idle_rand = 0;
	@(posedge clk);
	#1 idle = 3'b101;
	w0 = slotmem[S2 - S0];
	w2 = slotmem[S2 - S0 + 2];
	op(0, S2);
	check(last_result == 1, "14 forced save abandoned");
	check(slotmem[S2 - S0] == w0 && slotmem[S2 - S0 + 2] == w2, "14 slot untouched by the forced save");
	check(block == 3'b101, "14 watchdog records the blocking idle bit");
	fill(9);
	snap;
	op(1, S0);
	check(last_result == 0, "14 forced load proceeds");
	idle_rand = 1;

	// 15. hold keeps the machine frozen after the operation
	hold = 1;
	@(posedge clk) save <= 1;
	@(posedge clk) save <= 0;
	@(posedge clk);
	while (!done) @(posedge clk);
	repeat (200) @(posedge clk);
	check(freeze_req && c64_pause, "15 hold keeps the freeze");
	hold = 0;
	repeat (200) @(posedge clk);
	check(!c64_pause, "15 released after hold");

	check(drive_slot_writes == 0, "drive writes never reach the slot window");

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
	#200000000;
	$display("tb_savestates: FAIL (timeout)");
	$finish;
end

endmodule
