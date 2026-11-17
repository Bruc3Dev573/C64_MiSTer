//-------------------------------------------------------------------------------
//
// C1541 multi-drive implementation with shared ROM
// (C) 2021 Alexey Melnikov
//
// Input clock/ce 16MHz
//
//-------------------------------------------------------------------------------


module c1581_multi #(parameter PARPORT=1,DUALROM=1,DRIVES=2)
(
	//clk ports
	input         clk,
	input   [N:0] reset,
	input         ce,

	input         pause,

	input   [N:0] img_mounted,
	input         img_readonly,
	input  [31:0] img_size,

	output  [N:0] act_led,
	output  [N:0] pwr_led,
	// OSD
	output wire [7:0] out_track[NDR],
	output wire [N:0] out_we,

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

	//clk_sys ports
	input         clk_sys,

	output [31:0] sd_lba[NDR],
	output  [N:0] sd_rd,
	output  [N:0] sd_wr,
	input   [N:0] sd_ack,
	input   [8:0] sd_buff_addr,
	input   [7:0] sd_buff_dout,
	output  [7:0] sd_buff_din[NDR],
	input         sd_buff_wr,

	input  [14:0] rom_addr,
	input   [7:0] rom_data,
	input         rom_wr,
	input         rom_std,

	// savestate (WP A10, docs/SAVESTATES.md): chain ss_si -> unit 9 (DRV9_1581)
	// -> glue -> unit 8 -> ss_so (glue + unit 8 = DRV8_1581), regions of the
	// units through the byte port, freeze boundary of the units
	input         ss_en,
	input         ss_hold,
	input         ss_load_done,
	input         ss_si,
	output        ss_so,
	output        ss_idle,
	input [2*NDR-1:0] ss_rgn_sel,   // unit i: bits [2*i +: 2] = {FDC_BUF, RAM}
	input  [12:0] ss_rgn_addr,
	input         ss_rgn_req,
	input         ss_rgn_we,
	input   [7:0] ss_rgn_wdata,
	output reg [7:0] ss_rgn_rdata,
	output        ss_rgn_ack
);

localparam NDR = (DRIVES < 1) ? 1 : (DRIVES > 4) ? 4 : DRIVES;
localparam N   = NDR - 1;

// The drives stop on the same clocks as the C64, as the 1541 (c1541_multi):
// the every-clock logic holds on pause delayed by one clock (stop); the ph2
// and 8 MHz pulses made from the last drive_ce wait in their registers (on the
// chain) until the drives run again.
reg  [1:0] stop_r = 0;
always @(posedge clk) stop_r <= {stop_r[0], pause};
wire stop = stop_r[0];

// The engine takes the RAM ports of the units, the outputs hold and the reset
// is released (hold) from the second stopped clock on: iecdrv_mem writes the
// data one clock after the address, so a CPU write of the last running clock
// lands before the port is the engine's.
wire hold = ss_hold & &stop_r;

// drive reset: follows the host/OSD level and the drive type, released while
// the engine owns the machine (the T65 reset is asynchronous)
wire [N:0] reset_drv;
iecdrv_sync #(NDR) rst_sync(clk, reset, reset_drv);
wire [N:0] reset_unit = reset_drv & ~{NDR{hold}};

wire stdrom = (DUALROM || PARPORT) ? rom_std : 1'b1;

// chain: ss_c[i+1] -> unit i -> ss_c[i] for the units above 0, then
// ss_c[1] -> glue -> unit 0 -> ss_c[0]
wire [NDR:0] ss_c;
assign ss_c[NDR] = ss_si;
assign ss_so     = ss_c[0];

// glue part of DRV8_1581, bit 0 leaves first: div, the ATN, DATA, CLK and FCLK
// synchronizers ({s1, s2, out} each), then ph2_r, ph2_f, wd_ce
reg       ph2_r, ph2_f, wd_ce;
reg [2:0] div;
reg [2:0] atn_s, dat_s, clk_s, fclk_s;
wire      iec_atn = atn_s[2], iec_data = dat_s[2], iec_clk = clk_s[2], iec_fclk = fclk_s[2];

wire [17:0] ss_q = {wd_ce, ph2_f, ph2_r, fclk_s, clk_s, dat_s, atn_s, div};
wire [17:0] ss_d = {ss_c[1], ss_q[17:1]};
wire        ss_glue_so = ss_q[0];

always @(posedge clk) begin
	if (ss_en) {wd_ce, ph2_f, ph2_r, fclk_s, clk_s, dat_s, atn_s, div} <= ss_d;
	else if (~stop) begin
		ph2_r <= 0;
		ph2_f <= 0;
		wd_ce <= 0;
		if(ce) begin
			div <= div + 1'd1;
			ph2_r <= !div[2] && !div[1:0];
			ph2_f <=  div[2] && !div[1:0];
			wd_ce <= !div[0];
		end

		atn_s  <= {(atn_s[1]  == atn_s[0])  ? atn_s[1]  : atn_s[2],  atn_s[0],  iec_atn_i};
		dat_s  <= {(dat_s[1]  == dat_s[0])  ? dat_s[1]  : dat_s[2],  dat_s[0],  iec_data_i};
		clk_s  <= {(clk_s[1]  == clk_s[0])  ? clk_s[1]  : clk_s[2],  clk_s[0],  iec_clk_i};
		fclk_s <= {(fclk_s[1] == fclk_s[0]) ? fclk_s[1] : fclk_s[2], fclk_s[0], iec_fclk_i};
	end
end

// Mounts reach the units as a 4-clock pulse made from the host strobe edge,
// with the image size and write protect latched there. A mount writes a chain
// register of the unit (disk change line), so the pulse waits while the
// engine owns the machine.
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

