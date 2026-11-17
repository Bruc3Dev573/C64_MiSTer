//-------------------------------------------------------------------------------
//
// Reworked and adapted to MiSTer by Sorgelig@MiSTer (07.09.2018)
//
//-------------------------------------------------------------------------------

//
// Model 1541B
//
module c1541_logic
(
	input        clk,
	input        reset,

	input        ce,
	input        ph2_r,
	input        ph2_f,

	// serial bus
	input        iec_clk_in,
	input        iec_data_in,
	input        iec_atn_in,
	output       iec_clk_out,
	output       iec_data_out,

	input        ext_en,
	output[14:0] rom_addr,
	input  [7:0] rom_data,

	// parallel bus
	input  [7:0] par_data_in,
	input        par_stb_in,
	output [7:0] par_data_out,
	output       par_stb_out,
	
	// drive-side interface
	input  [1:0] ds,			   // device select
	input  [7:0] din,			   // disk read data
	output [7:0] dout,		   // disk write data
	output       mode,		   // read/write
	output [1:0] stp,			   // stepper motor control
	output       mtr,			   // stepper motor on/off
	output [1:0] freq,		   // motor frequency
	input        sync_n,		   // reading SYNC bytes
	input        byte_n,		   // byte ready
	input        wps_n,		   // write-protect sense
	input        tr00_sense_n,	// track 0 sense
	output       act,			   // activity LED

	// savestate (WP A8): chain T65 -> VIA1 (UC1) -> VIA2 (UC3) (bit 0 out
	// first: VIA2), RAM regions on port a while the engine owns the machine
	input        stop,          // drive stopped with the machine
	input        ss_en,
	input        ss_hold,
	input        ss_si,
	output       ss_so,
	output       cpu_sync,      // drive CPU between instructions
	input [12:0] ss_addr,
	input  [7:0] ss_wdata,
	input        ss_wr_ram,
	input        ss_wr_extram,
	output [7:0] ss_ram_q,
	output [7:0] ss_extram_q
);

assign rom_addr = cpu_a[14:0];

//same decoder as on real HW
wire [3:0] ls42 = {cpu_a[15],cpu_a[12:10]};
wire ram_cs     = ls42 == 0 || ls42 == 1;
wire uc1_cs     = ls42 == 6;
wire uc3_cs     = ls42 == 7;
wire rom_cs     = cpu_a[15];

wire  [7:0] cpu_di =
	!cpu_rw    ? cpu_do :
	 ram_cs    ? ram_do :
	 uc1_cs    ? uc1_do :
	 uc3_cs    ? uc3_do :
	 extram_cs ? extram_do :
	 rom_cs    ? rom_data :
	 8'hFF;

wire [23:0] cpu_a;
wire  [7:0] cpu_do;
wire        cpu_rw;
wire        cpu_irq_n = ~(uc1_irq | uc3_irq);
wire        cpu_so_n = byte_n | ~soe;

wire ss_cpu_so, ss_uc1_so;

