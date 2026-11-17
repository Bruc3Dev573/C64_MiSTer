//-------------------------------------------------------------------------------
//
// Reworked and adapted to MiSTer by Sorgelig@MiSTer (07.09.2018)
//
// Commodore 1541 to SD card by Dar (darfpga@aol.fr)
// http://darfpga.blogspot.fr
//
// c1541_logic    from : Mark McDougall
// via6522        from : Gideon Zweijtzer  <gideon.zweijtzer@gmail.com>
// c1541_track    from : Sorgelig@MiSTer
//
// c1541_logic    modified for : slow down CPU (EOI ack missed by real c64)
//                             : remove iec internal OR wired
//                             : synched atn_in (sometime no IRQ with real c64)
//
// Input clk ~32MHz (clk_sys from top level, previously labeled 16MHz)
//
//-------------------------------------------------------------------------------

module c1541_drv
(
	//clk ports
	input         clk,
	input         reset,

	input         gcr_mode,

	input         ce,
	input         ph2_r,
	input         ph2_f,

	input         img_mounted,
	input         img_readonly,
	input  [31:0] img_size,
	input   [2:0] drive_rpm,
	input         drive_wobble,

	output reg    disk_ready,

	input   [1:0] drive_num,
	output        led,
	output wire [6:0] out_track,
	output wire    out_we,

	input         iec_atn_i,
	input         iec_data_i,
	input         iec_clk_i,
	output        iec_data_o,
	output        iec_clk_o,

	// parallel bus
	input   [7:0] par_data_i,
	input         par_stb_i,
	output  [7:0] par_data_o,
	output        par_stb_o,

	input         ext_en,
	output [14:0] rom_addr,
	input   [7:0] rom_data,

	//clk_sys ports
	input         clk_sys,

	output [31:0] sd_lba,
	output  [5:0] sd_blk_cnt,
	output        sd_rd,
	output        sd_wr,
	input         sd_ack,
	input  [13:0] sd_buff_addr,
	input   [7:0] sd_buff_dout,
	output  [7:0] sd_buff_din,
	input         sd_buff_wr,

	input         DDRAM_BUSY,
	output  [7:0] DDRAM_BURSTCNT,
	output [28:0] DDRAM_ADDR,
	input  [63:0] DDRAM_DOUT,
	input         DDRAM_DOUT_READY,
	output        DDRAM_RD,
	output        DDRAM_WE,
	output [63:0] DDRAM_DIN,
	output  [7:0] DDRAM_BE,

	// savestate (WP A8, docs/SAVESTATES.md). Chain of the unit, bit 0 out
	// first: c1541_track, direct_gcr (head, encoder, noise LFSR), VIA2, VIA1,
	// T65, then the registers of this module. Regions RAM, EXTRAM and TRACK
	// through a byte port while the engine owns the machine.
	input         stop,          // drive stopped with the machine (ph2 grid): every-clock logic holds
	input  [15:0] mount_seed,    // free-running count: identity of a new mount
	input         ss_en,
	input         ss_hold,
	input         ss_load_done,
	input         ss_si,
	output        ss_so,
	output        ss_idle,       // CPU between instructions, no track transfer starting
	input   [2:0] ss_rgn_sel,    // {TRACK, EXTRAM, RAM} of this unit
	input  [12:0] ss_rgn_addr,
	input         ss_rgn_req,
	input         ss_rgn_we,
	input   [7:0] ss_rgn_wdata,
	output reg [7:0] ss_rgn_rdata,
	output reg    ss_rgn_ack
);

assign led       = act;
assign out_track = track;
assign out_we    = track_modified | busy_flushing_s;

localparam [1:0] IDLE          = 2'd0,
                 // Disk Swap states
                 MOUNT_REMOVED = 2'd1,
                 MOUNT_EMPTY   = 2'd2;

reg  [1:0] state = IDLE;       // a vector: a chain cell must hold any pattern

