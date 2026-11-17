// Simulation replacements for sys/video_mixer.sv and sys/video_freak.sv.
//
// video_mixer: no scandoubler/gamma, the core's pixels go straight to VGA_*
// on ce_pix. The freeze engine is the real sys/video_freezer.sv, so
// freeze_sync keeps toggling once per frame while HDMI_FREEZE holds the
// machine (the core only changes freeze on a freeze_sync edge).

module video_mixer
#(
	parameter LINE_LENGTH  = 768,
	parameter HALF_DEPTH   = 0,
	parameter GAMMA        = 0
)
(
	input            CLK_VIDEO,
	output reg       CE_PIXEL,
	input            ce_pix,
	input            scandoubler,
	input            hq2x,
	inout     [21:0] gamma_bus,
	input      [7:0] R,
	input      [7:0] G,
	input      [7:0] B,
	input            HSync,
	input            VSync,
	input            HBlank,
	input            VBlank,
	input            HDMI_FREEZE,
	output           freeze_sync,
	output reg [7:0] VGA_R,
	output reg [7:0] VGA_G,
	output reg [7:0] VGA_B,
	output reg       VGA_VS,
	output reg       VGA_HS,
	output reg       VGA_DE
);

wire frz_hs, frz_vs, frz_hbl, frz_vbl;
video_freezer freezer
(
	.clk(CLK_VIDEO),
	.freeze(HDMI_FREEZE),
	.hs_in(HSync),
	.vs_in(VSync),
	.hbl_in(HBlank),
	.vbl_in(VBlank),
	.sync(freeze_sync),
	.hs_out(frz_hs),
	.vs_out(frz_vs),
	.hbl_out(frz_hbl),
	.vbl_out(frz_vbl)
);

always @(posedge CLK_VIDEO) begin
	CE_PIXEL <= ce_pix;
	if (ce_pix) begin
		VGA_R  <= R;
		VGA_G  <= G;
		VGA_B  <= B;
		VGA_HS <= HSync;
		VGA_VS <= VSync;
		VGA_DE <= ~(HBlank | VBlank);
	end
end

endmodule

module video_freak
(
	input             CLK_VIDEO,
	input             CE_PIXEL,
	input             VGA_VS,
	input      [11:0] HDMI_WIDTH,
	input      [11:0] HDMI_HEIGHT,
	output            VGA_DE,
	output reg [12:0] VIDEO_ARX,
	output reg [12:0] VIDEO_ARY,
	input             VGA_DE_IN,
	input      [11:0] ARX,
	input      [11:0] ARY,
	input      [11:0] CROP_SIZE,
	input       [4:0] CROP_OFF,
	input       [2:0] SCALE
);

assign VGA_DE = VGA_DE_IN;
always @(posedge CLK_VIDEO) begin
	VIDEO_ARX <= {1'b0, ARX};
	VIDEO_ARY <= {1'b0, ARY};
end

endmodule
