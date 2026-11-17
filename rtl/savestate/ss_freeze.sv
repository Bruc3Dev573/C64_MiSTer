// Savestate freeze controller (WP A2): second freeze level on top of the
// user pause (docs/PAUSE.md).
//
// fpga64_sid_iec samples its pause input once per C64 cycle group, on the
// clk_sys edge where it also raises 'refresh' (preCycle = pred(CYCLE_EXT4),
// rfsh_cycle = 0), and stops the machine there (sysEnable low). While the
// engine asks for a freeze (req), that pause input is the AND of the idle
// signals of every block: the machine stops only on a sample where all of
// them are idle (C64 CPU between instructions, no reset pending, no REU DMA,
// no disk or download transfer, ...). Each block exposes only its idle
// signal. Once stopped on such a sample the freeze is held until req drops,
// then the pause input goes back to the user pause.
//
// If the machine was already stopped at an arbitrary point (user pause, the
// video realignment after one) it is let run again until the next boundary
// (a few cycles, HDMI keeps the frozen frame), starting on a sample where
// run_ok is high: c64.sv gives it on the sample after video_sync's resume_ok,
// when the free-running video output is on the position of the stopped VIC,
// so the output sync does not jump by the time the machine was stopped.
//
// Watchdog: no boundary within 2^WDOG_BITS clocks forces the freeze on the
// next sample. 'forced' tells the engine (a forced load proceeds, a forced
// save is abandoned) and 'block' keeps the idle bits that were low.

module ss_freeze #(parameter N = 9, parameter WDOG_BITS = 27)
(
	input              clk,
	input              req,         // savestate engine wants the machine frozen
	input              user_pause,  // existing freeze (user / OSD pause)
	input              run_ok,      // a stopped machine may run on this sample
	input              sample,      // fpga64 'refresh': pause was sampled on this edge
	input              c64_pause,   // fpga64 pause_out
	input      [N-1:0] idle,        // 1 = this block is at a boundary
	output             pause,       // to fpga64 .pause
	output reg         ack = 0,     // frozen for the engine
	output reg         forced = 0,  // ack came from the watchdog
	output reg [N-1:0] block = 0    // idle bits that were low when the watchdog fired
);

wire all_idle = &idle;

reg              hold = 0;
reg              fired = 0;
reg [WDOG_BITS:0] wd = 0;
reg              frz_d = 0, req_d = 0, idle_d = 0;

wire frz = hold | fired | all_idle;   // stop (stay stopped) for the engine on this sample
assign pause = req ? (frz | (c64_pause & ~run_ok)) : user_pause;

always @(posedge clk) begin
	frz_d  <= frz;
	req_d  <= req;
	idle_d <= all_idle;

	if (~req) begin
		hold  <= 0;
		fired <= 0;
		ack   <= 0;
		wd    <= 0;
	end
	else begin
		// 'sample' is high in the clock after the sampling edge: frz_d, req_d
		// and idle_d hold the values the machine saw on that edge (a machine
		// kept stopped only for run_ok is not at a boundary)
		if (sample & c64_pause & frz_d & req_d & ~ack) begin
			hold   <= 1;
			ack    <= 1;
			forced <= ~idle_d;
		end
		if (~ack & ~fired) begin
			wd <= wd + 1'd1;
			if (wd[WDOG_BITS]) begin
				fired <= 1;
				block <= idle;
			end
		end
	end
end

endmodule