// readonly, present and mount_id describe the mounted image (host side);
// the mount sequence (state, phase_timer, disk_present, wps_reg) is saved
reg        readonly     = 0;
reg        disk_present = 0;
reg        present      = 0;
reg        old_mounted  = 0;
reg [21:0] phase_timer  = 0;
reg        wps_reg      = 0;
reg [15:0] mount_id     = 0;
reg [15:0] ss_mount_id  = 0;  // mount_id at the save, on the chain

// savestate chain of this module, bit 0 leaves first (fields after cpu_ in
// DRV8_1541 / DRV9_1541); the first bit in comes from the engine side
reg  [6:0] track;
reg  [6:0] track_num;
reg  [1:0] move, stp_old;
reg        save_track = 0;
reg [23:0] read_timer = 0;
reg        track_modified = 0;
wire [85:0] ss_q = {ss_mount_id, read_timer, track_modified, save_track, move, stp_old, track_num, track,
                    wps_reg, disk_present, phase_timer, state};
wire [85:0] ss_d = {ss_si, ss_q[85:1]};

// a load brought the state of another mount: the saved track buffer belongs
// to that image, never write it into this one
wire remount = ss_load_done & (ss_mount_id != mount_id);

always @(posedge clk) begin
	old_mounted <= img_mounted;
	disk_ready  <= (state == IDLE) && (phase_timer == 0);

	if (ss_en) {wps_reg, disk_present, phase_timer, state} <= ss_d[25:0];
	else if (~old_mounted & img_mounted) begin
		readonly <= img_readonly;
		mount_id <= mount_seed;
		if (|img_size) begin
			if (present) begin
				// Mount -> Mount sequence starts by removing Disk
				state        <= MOUNT_REMOVED;
				disk_present <= 0;
				wps_reg      <= 1;
				// ~262ms removal  phase
				phase_timer  <= 22'h3FFFFF;
			end else begin
				// Empty -> Mount sequence starts by adding empty
				// phase before inserting, as a cautionary measure,
				// if drive was just enabled.
				state        <= MOUNT_EMPTY;
				disk_present <= 0;
				wps_reg      <= 0; // Drive empty.
				phase_timer  <= 22'h3FFFFF;
			end
			present          <= 1;
		end else begin
			if (present) begin
				// Mount -> Empty sequence just removes Disk
				state        <= IDLE;
				disk_present <= 0;
				wps_reg      <= 1;
				phase_timer  <= 22'h3FFFFF;
			end else begin     // Already empty
				// Do Nothing
				state        <= IDLE;
				disk_present <= 0;
				wps_reg      <= 0;
				phase_timer  <= 0;
			end
			present <= 0;
		end
	end else if (ce) begin
		if (phase_timer > 0) begin
			phase_timer <= phase_timer - 1'd1;
		end else begin
			// Phase transition dispatcher
			case (state)
				IDLE:          begin
					// IDLE
					// Is the final terminal state for all sequences.
					// Applies the true, final write protect and
					// disk_present status.
					state        <= IDLE;
					disk_present <= present;
					wps_reg      <= present ? readonly : 1'b0;
				end
				MOUNT_REMOVED: begin
					// Leave empty for a while
					state        <= MOUNT_EMPTY;
					phase_timer  <= 22'h3FFFFF;
					disk_present <= 0;
					wps_reg      <= 0;
				end
				MOUNT_EMPTY:  begin
					// Insert Disk
					state        <= IDLE;
					phase_timer  <= 22'h3FFFFF;
					disk_present <= 0;
					wps_reg      <= 1;
				end
				default:      begin
					state        <= IDLE;
					disk_present <= present;
					wps_reg      <= present ? readonly : 1'b0;
				end
			endcase
		end
	end

	if (ss_en) ss_mount_id <= ss_d[85:70];
	else if (~ss_hold) ss_mount_id <= mount_id;
end

wire       mode; // read/write
wire [1:0] stp;
wire       mtr;
wire       act;
wire [1:0] freq;

wire wps_n = ~wps_reg;

wire       cpu_sync;
wire       ss_logic_so, ss_gcr_so;
wire       trk_idle;
wire [7:0] ss_ram_q, ss_extram_q, ss_trk_q;
reg        ss_rgn_wr = 0;

