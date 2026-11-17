//-------------------------------------------------------------------------------
//
// Commodore 1581 implementation
// (C) 2021 Alexey Melnikov
//
// Input clock 16MHz
//
//-------------------------------------------------------------------------------

module c1581_drv
(
	//clk ports
	input         clk,
	input         reset,

	input         ce,
	input         wd_ce,
	input         ph2_r,
	input         ph2_f,

	input         img_mounted,
	input         img_readonly,
	input  [31:0] img_size,

	input   [1:0] drive_num,
	output        act_led,
	output        pwr_led,
	// OSD
	output  [7:0] track,
	output        we,

	input         iec_atn_i,
	input         iec_data_i,
	input         iec_clk_i,
	input         iec_fclk_i,
	output        iec_data_o,
	output        iec_clk_o,
	output        iec_fclk_o,

	// parallel bus
	input   [7:0] par_data_i,
	input         par_stb_i,
	output  [7:0] par_data_o,
	output        par_stb_o,

	output [14:0] rom_addr,
	input   [7:0] rom_data,

	//clk_sys ports
	input         clk_sys,

	output [31:0] sd_lba,
	output        sd_rd,
	output        sd_wr,
	input         sd_ack,
	input   [8:0] sd_buff_addr,
	input   [7:0] sd_buff_dout,
	output  [7:0] sd_buff_din,
	input         sd_buff_wr,

	// savestate (WP A10, docs/SAVESTATES.md). Chain of the unit, bit 0 out
	// first: fdc1772 (floppy mechanics, then the WD1772), 8520, VIA, T65, then
	// the disk change line of this module. Regions RAM and FDC_BUF through a
	// byte port while the engine owns the machine.
	input         stop,          // drive stopped with the machine (ph2 grid): every-clock logic holds
	input         ss_en,
	input         ss_hold,       // the engine owns the unit (from the second stopped clock)
	input         ss_si,
	output        ss_so,
	output        ss_idle,       // CPU between instructions, no sector request to the host pending or starting
	input   [1:0] ss_rgn_sel,    // {FDC_BUF, RAM} of this unit
	input  [12:0] ss_rgn_addr,
	input         ss_rgn_req,
	input         ss_rgn_we,
	input   [7:0] ss_rgn_wdata,
	output reg [7:0] ss_rgn_rdata,
	output reg    ss_rgn_ack
);

assign rom_addr = cpu_a[14:0];

// write protect of the mounted image (host side, latched at its mount)
reg wps_n = 0;
always @(posedge clk) begin
	reg prev_mounted;
	prev_mounted <= img_mounted;
	if (~prev_mounted & img_mounted) wps_n <= ~img_readonly;
end

//same decoder as on real HW
wire [2:0] ls193 = cpu_a[15:13];
wire ram_cs      = ls193 == 0;
wire via_cs      = ls193 == 1;
wire cia_cs      = ls193 == 2;
wire wd_cs       = ls193 == 3;
wire rom_cs      = cpu_a[15];

wire  [7:0] cpu_di =
	!cpu_rw ? cpu_do :
	 ram_cs ? ram_do :
	 via_cs ? via_do :
	 cia_cs ? cia_do :
	 wd_cs  ? wd_do  :
	 rom_cs ? rom_data :
	 8'hFF;

wire [23:0] cpu_a;
wire  [7:0] cpu_do;
wire        cpu_rw;
wire        cpu_sync;

wire        ss_cpu_so, ss_via_so, ss_cia_so;
wire        fdc_idle, fdc_sd_rd, fdc_sd_wr;
wire  [7:0] ss_fdc_q;
reg         ss_rgn_wr = 0;
reg         disk_chng_n;

