// Behavioral models of the Altera megafunctions used by the core.

module scfifo #(
	parameter add_ram_output_register = "OFF",
	parameter intended_device_family  = "",
	parameter lpm_numwords            = 64,
	parameter lpm_showahead           = "OFF",
	parameter lpm_type                = "scfifo",
	parameter lpm_width               = 8,
	parameter lpm_widthu              = 6,
	parameter overflow_checking       = "ON",
	parameter underflow_checking      = "ON",
	parameter use_eab                 = "ON"
)(
	input                   aclr,
	input                   clock,
	input  [lpm_width-1:0]  data,
	input                   rdreq,
	input                   wrreq,
	output                  empty,
	output                  full,
	output [lpm_width-1:0]  q
);

reg [lpm_width-1:0]  mem [lpm_numwords];
reg [lpm_widthu:0]   wp = 0, rp = 0;
reg [lpm_width-1:0]  q_r = 0;

wire [lpm_widthu:0] used = wp - rp;
assign empty = (used == 0);
assign full  = (used == lpm_numwords);
assign q     = (lpm_showahead == "ON") ? mem[rp[lpm_widthu-1:0]] : q_r;

always @(posedge clock or posedge aclr) begin
	if (aclr) begin
		wp <= 0;
		rp <= 0;
	end else begin
		if (wrreq && !full) begin
			mem[wp[lpm_widthu-1:0]] <= data;
			wp <= wp + 1'd1;
		end
		if (rdreq && !empty) begin
			q_r <= mem[rp[lpm_widthu-1:0]];
			rp <= rp + 1'd1;
		end
	end
end

endmodule

// Dual-clock FIFO: destination-clock pointer visibility, independently in
// each direction. No metastability model; the harness selects 0, 2 or 3 stages.
module dcfifo #(
	parameter intended_device_family = "",
	parameter lpm_numwords           = 1024,
	parameter lpm_showahead          = "ON",
	parameter lpm_type               = "dcfifo",
	parameter lpm_width              = 10,
	parameter lpm_widthu             = 10,
	parameter overflow_checking      = "ON",
	parameter rdsync_delaypipe       = 5,
	parameter read_aclr_synch        = "ON",
	parameter underflow_checking     = "ON",
	parameter use_eab                = "ON",
	parameter write_aclr_synch       = "ON",
	parameter wrsync_delaypipe       = 5
)(
	input                   aclr,
	input  [lpm_width-1:0]  data,
	input                   rdclk,
	input                   rdreq,
	input                   wrclk,
	input                   wrreq,
	output [lpm_width-1:0]  q,
	output                  rdempty,
	output                  eccstatus,
	output                  rdfull,
	output [lpm_widthu-1:0] rdusedw,
	output                  wrempty,
	output                  wrfull,
	output [lpm_widthu-1:0] wrusedw
);

reg [lpm_width-1:0]  mem [1<<lpm_widthu];
reg [lpm_widthu:0]   wp = 0, rp = 0;
reg [lpm_width-1:0]  q_r = 0;

integer sim_sync_stages /*verilator public_flat_rw*/ = 3;
reg [lpm_widthu:0] wp_rd1 = 0, wp_rd2 = 0, wp_rd3 = 0;
reg [lpm_widthu:0] rp_wr1 = 0, rp_wr2 = 0, rp_wr3 = 0;
wire [lpm_widthu:0] rd_wp = sim_sync_stages == 0 ? wp : sim_sync_stages == 2 ? wp_rd2 : wp_rd3;
wire [lpm_widthu:0] wr_rp = sim_sync_stages == 0 ? rp : sim_sync_stages == 2 ? rp_wr2 : rp_wr3;
wire [lpm_widthu:0] rd_used = rd_wp - rp;
wire [lpm_widthu:0] wr_used = wp - wr_rp;
assign rdempty   = (rd_used == 0);
assign wrempty   = (wr_used == 0);
assign rdfull    = (rd_used == lpm_numwords);
assign wrfull    = (wr_used == lpm_numwords);
assign rdusedw   = rd_used[lpm_widthu-1:0];
assign wrusedw   = wr_used[lpm_widthu-1:0];
assign eccstatus = 1'b0;
assign q         = (lpm_showahead == "ON") ? mem[rp[lpm_widthu-1:0]] : q_r;

always @(posedge rdclk or posedge aclr) begin
	if (aclr) begin wp_rd1 <= 0; wp_rd2 <= 0; wp_rd3 <= 0; end
	else begin wp_rd1 <= wp; wp_rd2 <= wp_rd1; wp_rd3 <= wp_rd2; end
end

always @(posedge wrclk or posedge aclr) begin
	if (aclr) begin rp_wr1 <= 0; rp_wr2 <= 0; rp_wr3 <= 0; end
	else begin rp_wr1 <= rp; rp_wr2 <= rp_wr1; rp_wr3 <= rp_wr2; end
end

always @(posedge wrclk or posedge aclr) begin
	if (aclr) wp <= 0;
	else if (wrreq && !wrfull) begin
		mem[wp[lpm_widthu-1:0]] <= data;
		wp <= wp + 1'd1;
	end
end

always @(posedge rdclk or posedge aclr) begin
	if (aclr) rp <= 0;
	else if (rdreq && !rdempty) begin
		q_r <= mem[rp[lpm_widthu-1:0]];
		rp <= rp + 1'd1;
	end
end

endmodule
