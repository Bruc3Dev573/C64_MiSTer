/*
 * Copyright (c) 2014, Aleksander Osman
 * All rights reserved.
 * 
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions are met:
 * 
 * * Redistributions of source code must retain the above copyright notice, this
 *   list of conditions and the following disclaimer.
 * 
 * * Redistributions in binary form must reproduce the above copyright notice,
 *   this list of conditions and the following disclaimer in the documentation
 *   and/or other materials provided with the distribution.
 * 
 * THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
 * AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
 * IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
 * DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE
 * FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
 * DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
 * SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
 * CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
 * OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
 * OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

module opl3
#(
	parameter     OPLCLK // opl_clk in Hz (minimum 45Mhz)
)
(
	input         clk,
	input         clk_opl,
	input         rst_n,
	input         pause,   // C64 paused: timers, Z80 firmware and sample sequencer hold
	output reg    irq_n,

	input   [1:0] addr,
	output  [7:0] dout,
	input   [7:0] din,
	input         we,

	output [15:0] sample_l,
	output [15:0] sample_r,

	// savestates: segment OPL3 (this module) and region OPL3_REGS (register shadow)
	input         ss_en,
	input         ss_hold,
	input         ss_load_done,
	input         ss_si,
	output        ss_so,
	output        ss_replay,     // register replay after a load: keep the machine frozen
	input         ss_rgn_sel,
	input         ss_rgn_req,
	input         ss_rgn_we,
	input   [7:0] ss_rgn_addr,
	input   [7:0] ss_rgn_wdata,
	output  [7:0] ss_rgn_rdata,
	output reg    ss_rgn_ack
);

//------------------------------------------------------------------------------

wire [7:0] io_readdata = { timer1_overflow | timer2_overflow, timer1_overflow, timer2_overflow, 5'd0 };
assign dout = !addr ? io_readdata : 8'hFF;

//------------------------------------------------------------------------------
// Segment OPL3: the C64 side of the chip, i.e. the index register, both timers
// and the status and IRQ they set. Bit 0 leaves first: index, old_write, timer1
// preset, mask, active, overflow, the same for timer2, irq_n, then the timer1
// and timer2 counters. Everything holds while the engine owns the machine; the
// reset is synchronous and yields to ss_hold (with the Sound Expander off it is
// held while the chain shifts).

reg       old_write;
reg [8:0] index;
reg [7:0] timer1_preset, timer2_preset;
reg       timer1_mask, timer1_active, timer1_overflow;
reg       timer2_mask, timer2_active, timer2_overflow;

wire [32:0] ss_q = {irq_n, timer2_overflow, timer2_active, timer2_mask, timer2_preset,
                    timer1_overflow, timer1_active, timer1_mask, timer1_preset, old_write, index};
wire        ss_t1_so, ss_t2_so;
assign ss_so = ss_q[0];

wire       write        = (~old_write & we);
wire       io_write     = (addr[0] && write);
wire [7:0] io_writedata = din;
wire       timer1_pulse, timer2_pulse;

always @(posedge clk) begin
	if (ss_en) {irq_n, timer2_overflow, timer2_active, timer2_mask, timer2_preset,
	             timer1_overflow, timer1_active, timer1_mask, timer1_preset, old_write, index} <= {ss_t1_so, ss_q[32:1]};
	else if (~ss_hold) begin
		old_write <= we;
		if (~rst_n) begin
			index <= 0;
			{timer1_preset, timer1_mask, timer1_active, timer1_overflow} <= 0;
			{timer2_preset, timer2_mask, timer2_active, timer2_overflow} <= 0;
			irq_n <= 1;
		end
		else begin
			if(~addr[0] && write) index <= {addr[1], din};
			if(io_write && index == 2) timer1_preset <= io_writedata;
			if(io_write && index == 3) timer2_preset <= io_writedata;
			if(io_write && index == 4 && ~io_writedata[7]) begin
				{timer1_mask, timer1_active} <= {io_writedata[6], io_writedata[0]};
				{timer2_mask, timer2_active} <= {io_writedata[5], io_writedata[1]};
			end
			if(io_write && index == 4 && io_writedata[7]) {timer1_overflow, timer2_overflow, irq_n} <= 3'b001;
			if(timer1_pulse) timer1_overflow <= 1;
			if(timer2_pulse) timer2_overflow <= 1;
			if((~timer1_mask && timer1_pulse) || (~timer2_mask && timer2_pulse)) irq_n <= 0;
		end
	end
end

timer #(OPLCLK) timer1( clk, ~pause, 12500, timer1_preset, timer1_active, timer1_pulse, ss_en, ss_hold, ss_t2_so, ss_t1_so );
timer #(OPLCLK) timer2( clk, ~pause,  3125, timer2_preset, timer2_active, timer2_pulse, ss_en, ss_hold, ss_si,    ss_t2_so );

//------------------------------------------------------------------------------
// Region OPL3_REGS and the replay. The FM part (opl3sw: Z80 firmware, its RAM,
// the register queue, the sample sequencer) is not saved and keeps running
// across a load. 'shadow' keeps the value of every register as the C64 wrote it
// (the region), 'fmreg' the value the FM part has or will take from its queue.
// Both follow the C64 writes, so they differ only after a load wrote the shadow:
// then every register that differs is queued as a C64 write (index, value), the
// sweep starting at $C0 and wrapping so the key-on registers $B0-$BD come after
// every operator setting, and the saved index goes last. Envelopes, phases and
// LFOs go on from the state before the load. A reset clears both (the firmware
// clears every register). addr[1] is 0 in this core: one register bank.

reg  [7:0] shadow[256], fmreg[256];
reg  [7:0] shadow_q, fmreg_q;
reg  [7:0] clr = 0;       // clears both while the chip is in reset, one whole pass
reg [10:0] rp  = 0;       // replay step, 0 = idle

wire [7:0] rp_reg = rp[9:2] + 8'hBF;               // 4 steps per register, $C0 at step 4
wire       rp_ix  = (rp == 11'd1028);              // the saved index, last
wire       rp_wr  = rp_ix | ((rp < 11'd1028) & (rp[1] ^ rp[0]) & (shadow_q != fmreg_q));
wire       rgn_wr = ss_rgn_sel & ss_rgn_req & ss_rgn_we;
wire       clr_on = ~rst_n | |clr;

assign ss_replay    = |rp;
assign ss_rgn_rdata = shadow_q;

always @(posedge clk) begin
	if (rgn_wr | clr_on | io_write)
		shadow[rgn_wr ? ss_rgn_addr : clr_on ? clr : index[7:0]] <= rgn_wr ? ss_rgn_wdata : clr_on ? 8'd0 : din;
	if (clr_on | io_write | (rp_wr & rp[1]))
		fmreg[clr_on ? clr : rp ? rp_reg : index[7:0]] <= clr_on ? 8'd0 : rp ? shadow_q : din;
	shadow_q   <= shadow[rp ? rp_reg : ss_rgn_addr];
	fmreg_q    <= fmreg[rp_reg];
	ss_rgn_ack <= ss_rgn_sel & ss_rgn_req;

	if (clr_on) clr <= clr + 1'd1;
	if (ss_load_done & rst_n) rp <= 11'd4;
	else if (rp) rp <= rp_ix ? 11'd0 : rp + 1'd1;
end

// replay: step 1 of a register queues its index, step 2 its value (both read from step 1)
opl3sw #(OPLCLK) opl3
(
    .reset(~rst_n),
    .pause(pause),

    .cpu_clk(clk),
    .addr(rp ? {1'b0, rp[1]} : addr),
    .din(rp ? (rp[1] ? shadow_q : rp_ix ? index[7:0] : rp_reg) : din),
    .wr(rp ? rp_wr : write),

    .clk(clk_opl),
    .left(sample_l),
    .right(sample_r)
);

endmodule

module timer #(parameter OPLCLK)
(
	input         clk,
	input         ce,
	input  [14:0] hz,
	input   [7:0] init,
	input         active,
	output reg    overflow_pulse,

	// savestate: {overflow_pulse, old_act, counter, sum}, bit 0 leaves first
	input         ss_en,
	input         ss_hold,
	input         ss_si,
	output        ss_so
);

reg  [31:0] sum;
reg   [7:0] counter = 0;
reg         old_act;
wire [31:0] next = sum + hz;

wire [41:0] ss_q = {overflow_pulse, old_act, counter, sum};
assign ss_so = ss_q[0];

always @(posedge clk) begin
	if (ss_en) {overflow_pulse, old_act, counter, sum} <= {ss_si, ss_q[41:1]};
	else if (~ss_hold) begin
		old_act <= active;
		overflow_pulse <= 0;

		if(~old_act && active) begin
			counter <= init;
			sum <= 0;
		end
		else if(active && ce) begin
			sum <= next;
			if(next >= OPLCLK) begin
				sum <= next - OPLCLK;
				counter <= counter + 1'd1;
				if(&counter) begin
					overflow_pulse <= 1;
					counter <= init;
				end
			end
		end
	end
end

endmodule
