//-------------------------------------------------------------------------------
//
// C1541 multi-drive implementation with shared ROM
// (C) 2021 Alexey Melnikov
//
// Input clock/ce 16MHz
//
//
// DDRAM arbiter by Robin Wünderlich
//-------------------------------------------------------------------------------


module c1541_multi #(parameter PARPORT=1,DUALROM=1,DRIVES=2)
(
	//clk ports
	input         clk,
	input   [N:0] reset,
	input         ce,

	input         pause,
	input   [N:0] gcr_mode,

	input   [N:0] img_mounted,
	input         img_readonly,
	input  [31:0] img_size,
	input   [2:0] drive_rpm,
	input         drive_wobble,

	output  [N:0] led,
	output wire [6:0] out_track[NDR],
	output wire [N:0] out_we,
	output        disk_ready,

	input         iec_atn_i,
	input         iec_data_i,
	input         iec_clk_i,
	output        iec_data_o,
	output        iec_clk_o,

	// parallel bus
	input         par_force,
	input   [7:0] par_data_i,
	input         par_stb_i,
	output  [7:0] par_data_o,
	output        par_stb_o,

	//clk_sys ports
	input         clk_sys,

	output [31:0] sd_lba[NDR],
	output  [5:0] sd_blk_cnt[NDR],
	output  [N:0] sd_rd,
	output  [N:0] sd_wr,
	input   [N:0] sd_ack,
	input  [13:0] sd_buff_addr,
	input   [7:0] sd_buff_dout,
	output  [7:0] sd_buff_din[NDR],
	input         sd_buff_wr,

	input  [14:0] rom_addr,
	input   [7:0] rom_data,
	input         rom_wr,
	input         rom_std,

	input         DDRAM_BUSY,
	output  [7:0] DDRAM_BURSTCNT,
	output [28:0] DDRAM_ADDR,
	input  [63:0] DDRAM_DOUT,
	input         DDRAM_DOUT_READY,
	output        DDRAM_RD,
	output        DDRAM_WE,
	output [63:0] DDRAM_DIN,
	output  [7:0] DDRAM_BE,

	// savestate (WP A8, docs/SAVESTATES.md): chain ss_si -> unit 9 (DRV9_1541)
	// -> glue -> unit 8 -> ss_so (glue + unit 8 = DRV8_1541), regions of the
	// units through the byte port, freeze boundary of the units
	input         ss_en,
	input         ss_hold,
	input         ss_load_done,
	input         ss_si,
	output        ss_so,
	output        ss_idle,
	input [3*NDR-1:0] ss_rgn_sel,   // unit i: bits [3*i +: 3] = {TRACK, EXTRAM, RAM}
	input  [12:0] ss_rgn_addr,
	input         ss_rgn_req,
	input         ss_rgn_we,
	input   [7:0] ss_rgn_wdata,
	output reg [7:0] ss_rgn_rdata,
	output        ss_rgn_ack
);

localparam NDR = (DRIVES < 1) ? 1 : (DRIVES > 4) ? 4 : DRIVES;
localparam N   = NDR - 1;

// The drives stop on the same clocks as the C64: fpga64 freezes on sysCycle
// EXT4 and runs EXT5 (where it samples the IEC lines) on the second clock
// after c64_pause falls, and drive_ce is 0 on exactly the clocks where pause
// was high one clock before. The every-clock logic of the drives holds on
// that (stop); the ph2 pulses made from the last drive_ce wait in their
// registers (on the chain) until the drives run again.
reg  [1:0] stop_r = 0;
always @(posedge clk) stop_r <= {stop_r[0], pause};
wire stop = stop_r[0];
wire stop_end = stop_r[1] & ~stop_r[0];   // first clock the drives run again

// The engine takes the block RAM ports of the units, the outputs hold and
// the reset is released (hold) from the second stopped clock on: iecdrv_mem
// writes the data one clock after the address, so a RAM write of a drive CPU
// registered on the last running clock completes with the CPU data before
// the port is the engine's (the CPU writes only while the drive runs).
wire hold = ss_hold & &stop_r;

