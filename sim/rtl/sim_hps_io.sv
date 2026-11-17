// Simulation replacement of sys/hps_io.sv.
//
// Same module name and the ports c64.sv uses. Instead of decoding HPS_BUS,
// every output is a public register written by the C++ harness (tb/c64_tb.cpp)
// between clock edges: status, joysticks, ps2_key strobes, ioctl downloads.
// SD block requests are acknowledged by the harness too (sd_ack/sd_buff_*).

module hps_io #(parameter CONF_STR, CONF_STR_BRAM=0, PS2DIV=0, WIDE=0, VDNUM=1, BLKSZ=2, PS2WE=0, STRLEN=$size(CONF_STR)>>3, F12KEYMOD=0)
(
	input             clk_sys,
	inout      [45:0] HPS_BUS,

	output     [31:0] joystick_0,
	output     [31:0] joystick_1,
	output     [31:0] joystick_2,
	output     [31:0] joystick_3,

	output      [7:0] paddle_0,
	output      [7:0] paddle_1,
	output      [7:0] paddle_2,
	output      [7:0] paddle_3,

	output     [10:0] ps2_key,
	output     [24:0] ps2_mouse,

	output      [1:0] buttons,
	output            forced_scandoubler,
	inout      [21:0] gamma_bus,

	output    [127:0] status,
	input     [127:0] status_in,
	input             status_set,
	input      [15:0] status_menumask,
	input             info_req,
	input       [7:0] info,

	output   [VD:0]   img_mounted,
	output            img_readonly,
	output     [63:0] img_size,

	input      [31:0] sd_lba[VDNUM],
	input       [5:0] sd_blk_cnt[VDNUM],
	input    [VD:0]   sd_rd,
	input    [VD:0]   sd_wr,
	output   [VD:0]   sd_ack,
	output   [AW:0]   sd_buff_addr,
	output   [DW:0]   sd_buff_dout,
	input    [DW:0]   sd_buff_din[VDNUM],
	output            sd_buff_wr,

	output            ioctl_download,
	output     [15:0] ioctl_index,
	output            ioctl_wr,
	output     [26:0] ioctl_addr,
	output   [DW:0]   ioctl_dout,
	output            ioctl_upload,
	input             ioctl_upload_req,
	input       [7:0] ioctl_upload_index,
	input    [DW:0]   ioctl_din,
	output            ioctl_rd,
	output     [31:0] ioctl_file_ext,
	input             ioctl_wait,

	output     [64:0] RTC
);

localparam DW = (WIDE) ? 15 : 7;
localparam AW = (WIDE) ? 12 : 13;
localparam VD = VDNUM-1;

// ---- harness controlled state ----
reg  [31:0] h_joy0      /*verilator public_flat_rw*/ = 0;
reg  [31:0] h_joy1      /*verilator public_flat_rw*/ = 0;
reg  [31:0] h_joy2      /*verilator public_flat_rw*/ = 0;
reg  [31:0] h_joy3      /*verilator public_flat_rw*/ = 0;
reg   [7:0] h_paddle0   /*verilator public_flat_rw*/ = 0;
reg   [7:0] h_paddle1   /*verilator public_flat_rw*/ = 0;
reg   [7:0] h_paddle2   /*verilator public_flat_rw*/ = 0;
reg   [7:0] h_paddle3   /*verilator public_flat_rw*/ = 0;
reg  [10:0] h_ps2_key   /*verilator public_flat_rw*/ = 0;
reg  [24:0] h_ps2_mouse /*verilator public_flat_rw*/ = 0;
reg   [1:0] h_buttons   /*verilator public_flat_rw*/ = 0;
reg [127:0] h_status    /*verilator public_flat_rw*/ = 0;

