// Pause frame buffer for the analog output.
//
// While the C64 runs, the VIC color index of every visible dot is written
// into a frame-sized buffer (4 bits per dot, 382x270 PAL / 404x250 NTSC).
// While the machine is stopped, video_sync keeps the dot/line counters
// running and this module plays the buffer back on the same dots, so the
// analog output (and the scaler) keep a picture and a regular sync. The dots
// after the stop point hold the previous frame, the ones before it the
// current one: exactly what the screen showed, and where the VIC continues
// on resume.
//
// Timing (clk = clk_sys, one dot = 4 clocks): video_sync updates hblank and
// vblank with 'tick'; the VIC changes its color index on the edge that ends
// the cycle after 'tick' (ph 1). The playback index changes on that same edge,
// so the downstream pixel sampling sees the same dots as with the live VIC.
module pause_fb #(parameter DEPTH = 382*270)
(
	input            clk,
	input            tick,
	input            hblank,
	input            vblank,
	input            paused,
	input      [3:0] idx_in,
	output     [3:0] idx_out
);

reg  [3:0] mem[0:DEPTH-1];
reg [16:0] cnt = 0, wa = 0;
reg  [3:0] rd = 0, pb = 0;
reg  [1:0] ph = 0;
reg        vis_r = 0, wr_ok = 0;

always @(posedge clk) begin
	ph <= tick ? 2'd1 : ph + 2'd1;

	if (tick) begin
		rd    <= mem[cnt];
		wa    <= cnt;
		vis_r <= ~hblank & ~vblank & (cnt < DEPTH);
		if (vblank) cnt <= 0;
		else if (~hblank && cnt < DEPTH) cnt <= cnt + 1'd1;
	end

	// same edge as the VIC color index update
	if (ph == 2'd1) begin
		pb    <= vis_r ? rd : 4'd0;
		wr_ok <= ~paused;
	end

	if (ph == 2'd3 && vis_r && wr_ok) mem[wa] <= idx_in;
end

assign idx_out = paused ? pb : idx_in;

endmodule