T65 cpu
(
	.clk(clk),
	.enable(ph2_r & ~stop),   // T65 SS_Hold freezes only its SO sampler: a ph2_r held while stopped, or a chain bit passing through it, must not step the CPU
	.mode(2'b00),
	.res_n(~reset),
	.irq_n(cia_irq_n & ~via_irq),
	.r_w_n(cpu_rw),
	.sync(cpu_sync),
	.A(cpu_a),
	.DI(cpu_di),
	.DO(cpu_do),

	.SS_En(ss_en),
	.SS_Hold(stop),
	.SS_SI(disk_chng_n),
	.SS_SO(ss_cpu_so)
);

// The CPU writes on the ph2_f of running clocks only. iecdrv_mem takes the
// data one clock after the address, so the engine takes the write port a
// (ss_hold) one clock after the drive stopped, when a write of the last
// running clock is in. The engine reads through the CPU read port b, on the
// clock of its request only: a read on port a would make Quartus add a
// second copy of the RAM (8 M10K).
wire [7:0] ram_do;
iecdrv_mem #(8,13) ram
(
	.clock_a(clk),
	.address_a(ss_hold ? ss_rgn_addr : cpu_a[12:0]),
	.data_a(ss_hold ? ss_rgn_wdata : cpu_do),
	.wren_a(ss_hold ? ss_rgn_wr & ss_rgn_sel[0] : ph2_f & ~stop & ~cpu_rw & ram_cs),

	.clock_b(clk),
	.address_b(ss_hold & ss_rgn_req & ss_rgn_sel[0] ? ss_rgn_addr : cpu_a[12:0]),
	.q_b(ram_do)
);

wire [7:0] cia_do;
wire       cia_irq_n;

assign     act_led    =  pa_out[6];
assign     pwr_led    =  pa_out[5];
wire       motor_n    =  pa_out[2];
wire       side       =  pa_out[0];
wire [7:0] pa_in      = {disk_chng_n, 2'b11, drive_num, 1'b1, ~floppy_ready, 1'b1};

wire       fast_dir   =  pb_out[5];
assign     iec_clk_o  = ~pb_out[3];
assign     iec_data_o = ~pb_out[1] & ~(pb_out[4] & ~iec_atn_i) & (~fast_dir | sp_out);
assign     iec_fclk_o = ~fast_dir | cnt_out;
wire [7:0] pb_in      = {~iec_atn_i, wps_n, 3'b111, ~iec_clk_i, 1'b1, ~iec_data_i};

wire [7:0] pa_out;
wire [7:0] pb_out;

wire       sp_out;
wire       cnt_out;

iecdrv_mos8520 cia
(
	.clk(clk),
	.phi2_p(ph2_r),
	.phi2_n(ph2_f),
	.res_n(~reset),
	.cs_n(~cia_cs),
	.rw(cpu_rw),

	.rs(cpu_a[3:0]),
	.db_in(cpu_do),
	.db_out(cia_do),

	.pa_in(pa_in & pa_out),
	.pa_out(pa_out),
	.pb_in(pb_in & pb_out),
	.pb_out(pb_out),

	.flag_n(iec_atn_i),

	.tod(ph2_f),

	.sp_in(fast_dir | iec_data_i),
	.sp_out(sp_out),

	.cnt_in(fast_dir | iec_fclk_i),
	.cnt_out(cnt_out),

	.irq_n(cia_irq_n),

	.stop(stop),
	.ss_en(ss_en),
	.ss_si(ss_via_so),
	.ss_so(ss_cia_so)
);


wire [7:0] via_do;
wire       via_irq;
wire [7:0] via_pa_o;
wire [7:0] via_pa_oe;
wire       via_ca2_o;
wire       via_ca2_oe;
wire [7:0] via_pb_o;
wire [7:0] via_pb_oe;
wire       via_cb1_o;
wire       via_cb1_oe;
wire       via_cb2_o;
wire       via_cb2_oe;

assign     par_stb_o  = via_ca2_o | ~via_ca2_oe;
assign     par_data_o = via_pa_o  | ~via_pa_oe;

iecdrv_via6522 via
(
	.clock(clk),
	.rising(ph2_f),
	.falling(ph2_r),
	.reset(reset),

	.addr(cpu_a[3:0]),
	.wen(~cpu_rw & via_cs),
	.ren(cpu_rw & via_cs),
	.data_in(cpu_do),
	.data_out(via_do),

	.port_a_o(via_pa_o),
	.port_a_t(via_pa_oe),
	.port_a_i(par_data_i & (via_pa_o  | ~via_pa_oe)),

	.port_b_o(via_pb_o),
	.port_b_t(via_pb_oe),
	.port_b_i(via_pb_o | ~via_pb_oe),

	.ca1_i(1'b1),

	.ca2_o(via_ca2_o),
	.ca2_t(via_ca2_oe),
	.ca2_i(via_ca2_o | ~via_ca2_oe),

	.cb1_o(via_cb1_o),
	.cb1_t(via_cb1_oe),
	.cb1_i(par_stb_i & (via_cb1_o | ~via_cb1_oe)),

	.cb2_o(via_cb2_o),
	.cb2_t(via_cb2_oe),
	.cb2_i(via_cb2_o | ~via_cb2_oe),

	.irq(via_irq),

	.ss_en(ss_en),
	.ss_stop(stop),
	.ss_si(ss_cpu_so),
	.ss_so(ss_via_so)
);


// disk change line (PA7, on the chain, first bit in): a mount or the reset
// clears it, the first head step sets it; the step pulse is a chain register,
// so it counts only while the drive runs
always @(posedge clk) begin
	if (ss_en) disk_chng_n <= ss_si;
	else begin
		if(img_mounted | reset) disk_chng_n <=0;
		if(floppy_step & ~stop) disk_chng_n <=1;
	end
end

wire       floppy_step;
wire [7:0] wd_do;

wire floppy_ready;

fdc1772 #(.IMG_TYPE(1), .EXT_MOTOR(1), .FD_NUM(1)) fdc
(
	.clkcpu(clk),
	.clk8m_en(wd_ce),

	.floppy_drive(1'b0),
	.floppy_side(~side), 
	.floppy_reset(~reset),
	.floppy_step(floppy_step),
	.floppy_motor(~motor_n),
	.floppy_ready(floppy_ready),

	.cpu_addr(cpu_a[1:0]),
	.cpu_sel(wd_cs),
	.cpu_rw(cpu_rw | ~ph2_f),
	.cpu_din(cpu_do),
	.cpu_dout(wd_do),

	.img_wp(~wps_n),

	.img_mounted(img_mounted),
	.img_size(img_size),

	.sd_lba(sd_lba),
	.sd_rd(fdc_sd_rd),
	.sd_wr(fdc_sd_wr),
	.sd_ack(sd_ack),
	.sd_buff_addr(sd_buff_addr),
	.sd_dout(sd_buff_dout),
	.sd_din(sd_buff_din),
	.sd_dout_strobe(sd_buff_wr),

	.track_out(track),
	.we_out(we),

	.stop(stop),
	.ss_en(ss_en),
	.ss_si(ss_cia_so),
	.ss_so(ss_so),
	.ss_idle(fdc_idle),
	.ss_hold(ss_hold),
	.ss_addr(ss_rgn_addr[9:0]),
	.ss_wdata(ss_rgn_wdata),
	.ss_wr(ss_rgn_wr & ss_rgn_sel[1]),
	.ss_rgn_q(ss_fdc_q)
);

// Sector requests reach the host only while the drive runs: one raised on the
// last running clocks before a savestate waits in the chain until the release.
assign sd_rd = fdc_sd_rd & ~stop;
assign sd_wr = fdc_sd_wr & ~stop;

// Freeze boundary: CPU between instructions (or the unit held in reset), no
// sector request pending towards the host and none starting on the next clock.
assign ss_idle = (cpu_sync | reset) & fdc_idle;

// Region port (RAM, FDC_BUF): one byte per request, acknowledged after the
// 2-clock read latency of the RAM; writes land on port a meanwhile.
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
		ss_rgn_rdata <= ss_rgn_sel[0] ? ram_do : ss_fdc_q;
	end
end

endmodule