// IEC synchronizers (on the chain, hold with the drives)
reg  [2:0] atn_s, dat_s, clk_s;   // {out, s2, s1}
wire iec_atn = atn_s[2], iec_data = dat_s[2], iec_clk = clk_s[2];

// drive reset: follows the host/OSD level, released while the engine owns
// the machine (the T65 reset is asynchronous and would clear its chain)
wire [N:0] reset_drv;
iecdrv_sync #(NDR) rst_sync(clk, reset, reset_drv);
wire [N:0] reset_unit = reset_drv & ~{NDR{hold}};

wire stdrom = (DUALROM || PARPORT) ? rom_std : 1'b1;

initial begin
	rom_32k_i = 1;
	rom_16k_i = 1;
end

reg rom_32k_i;
reg rom_16k_i;
always @(posedge clk_sys) if (rom_wr & |rom_data & ~&rom_data) {rom_32k_i,rom_16k_i} <= rom_addr[14:13];

reg [1:0] rom_sz;
always @(posedge clk) rom_sz <= {rom_32k_i,rom_32k_i|rom_16k_i}; // support for 8K/16K/32K ROM

reg ph2_r;
reg ph2_f;
reg [3:0] div;
always @(posedge clk) begin
	if (ss_en) {ph2_f, ph2_r, div} <= {ss_d[64:63], ss_d[3:0]};
	else if (~stop) begin
		ph2_r <= 0;
		ph2_f <= 0;
		if(ce) begin
			div <= div + 1'd1;
			ph2_r <= !div[3] && !div[2:0];
			ph2_f <=  div[3] && !div[2:0];
		end
	end
end

// drive_ce is 0 while the machine is stopped: the drive CPU, the VIAs (ph2)
// and the disk mechanics stop and resume together
wire drv_ce = ce;

// Mounts reach the units as a 4-clock pulse made from the host strobe edge,
// with the image size and write protect latched there. A mount writes chain
// registers of the unit, so the pulse waits while the engine owns the
// machine (the bits of a savestate pass through them then).
reg  [N:0] mnt_old = 0, mnt_pend = 0, mnt_pulse = 0;
reg  [1:0] mnt_cnt = 0;
reg [31:0] mnt_size;
reg        mnt_ro;
wire [N:0] mnt_new = img_mounted & ~mnt_old;
always @(posedge clk) begin
	mnt_old <= img_mounted;
	if (|mnt_new) {mnt_size, mnt_ro} <= {img_size, img_readonly};
	if (|mnt_pulse) begin
		mnt_cnt <= mnt_cnt + 1'd1;
		if (&mnt_cnt) mnt_pulse <= 0;
	end
	if (~|mnt_pulse & |mnt_pend & ~hold) begin
		mnt_pulse <= mnt_pend;
		mnt_cnt   <= 0;
		mnt_pend  <= mnt_new;
	end
	else mnt_pend <= mnt_pend | mnt_new;
end

// identity of each new mount (savestate: a load into another image)
reg [15:0] mount_seed = 0;
always @(posedge clk) mount_seed <= mount_seed + 1'd1;

wire [7:0] rom_do;
generate
	if(PARPORT) begin
		iecdrv_mem #(8,15,"rtl/iec_drive/c1541_dolphin.mif") rom
		(
			.clock_a(clk_sys),
			.address_a(rom_addr),
			.data_a(rom_data),
			.wren_a(rom_wr),

			.clock_b(clk),
			.address_b(mem_a),
			.q_b(rom_do)
		);
	end
	else if(DUALROM) begin
		iecdrv_mem #(8,14,"rtl/iec_drive/c1541_rom.mif") rom
		(
			.clock_a(clk_sys),
			.address_a(rom_addr[13:0]),
			.data_a(rom_data),
			.wren_a(rom_wr),

			.clock_b(clk),
			.address_b(mem_a[13:0]),
			.q_b(rom_do)
		);
	end
	else begin
		assign rom_do = romstd_do;
	end