reg   [1:0] h_img_mounted  /*verilator public_flat_rw*/ = 0;
reg         h_img_readonly /*verilator public_flat_rw*/ = 0;
reg  [63:0] h_img_size     /*verilator public_flat_rw*/ = 0;
reg   [1:0] h_sd_ack       /*verilator public_flat_rw*/ = 0;
reg  [13:0] h_sd_buff_addr /*verilator public_flat_rw*/ = 0;
reg   [7:0] h_sd_buff_dout /*verilator public_flat_rw*/ = 0;
reg         h_sd_buff_wr   /*verilator public_flat_rw*/ = 0;

reg         h_ioctl_download /*verilator public_flat_rw*/ = 0;
reg  [15:0] h_ioctl_index    /*verilator public_flat_rw*/ = 0;
reg         h_ioctl_wr       /*verilator public_flat_rw*/ = 0;
reg  [26:0] h_ioctl_addr     /*verilator public_flat_rw*/ = 0;
reg   [7:0] h_ioctl_dout     /*verilator public_flat_rw*/ = 0;
reg  [31:0] h_ioctl_file_ext /*verilator public_flat_rw*/ = 0;

// status_set writes status_in back (Main stores it, e.g. the savestate slot);
// the last info message requested by the core is kept for the harness
reg   [7:0] o_info     /*verilator public_flat_rd*/ = 0;
reg  [31:0] o_info_cnt /*verilator public_flat_rd*/ = 0;
always @(posedge clk_sys) begin
	if (status_set) h_status <= status_in;
	if (info_req) begin
		o_info     <= info;
		o_info_cnt <= o_info_cnt + 1'd1;
	end
end

// ---- observation points for the harness ----
wire        o_ioctl_wait /*verilator public_flat_rd*/ = ioctl_wait;
wire  [1:0] o_sd_rd      /*verilator public_flat_rd*/ = sd_rd;
wire  [1:0] o_sd_wr      /*verilator public_flat_rd*/ = sd_wr;
wire [31:0] o_sd_lba0    /*verilator public_flat_rd*/ = sd_lba[0];
wire [31:0] o_sd_lba1    /*verilator public_flat_rd*/ = sd_lba[VD];
wire  [5:0] o_sd_blk_cnt0 /*verilator public_flat_rd*/ = sd_blk_cnt[0];
wire  [5:0] o_sd_blk_cnt1 /*verilator public_flat_rd*/ = sd_blk_cnt[VD];
wire [DW:0] o_sd_buff_din0 /*verilator public_flat_rd*/ = sd_buff_din[0];
wire [DW:0] o_sd_buff_din1 /*verilator public_flat_rd*/ = sd_buff_din[VD];

assign joystick_0 = h_joy0;
assign joystick_1 = h_joy1;
assign joystick_2 = h_joy2;
assign joystick_3 = h_joy3;
assign paddle_0   = h_paddle0;
assign paddle_1   = h_paddle1;
assign paddle_2   = h_paddle2;
assign paddle_3   = h_paddle3;
assign ps2_key    = h_ps2_key;
assign ps2_mouse  = h_ps2_mouse;
assign buttons    = h_buttons;
assign forced_scandoubler = 1'b0;
assign status     = h_status;

assign img_mounted  = h_img_mounted[VD:0];
assign img_readonly = h_img_readonly;
assign img_size     = h_img_size;
assign sd_ack       = h_sd_ack[VD:0];
assign sd_buff_addr = h_sd_buff_addr[AW:0];
assign sd_buff_dout = h_sd_buff_dout;
assign sd_buff_wr   = h_sd_buff_wr;

assign ioctl_download = h_ioctl_download;
assign ioctl_index    = h_ioctl_index;
assign ioctl_wr       = h_ioctl_wr;
assign ioctl_addr     = h_ioctl_addr;
assign ioctl_dout     = h_ioctl_dout;
assign ioctl_upload   = 1'b0;
assign ioctl_rd       = 1'b0;
assign ioctl_file_ext = h_ioctl_file_ext;

// Fixed date: 2026-11-01 12:00:00, Sunday (BCD, same layout as hps_io).
assign RTC = {1'b0, 8'h00, 8'h26, 8'h11, 8'h01, 8'h12, 8'h00, 8'h00, 8'h00};

endmodule
