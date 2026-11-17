// DRIVES=0 sim variant: no 1541/1581 at all (IEC and parallel lines idle,
// no SD or DDRAM traffic). The drives are ~40% of the simulation time even
// when nothing is mounted, so scenarios that do not touch a disk use this.

module iec_drive #(parameter PARPORT=1,DUALROM=1,DRIVES=2)
(
	input         clk,
	input   [N:0] reset,
	input         ce,
	input         pause,
	input   [N:0] img_mounted,
	input         img_readonly,
	input  [31:0] img_size,
	input   [1:0] img_type,
	input   [2:0] drive_rpm,
	input         drive_wobble,
	output  [N:0] led,
	output wire [7:0] out_track[NDR],
	output wire [N:0] out_we,
	output        disk_ready,
	input         iec_atn_i,
	input         iec_data_i,
	input         iec_clk_i,
	output        iec_data_o,
	output        iec_clk_o,
	input         par_force,
	input   [7:0] par_data_i,
	input         par_stb_i,
	output  [7:0] par_data_o,
	output        par_stb_o,
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
	input  [15:0] rom_addr,
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
	input         ss_en,
	input         ss_hold,
	input         ss_load_done,
	input         ss_si,
	output        ss_so,
	output        ss_idle,
	output  [N:0] ss_1581,
	input [3*NDR-1:0] ss_rgn_sel,
	input [2*NDR-1:0] ss_rgn_sel81,
	input  [12:0] ss_rgn_addr,
	input         ss_rgn_req,
	input         ss_rgn_we,
	input   [7:0] ss_rgn_wdata,
	output  [7:0] ss_rgn_rdata,
	output reg    ss_rgn_ack
);

localparam NDR = (DRIVES < 1) ? 1 : (DRIVES > 4) ? 4 : DRIVES;
localparam N   = NDR - 1;

`include "rtl/savestate/c64_savestates.vh"

// The chain keeps the length of the drive segments (the engine shifts the live
// total); the drive regions read as 0 and writes to them are dropped.
localparam SSW = `SS_DRV8_1541_BITS + `SS_DRV9_1541_BITS + `SS_DRV8_1581_BITS + `SS_DRV9_1581_BITS;
reg [SSW-1:0] ss_sr;
always @(posedge clk_sys) if (ss_en) ss_sr <= {ss_si, ss_sr[SSW-1:1]};
assign ss_so   = ss_sr[0];
assign ss_idle = 1'b1;
assign ss_1581 = '0;
assign ss_rgn_rdata = 8'h00;
always @(posedge clk_sys) ss_rgn_ack <= ss_rgn_req & (|ss_rgn_sel | |ss_rgn_sel81);

assign led        = '0;
assign out_we     = '0;
assign disk_ready = 1'b1;
assign iec_data_o = 1'b1;
assign iec_clk_o  = 1'b1;
assign par_data_o = 8'hFF;
assign par_stb_o  = 1'b1;
assign sd_rd      = '0;
assign sd_wr      = '0;
assign DDRAM_BURSTCNT = 8'd0;
assign DDRAM_ADDR = 29'd0;
assign DDRAM_RD   = 1'b0;
assign DDRAM_WE   = 1'b0;
assign DDRAM_DIN  = 64'd0;
assign DDRAM_BE   = 8'd0;

genvar i;
generate for (i = 0; i < NDR; i = i + 1) begin : d
	assign out_track[i]   = 8'd0;
	assign sd_lba[i]      = 32'd0;
	assign sd_blk_cnt[i]  = 6'd0;
	assign sd_buff_din[i] = 8'd0;
end endgenerate

endmodule