wire [7:0] rom_do;
generate
	if(PARPORT || DUALROM) begin
		iecdrv_mem #(8,15,"rtl/iec_drive/c1581_rom.mif") rom
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
	else begin
		assign rom_do = romstd_do;
	end
endgenerate

wire [7:0] romstd_do;
iecdrv_mem #(8,15,"rtl/iec_drive/c1581_rom.mif") romstd
(
	.clock_a(clk_sys),
	.address_a(rom_addr),
	.data_a(rom_data),
	.wren_a((DUALROM || PARPORT) ? 1'b0 : rom_wr),

	.clock_b(clk),
	.address_b(mem_a),
	.q_b(romstd_do)
);

// ROM bytes at the CPU addresses of the units: a fetch starts on ph2_f and
// needs 7 of the 8 clocks before the CPUs read it on ph2_r. While the drives
// are stopped it repeats, so whenever they run again (a stop is a whole C64
// cycle or more, and a load ends long after the chain moved) the bytes are
// those of the held addresses. Not on the chain: rebuilt from the CPUs.
reg  [14:0] mem_a;
wire [14:0] drv_addr[NDR];
reg   [7:0] drv_data[4];
reg   [2:0] state;
always @(posedge clk) begin
	if(~&state) state <= state + 1'd1;
	else if(stop) state <= 0;
	if(ph2_f & ~stop) state <= 0;

	case(state)
		0,1,2,3: mem_a <= drv_addr[state[1:0]];
	endcase
	
	case(state)
		3,4,5,6: drv_data[state[1:0] - 2'd3] <= stdrom ? romstd_do : rom_do;
	endcase
end

wire [N:0] iec_data_d, iec_clk_d, iec_fclk_d;
wire       iec_clk_l  = &{iec_clk_d  | reset_drv};
wire       iec_fclk_l = &{iec_fclk_d | reset_drv};
wire       iec_data_l = &{iec_data_d | reset_drv};

wire [7:0] par_data_d[NDR];
wire [N:0] par_stb_d;
wire       par_stb_l = &{par_stb_d | reset_drv};
reg  [7:0] par_data_l;
always_comb begin
	par_data_l = 8'hFF;
	for(int i=0; i<NDR; i=i+1) if(~reset_drv[i]) par_data_l = par_data_l & par_data_d[i];
end

wire [N:0] act_led_drv, pwr_led_drv;

// The outputs to the C64, the external IEC port and the LEDs keep their value
// while the engine owns the machine: the registers behind them move through
// the chain then. A load shows the loaded outputs from ss_load_done on.
wire [2*N+13:0] out_l = {act_led_drv & ~reset_drv, pwr_led_drv & ~reset_drv, par_data_l, par_stb_l, iec_fclk_l, iec_data_l, iec_clk_l};
reg  [2*N+13:0] out_h;
always @(posedge clk) if (~hold | ss_load_done) out_h <= out_l;
assign {act_led, pwr_led, par_data_o, par_stb_o, iec_fclk_o, iec_data_o, iec_clk_o} = hold ? out_h : out_l;

wire [7:0] track_drv[NDR];
wire       we_drv[NDR];

always_comb for(int j=0; j<NDR; j=j+1) begin
	out_track[j] = track_drv[j] << 1;
	out_we[j]    = we_drv[j];
end

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
		c1581_drv c1581_drv
		(
			.clk(clk),
			.reset(reset_unit[i]),

			.ce(ce),
			.wd_ce(wd_ce),
			.ph2_r(ph2_r),
			.ph2_f(ph2_f),

			.img_mounted(mnt_pulse[i]),
			.img_readonly(mnt_ro),
			.img_size(mnt_size),

			.drive_num(i),
			.act_led(act_led_drv[i]),
			.pwr_led(pwr_led_drv[i]),
			.track(track_drv[i]),
			.we(we_drv[i]),

			.iec_atn_i(iec_atn),
			.iec_data_i(iec_data & iec_data_o),
			.iec_clk_i(iec_clk & iec_clk_o),
			.iec_fclk_i(iec_fclk & iec_fclk_o),
			.iec_data_o(iec_data_d[i]),
			.iec_clk_o(iec_clk_d[i]),
			.iec_fclk_o(iec_fclk_d[i]),

			.par_data_i(par_data_i),
			.par_stb_i(par_stb_i),
			.par_data_o(par_data_d[i]),
			.par_stb_o(par_stb_d[i]),

			.rom_addr(drv_addr[i]),
			.rom_data(drv_data[i]),

			.clk_sys(clk_sys),

			.sd_lba(sd_lba[i]),
			.sd_rd(sd_rd[i]),
			.sd_wr(sd_wr[i]),
			.sd_ack(sd_ack[i]),
			.sd_buff_addr(sd_buff_addr),
			.sd_buff_dout(sd_buff_dout),
			.sd_buff_din(sd_buff_din[i]),
			.sd_buff_wr(sd_buff_wr),

			.stop(stop),
			.ss_en(ss_en),
			.ss_hold(hold),
			.ss_si(i ? ss_c[i+1] : ss_glue_so),
			.ss_so(ss_c[i]),
			.ss_idle(u_idle[i]),
			.ss_rgn_sel(ss_rgn_sel[2*i +: 2]),
			.ss_rgn_addr(ss_rgn_addr),
			.ss_rgn_req(ss_rgn_req),
			.ss_rgn_we(ss_rgn_we),
			.ss_rgn_wdata(ss_rgn_wdata),
			.ss_rgn_rdata(u_rdata[i]),
			.ss_rgn_ack(u_ack[i])
		);
	end
endgenerate

endmodule