T65 cpu
(
	.mode(2'b00),
	.res_n(~reset),
	.enable(ph2_f & ~stop),   // T65 SS_Hold freezes only its SO sampler: a ph2_f held while stopped, or a chain bit passing through it, must not step the CPU
	.clk(clk),
	.rdy(1'b1),
	.abort_n(1'b1),
	.irq_n(cpu_irq_n),
	.nmi_n(1'b1),
	.so_n(cpu_so_n),
	.r_w_n(cpu_rw),
	.sync(cpu_sync),
	.A(cpu_a),
	.DI(cpu_di),
	.DO(cpu_do),

	.SS_En(ss_en),
	.SS_Hold(stop),
	.SS_SI(ss_si),
	.SS_SO(ss_cpu_so)
);

wire extram_cs = ext_en && (cpu_a[15:13] == 'b100);

wire [7:0] extram_do;
iecdrv_mem #(8,13) extram
(
	.clock_a(clk),
	.address_a(ss_hold ? ss_addr : cpu_a[12:0]),
	.data_a(ss_hold ? ss_wdata : cpu_do),
	.wren_a(ss_hold ? ss_wr_extram : (ph2_r & ~stop & ~cpu_rw & extram_cs)),
	.q_a(ss_extram_q),

	.clock_b(clk),
	.address_b(cpu_a[12:0]),
	.q_b(extram_do)
);

wire [7:0] ram_do;
iecdrv_mem #(8,11) ram
(
	.clock_a(clk),
	.address_a(ss_hold ? ss_addr[10:0] : cpu_a[10:0]),
	.data_a(ss_hold ? ss_wdata : cpu_do),
	.wren_a(ss_hold ? ss_wr_ram : (ph2_r & ~stop & ~cpu_rw & ram_cs)),
	.q_a(ss_ram_q),

	.clock_b(clk),
	.address_b(cpu_a[10:0]),
	.q_b(ram_do)
);

// UC1 (VIA6522) signals
wire [7:0] uc1_do;
wire       uc1_irq;
wire [7:0] uc1_pa_o;
wire [7:0] uc1_pa_oe;
wire       uc1_ca2_o;
wire       uc1_ca2_oe;
wire [7:0] uc1_pb_o;
wire [7:0] uc1_pb_oe;
wire       uc1_cb1_o;
wire       uc1_cb1_oe;
wire       uc1_cb2_o;
wire       uc1_cb2_oe;

assign     iec_data_out = ~(uc1_pb_o[1] | ~uc1_pb_oe[1]) & ~((uc1_pb_o[4] | ~uc1_pb_oe[4]) ^ ~iec_atn_in);
assign     iec_clk_out  = ~(uc1_pb_o[3] | ~uc1_pb_oe[3]);

assign     par_stb_out  = uc1_ca2_o | ~uc1_ca2_oe;
assign     par_data_out = uc1_pa_o  | ~uc1_pa_oe;

iecdrv_via6522 uc1
(
	.clock(clk),
	.rising(ph2_r),
	.falling(ph2_f),
	.reset(reset),

	.addr(cpu_a[3:0]),
	.wen(~cpu_rw & uc1_cs),
	.ren(cpu_rw & uc1_cs),
	.data_in(cpu_do),
	.data_out(uc1_do),

	.port_a_o(uc1_pa_o),
	.port_a_t(uc1_pa_oe),
	.port_a_i((ext_en ? par_data_in : {7'h7F,tr00_sense_n}) & (uc1_pa_o  | ~uc1_pa_oe)),

	.port_b_o(uc1_pb_o),
	.port_b_t(uc1_pb_oe),
	.port_b_i({~iec_atn_in, ds, 2'b11, ~iec_clk_in, 1'b1, ~iec_data_in} & (uc1_pb_o | ~uc1_pb_oe)),

	.ca1_i(~iec_atn_in),

	.ca2_o(uc1_ca2_o),
	.ca2_t(uc1_ca2_oe),
	.ca2_i(uc1_ca2_o | ~uc1_ca2_oe),

	.cb1_o(uc1_cb1_o),
	.cb1_t(uc1_cb1_oe),
	.cb1_i((ext_en ? par_stb_in : 1'b1) & (uc1_cb1_o | ~uc1_cb1_oe)),

	.cb2_o(uc1_cb2_o),
	.cb2_t(uc1_cb2_oe),
	.cb2_i(uc1_cb2_o | ~uc1_cb2_oe),

	.irq(uc1_irq),

	.ss_en(ss_en),
	.ss_stop(stop),
	.ss_si(ss_cpu_so),
	.ss_so(ss_uc1_so)
);


// UC3 (VIA6522) signals
wire [7:0] uc3_do;
wire       uc3_irq;
wire [7:0] uc3_pa_o;
wire [7:0] uc3_pa_oe;
wire       uc3_ca2_o;
wire       uc3_ca2_oe;
wire [7:0] uc3_pb_o;
wire [7:0] uc3_pb_oe;
wire       uc3_cb1_o;
wire       uc3_cb1_oe;
wire       uc3_cb2_o;
wire       uc3_cb2_oe;

wire       soe  = uc3_ca2_o | ~uc3_ca2_oe;
assign     dout = uc3_pa_o  | ~uc3_pa_oe;
assign     mode = uc3_cb2_o | ~uc3_cb2_oe;

assign     stp  = uc3_pb_o[1:0] | ~uc3_pb_oe[1:0];
assign     mtr  = uc3_pb_o[2]   | ~uc3_pb_oe[2];
assign     act  = uc3_pb_o[3]   | ~uc3_pb_oe[3];
assign     freq = uc3_pb_o[6:5] | ~uc3_pb_oe[6:5];


iecdrv_via6522 uc3
(
	.clock(clk),
	.rising(ph2_r),
	.falling(ph2_f),
	.reset(reset),

	.addr(cpu_a[3:0]),
	.wen(~cpu_rw & uc3_cs),
	.ren(cpu_rw & uc3_cs),
	.data_in(cpu_do),
	.data_out(uc3_do),

	.port_a_o(uc3_pa_o),
	.port_a_t(uc3_pa_oe),
	.port_a_i(din & (uc3_pa_o | ~uc3_pa_oe)),

	.port_b_o(uc3_pb_o),
	.port_b_t(uc3_pb_oe),
	.port_b_i({sync_n, 2'b11, wps_n, 4'b1111} & (uc3_pb_o | ~uc3_pb_oe)),

	.ca1_i(cpu_so_n),

	.ca2_o(uc3_ca2_o),
	.ca2_t(uc3_ca2_oe),
	.ca2_i(uc3_ca2_o | ~uc3_ca2_oe),

	.cb1_o(uc3_cb1_o),
	.cb1_t(uc3_cb1_oe),
	.cb1_i(uc3_cb1_o | ~uc3_cb1_oe),

	.cb2_o(uc3_cb2_o),
	.cb2_t(uc3_cb2_oe),
	.cb2_i(uc3_cb2_o | ~uc3_cb2_oe),

	.irq(uc3_irq),

	.ss_en(ss_en),
	.ss_stop(stop),
	.ss_si(ss_uc1_so),
	.ss_so(ss_so)
);

endmodule