c1541_logic c1541_logic
(
	.clk(clk),
	.reset(reset),

	.ce(ce),
	.ph2_r(ph2_r),
	.ph2_f(ph2_f),

	// serial bus
	.iec_clk_in(iec_clk_i),
	.iec_data_in(iec_data_i),
	.iec_atn_in(iec_atn_i),
	.iec_clk_out(iec_clk_o),
	.iec_data_out(iec_data_o),

	.ext_en(ext_en),
	.rom_addr(rom_addr),
	.rom_data(rom_data),

	// parallel bus
	.par_data_in(par_data_i),
	.par_stb_in(par_stb_i),
	.par_data_out(par_data_o),
	.par_stb_out(par_stb_o),

	// drive-side interface
	.ds(drive_num),
	.din(dgcr_do),
	.dout(dgcr_di),
	.mode(mode),
	.stp(stp),
	.mtr(mtr),
	.freq(freq),
	.sync_n(dgcr_sync_n),
	.byte_n(dgcr_byte_n),
	.wps_n(wps_n),
	.tr00_sense_n(|track),
	.act(act),

	.stop(stop),
	.ss_en(ss_en),
	.ss_hold(ss_hold),
	.ss_si(ss_q[0]),
	.ss_so(ss_logic_so),
	.cpu_sync(cpu_sync),
	.ss_addr(ss_rgn_addr),
	.ss_wdata(ss_rgn_wdata),
	.ss_wr_ram(ss_rgn_wr & ss_rgn_sel[0]),
	.ss_wr_extram(ss_rgn_wr & ss_rgn_sel[1]),
	.ss_ram_q(ss_ram_q),
	.ss_extram_q(ss_extram_q)
);

iecdrv_sync dirty_sync(clk, busy_flushing, busy_flushing_s);
wire        we = dgcr_we;
wire [7:0]  dgcr_do,dgcr_di;
wire [63:0] dgcr_sd_buff_dout;
wire        dgcr_sync_n, dgcr_byte_n, dgcr_we;
wire [13:0] dma_buff_addr;
wire [63:0] dma_buff_dout;
wire        dma_buff_wr;
wire        dma_active;

// Interface bg_buff (64bit) to sd_buff (8bit)
wire [63:0] bg_buff_dout;
assign      sd_buff_din = bg_buff_dout[(sd_buff_addr[2:0]*8) +: 8];

c1541_direct_gcr c1541_direct_gcr
(
	.clk(clk),
	.ce(ce & gcr_mode),
	.reset(reset),
	
	.drive_rpm(drive_rpm),
	.drive_wobble(drive_wobble),
	
	.dout(dgcr_do),
	.din(dgcr_di),
	.mode(mode),
	.mtr(mtr),
	.freq(freq),
	.wps_n(wps_n),
	.sync_n(dgcr_sync_n),
	.byte_n(dgcr_byte_n),

	.disk_present(disk_present),
	.we(dgcr_we),

	.sd_clk(clk_sys),
	.sd_buff_addr(dma_buff_addr),
	.sd_buff_dout(dma_buff_dout),
	.sd_buff_din(dgcr_sd_buff_dout),
	.sd_buff_wr(dma_buff_wr),

	.ss_en(ss_en),
	.ss_si(ss_logic_so),
	.ss_so(ss_gcr_so),
	.ss_hold(ss_hold),
	.ss_addr(ss_rgn_addr),
	.ss_wdata(ss_rgn_wdata),
	.ss_wr(ss_rgn_wr & ss_rgn_sel[2]),
	.ss_rgn_q(ss_trk_q)
);

wire busy_flushing;
wire busy_flushing_s;