endgenerate

wire [7:0] romstd_do;
iecdrv_mem #(8,14,"rtl/iec_drive/c1541_rom.mif") romstd
(
	.clock_a(clk_sys),
	.address_a(rom_addr[13:0]),
	.data_a(rom_data),
	.wren_a((DUALROM || PARPORT) ? 1'b0 : rom_wr),

	.clock_b(clk),
	.address_b(mem_a[13:0]),
	.q_b(romstd_do)
);

reg  [14:0] mem_a;
wire [14:0] drv_addr[NDR];
reg   [7:0] drv_data[4];
reg   [2:0] state;
always @(posedge clk) begin
	if (ss_en) begin
		{state, mem_a} <= {ss_d[6:4], ss_d[21:7]};
		drv_data[0] <= ss_d[29:22];
		drv_data[1] <= ss_d[37:30];
		drv_data[2] <= ss_d[45:38];
		drv_data[3] <= ss_d[53:46];
		{clk_s, dat_s, atn_s} <= ss_d[62:54];
	end
	else if (~stop) begin
		// The ROM read latency runs on every clock (block RAM port registers):
		// a fetch cut by a stop is redone from the first unit when the drives
		// run again (same addresses, same bytes, long before the next ph2_f).
		if(~&state) state <= state + 1'd1;
		if(ph2_f | stop_end) state <= 0;

		case(state)
			0,1,2,3: mem_a <= {drv_addr[state[1:0]][14] & rom_sz[1], drv_addr[state[1:0]][13] & (rom_sz[0] | stdrom), drv_addr[state[1:0]][12:0]};
		endcase

		case(state)
			3,4,5,6: drv_data[state[1:0] - 2'd3] <= stdrom ? romstd_do : rom_do;
		endcase

		atn_s <= {(atn_s[1] == atn_s[0]) ? atn_s[1] : atn_s[2], atn_s[0], iec_atn_i};
		dat_s <= {(dat_s[1] == dat_s[0]) ? dat_s[1] : dat_s[2], dat_s[0], iec_data_i};
		clk_s <= {(clk_s[1] == clk_s[0]) ? clk_s[1] : clk_s[2], clk_s[0], iec_clk_i};
	end
end

// chain: ss_c[i+1] -> unit i -> ss_c[i] for the units above 0, then
// ss_c[1] -> glue -> unit 0 -> ss_c[0]
wire [NDR:0] ss_c;
assign ss_c[NDR] = ss_si;
assign ss_so     = ss_c[0];

// glue part of DRV8_1541, bit 0 leaves first: div, state, mem_a, drv_data[0..3],
// the ATN, DATA and CLK synchronizers ({s1, s2, out} each), then ph2_r, ph2_f
wire [64:0] ss_q = {ph2_f, ph2_r, clk_s, dat_s, atn_s, drv_data[3], drv_data[2], drv_data[1], drv_data[0], mem_a, state, div};
wire [64:0] ss_d = {ss_c[1], ss_q[64:1]};
wire        ss_glue_so = ss_q[0];

wire [N:0] iec_data_d, iec_clk_d;
wire       iec_clk_l  = &{iec_clk_d  | reset_drv};
wire       iec_data_l = &{iec_data_d | reset_drv};

// Parallel Cable: On bypasses the 32 KB loadable drive ROM requirement.
wire [N:0] ext_en = {NDR{((rom_sz[1] & ~stdrom) | par_force) & |PARPORT}} & ~reset_drv;
wire [7:0] par_data_d[NDR];
wire [N:0] par_stb_d;
wire       par_stb_l = &{par_stb_d | ~ext_en};
reg  [7:0] par_data_l;
always_comb begin
	par_data_l = 8'hFF;
	for(int i=0; i<NDR; i=i+1) if(ext_en[i]) par_data_l = par_data_l & par_data_d[i];
end

wire [N:0] led_drv;
wire [N:0] i_disk_ready;

// The outputs to the C64, the external IEC port and the LEDs keep their value
// while the engine owns the machine: the registers behind them move through
// the chain then. A load shows the loaded outputs from ss_load_done on, so the
// FLAG edge detector of CIA2 (parallel cable strobe) takes them before the
// release instead of seeing a false edge.
wire [N+12:0] out_l = {&(i_disk_ready | reset_drv), led_drv & ~reset_drv, par_data_l, par_stb_l, iec_data_l, iec_clk_l};
reg  [N+12:0] out_h;
always @(posedge clk) if (~hold | ss_load_done) out_h <= out_l;
assign {disk_ready, led, par_data_o, par_stb_o, iec_data_o, iec_clk_o} = hold ? out_h : out_l;

wire [N:0] u_ack, u_idle;
wire [7:0] u_rdata[NDR];
assign ss_idle    = &u_idle;
assign ss_rgn_ack = |u_ack;
always_comb begin
	ss_rgn_rdata = 8'h00;
	for(int i=0; i<NDR; i=i+1) if(u_ack[i]) ss_rgn_rdata = ss_rgn_rdata | u_rdata[i];
end

generate
	genvar i;
	for(i=0; i<NDR; i=i+1) begin :drives
		c1541_drv c1541_drv
		(
			.clk(clk),
			.reset(reset_unit[i]),

			.gcr_mode(gcr_mode[i]),

			.ce(drv_ce),
			.ph2_r(ph2_r),
			.ph2_f(ph2_f),

			.img_mounted(mnt_pulse[i]),
			.img_readonly(mnt_ro),
			.img_size(mnt_size),
			.drive_rpm(drive_rpm),
			.drive_wobble(drive_wobble),

			.drive_num(i),
			.led(led_drv[i]),
			.out_track(out_track[i]),
			.out_we(out_we[i]),
			.disk_ready(i_disk_ready[i]),

			.iec_atn_i(iec_atn),
			.iec_data_i(iec_data & iec_data_o),
			.iec_clk_i(iec_clk & iec_clk_o),
			.iec_data_o(iec_data_d[i]),
			.iec_clk_o(iec_clk_d[i]),

			.par_data_i(par_data_i),
			.par_stb_i(par_stb_i),
			.par_data_o(par_data_d[i]),
			.par_stb_o(par_stb_d[i]),

			.ext_en(ext_en[i]),
			.rom_addr(drv_addr[i]),
			.rom_data(drv_data[i]),

			.clk_sys(clk_sys),

			.sd_lba(sd_lba[i]),
			.sd_blk_cnt(sd_blk_cnt[i]),
			.sd_rd(sd_rd[i]),
			.sd_wr(sd_wr[i]),
			.sd_ack(sd_ack[i]),
			.sd_buff_addr(sd_buff_addr),
			.sd_buff_dout(sd_buff_dout),
			.sd_buff_din(sd_buff_din[i]),
			.sd_buff_wr(sd_buff_wr),

			.DDRAM_BUSY(arb_ddram_busy[i]),
			.DDRAM_DOUT(DDRAM_DOUT),
			.DDRAM_DOUT_READY(arb_ddram_ready[i]),
			.DDRAM_BURSTCNT(drv_ddram_burstcnt[i]),
			.DDRAM_ADDR(drv_ddram_addr[i]),
			.DDRAM_RD(drv_ddram_rd[i]),
			.DDRAM_WE(drv_ddram_we[i]),
			.DDRAM_DIN(drv_ddram_din[i]),
			.DDRAM_BE(drv_ddram_be[i]),

			.stop(stop),
			.mount_seed(mount_seed),
			.ss_en(ss_en),
			.ss_hold(hold),
			.ss_load_done(ss_load_done),
			.ss_si(i ? ss_c[i+1] : ss_glue_so),
			.ss_so(ss_c[i]),
			.ss_idle(u_idle[i]),
			.ss_rgn_sel(ss_rgn_sel[3*i +: 3]),
			.ss_rgn_addr(ss_rgn_addr),
			.ss_rgn_req(ss_rgn_req),
			.ss_rgn_we(ss_rgn_we),
			.ss_rgn_wdata(ss_rgn_wdata),
			.ss_rgn_rdata(u_rdata[i]),
			.ss_rgn_ack(u_ack[i])
		);
	end
endgenerate

wire [7:0]  drv_ddram_burstcnt[NDR];
wire [28:0] drv_ddram_addr[NDR];
wire        arb_ddram_busy[NDR];
wire        arb_ddram_ready[NDR];
wire        drv_ddram_rd[NDR];
wire        drv_ddram_we[NDR];
wire [63:0] drv_ddram_din[NDR];
wire  [7:0] drv_ddram_be[NDR];

// ==============================================================================
// DDRAM Round-Robin Arbiter (Supports Read Bursts)
// ==============================================================================

reg [1:0] arb_rr_state;
reg       arb_is_locked;
reg [7:0] burst_remaining;

// MUX: Route signals for the currently polled/active drive
assign DDRAM_ADDR     = drv_ddram_addr[arb_rr_state];
assign DDRAM_DIN      = drv_ddram_din[arb_rr_state];
assign DDRAM_BE       = drv_ddram_be[arb_rr_state];
assign DDRAM_BURSTCNT = drv_ddram_burstcnt[arb_rr_state];

// Only assert RD/WE if the bus isn't locked by an ongoing fetch
assign DDRAM_RD = arb_is_locked ? 1'b0 : drv_ddram_rd[arb_rr_state];
assign DDRAM_WE = arb_is_locked ? 1'b0 : drv_ddram_we[arb_rr_state];

// BUSY Router: Drive must wait if it's not being polled, bus is locked, or RAM is busy
generate
	genvar arb_i;
	for(arb_i=0; arb_i<NDR; arb_i=arb_i+1) begin : arb_routing_gen
		// Force drive to wait if not polled, bus locked, or RAM busy
		assign arb_ddram_busy[arb_i]  = (arb_rr_state != arb_i[1:0]) || arb_is_locked || DDRAM_BUSY;
		// Only pass the ready pulse to the drive that currently owns the lock
		assign arb_ddram_ready[arb_i] = (arb_rr_state == arb_i[1:0] && arb_is_locked) ? DDRAM_DOUT_READY : 1'b0;
	end
endgenerate

// Polling and Burst-Lock FSM
always @(posedge clk_sys) begin
	if (&reset) begin
		arb_is_locked   <= 1'b0;
		arb_rr_state    <= 2'd0;
		burst_remaining <= 8'd0;
	end else begin
		if (!arb_is_locked) begin
			// POLLING: Check if the current drive wants the bus
			// (the pointer holds while the drives are stopped: they request
			// nothing then, and the next grant comes at the same drive time)
			if (!DDRAM_BUSY && !stop) begin
				if (drv_ddram_rd[arb_rr_state]) begin
					arb_is_locked   <= 1'b1; // Lock bus for the duration of the burst
					burst_remaining <= drv_ddram_burstcnt[arb_rr_state];
				end else if (!drv_ddram_we[arb_rr_state]) begin
					// No request, move to next drive
					arb_rr_state <= (arb_rr_state == N) ? 2'd0 : arb_rr_state + 2'd1;
				end
			end
		end else begin
			// LOCKED: Wait for the burst to complete
			if (DDRAM_DOUT_READY) begin
				if (burst_remaining <= 8'd1) begin
					arb_is_locked <= 1'b0; // Unlock immediately
					// Move to next drive to ensure fairness
					arb_rr_state  <= (arb_rr_state == N) ? 2'd0 : arb_rr_state + 2'd1;
				end else begin
					burst_remaining <= burst_remaining - 8'd1;
				end
			end
		end
	end
end

endmodule