c1541_track c1541_track
(
	.clk(clk_sys),
	.reset(reset),

	.gcr_mode(gcr_mode),

	.sd_lba(sd_lba),
	.sd_blk_cnt(sd_blk_cnt),
	.sd_rd(sd_rd),
	.sd_wr(sd_wr),
	.sd_ack(sd_ack),

	.save_track(save_track),
	.change(img_mounted),
	.track(track),
	.busy_flushing(busy_flushing),
	.drive_num(drive_num[0]),

	.DDRAM_BUSY(DDRAM_BUSY),
	.DDRAM_BURSTCNT(DDRAM_BURSTCNT),
	.DDRAM_ADDR(DDRAM_ADDR),
	.DDRAM_DOUT(DDRAM_DOUT),
	.DDRAM_DOUT_READY(DDRAM_DOUT_READY),
	.DDRAM_RD(DDRAM_RD),
	.DDRAM_WE(DDRAM_WE),
	.DDRAM_DIN(DDRAM_DIN),
	.DDRAM_BE(DDRAM_BE),

	.dma_buff_addr(dma_buff_addr),
	.dma_buff_dout(dma_buff_dout),
	.dma_buff_wr(dma_buff_wr),
	.dma_buff_din(dgcr_sd_buff_dout),

	.sd_buff_addr(sd_buff_addr),
	.bg_buff_dout(bg_buff_dout),

	.stop(stop),
	.remount(remount),
	.ss_en(ss_en),
	.ss_si(ss_gcr_so),
	.ss_so(ss_so),
	.ss_idle(trk_idle)
);

// Freeze boundary: CPU between instructions and no track transfer starting;
// no head step on its way to c1541_track either (track_num -> track -> sync).
assign ss_idle = (cpu_sync | reset) & trk_idle & (track == track_num) & ~move[0];

// Every-clock logic holds while the drive is stopped (stop) and shifts on ss_en.
always @(posedge clk) begin
	if (ss_en) {read_timer, track_modified, save_track, move, stp_old, track_num, track} <= ss_d[69:26];
	else if (~stop) begin
		track <= track_num;

		stp_old <= stp;
		move <= stp - stp_old;

		if (we && disk_present) track_modified <= 1;

		if (reset) begin
			track_num <= 34;
			track_modified <= 0;
		end else begin
			if (mtr & move[0]) begin
				if (~move[1] && track_num < 84) track_num <= track_num + 1'b1;
				if ( move[1] && track_num > 0 ) track_num <= track_num - 1'b1;
				// must save modified track on track change
				if (track_modified) save_track <= ~save_track;
				track_modified <= 0;
			end

			// Save Track Strategy:
			// balance SD longevity against data integrity by aggregating writes.
			//
			// Trade-offs:
			// - DOS motor-off is too sluggish (~2s) for modern users.
			// - DOS write-patterns (sector-by-sector) cause 20+ cycles per track.
			// - Poorly behaved software (e.g., track copiers) abuses the LED and motor states.
			//
			// Strategy:
			// We use a Write->Read transition timeout. If the drive has been in read mode for
			// ~500ms since the last write, we assume inactivity and save the track.
			// We also save immediately if the motor turns off.
			if (track_modified && ((mode && read_timer == 24'd16_000_000) || !mtr)) begin
				save_track <= ~save_track;
				track_modified <= 0;
			end
		end

		// Timer for read inactivity (500ms of running clk_sys = 16,000,000 cycles)
		if (!mode) begin // mode 0 = writing
			read_timer <= 0;
		end else if (read_timer != 24'd16_000_000) begin
			read_timer <= read_timer + 1'd1;
		end
	end

	// a new image (also while paused) or another image's saved state: the
	// track buffer is not written back
	if (img_mounted | remount) track_modified <= 0;
end

// Region port (RAM, EXTRAM, TRACK): one byte per request, acknowledged after
// the 2-clock read latency of the block RAMs; writes land on port a meanwhile.
reg [1:0] ss_rgn_cnt = 0;
always @(posedge clk) begin
	ss_rgn_ack <= 0;
	ss_rgn_wr  <= 0;
	if (ss_rgn_req & |ss_rgn_sel) begin
		ss_rgn_cnt <= 1;
		ss_rgn_wr  <= ss_rgn_we;
	end
	else if (ss_rgn_cnt == 1) ss_rgn_cnt <= 2;
	else if (ss_rgn_cnt == 2) begin
		ss_rgn_cnt   <= 0;
		ss_rgn_ack   <= 1;
		ss_rgn_rdata <= ss_rgn_sel[0] ? ss_ram_q : ss_rgn_sel[1] ? ss_extram_q : ss_trk_q;
	end
end

endmodule
