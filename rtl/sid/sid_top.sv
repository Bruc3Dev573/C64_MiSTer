
module sid_top 
#(
	parameter MULTI_FILTERS = 1, 
	parameter DUAL = 1
)
(
	input         reset,

	input         clk,
	input         ce_1m,

	input [N-1:0] cs,
	input         we,
	input   [4:0] addr,
	input   [7:0] data_in,
	output  [7:0] data_out,

	input  [12:0] fc_offset_l,
	input   [7:0] pot_x_l,
	input   [7:0] pot_y_l,
	input  [17:0] ext_in_l,
	output [17:0] audio_l,

	input  [12:0] fc_offset_r, // not used if DUAL is 0
	input   [7:0] pot_x_r,     // not used if DUAL is 0
	input   [7:0] pot_y_r,     // not used if DUAL is 0
	input  [17:0] ext_in_r,    // not used if DUAL is 0
	output [17:0] audio_r,

	input [N-1:0] filter_en,
	input [N-1:0] mode,
	input [(N*2)-1:0] cfg,

	input         ld_clk,
	input  [11:0] ld_addr,
	input  [15:0] ld_data,
	input         ld_wr,

	// savestate scan chain, ss_si -> SID2 -> SID1 -> ss_so (docs/SAVESTATES.md).
	// The voices run on ce_1m. The table/filter pipeline steps on every clock
	// for 16 clocks after ce_1m, across the boundary where the machine stops:
	// it holds while the machine is stopped (stop = pause or savestate freeze),
	// so it resumes exactly where it was cut.
	input         ss_en,
	input         stop,
	input         ss_si,
	output        ss_so
);

localparam N = DUAL ? 2 : 1;

// Internal Signals
reg  [15:0] Voice_1_Freq[N];
reg  [11:0] Voice_1_Pw[N];
reg   [7:0] Voice_1_Control[N];
reg   [7:0] Voice_1_Att_dec[N];
reg   [7:0] Voice_1_Sus_Rel[N];

reg  [15:0] Voice_2_Freq[N];
reg  [11:0] Voice_2_Pw[N];
reg   [7:0] Voice_2_Control[N];
reg   [7:0] Voice_2_Att_dec[N];
reg   [7:0] Voice_2_Sus_Rel[N];

reg  [15:0] Voice_3_Freq[N];
reg  [11:0] Voice_3_Pw[N];
reg   [7:0] Voice_3_Control[N];
reg   [7:0] Voice_3_Att_dec[N];
reg   [7:0] Voice_3_Sus_Rel[N];

reg  [10:0] Filter_Fc[N];
reg   [7:0] Filter_Res_Filt[N];
reg   [7:0] Filter_Mode_Vol[N];

wire  [7:0] Misc_Osc3[N];
wire  [7:0] Misc_Env3[N];

wire [21:0] voice_1[N];
wire [21:0] voice_2[N];
wire [21:0] voice_3[N];

wire        voice_1_PA_MSB[N];
wire        voice_2_PA_MSB[N];
wire        voice_3_PA_MSB[N];

reg   [7:0] _st_out[N*3];
reg   [7:0] p_t_out[N*3];
reg   [7:0] ps__out[N*3];
reg   [7:0] pst_out[N*3];
wire [11:0] acc_t[N*3];

reg  [17:0] audio[N];

reg   [7:0] bus_data[N];
reg  [12:0] Fc_offset[N];

// savestate: per chip, the register file then voices 3, 2, 1 (each voice:
// its registers, then its envelope); SID1 carries the shared table/filter
// pipeline ahead of its register file. Field order: savestate/map.yaml.
wire [286:0] top_q[N];
wire [286:0] top_d[N];
wire [N-1:0] chip_so;
wire         filter_so;
wire         ss_pipe_si = (N == 2) ? chip_so[N-1] : ss_si;
assign       ss_so = chip_so[0];

generate
	genvar i;
	
	for(i=0; i<N; i=i+1) begin :chip
		wire ss_v1_si, ss_v2_si, ss_v3_si;

		assign top_q[i] = {pst_out[i*3+2], pst_out[i*3+1], pst_out[i*3], ps__out[i*3+2], ps__out[i*3+1], ps__out[i*3],
		                   p_t_out[i*3+2], p_t_out[i*3+1], p_t_out[i*3], _st_out[i*3+2], _st_out[i*3+1], _st_out[i*3],
		                   bus_data[i], Filter_Mode_Vol[i], Filter_Res_Filt[i], Filter_Fc[i],
		                   Voice_3_Sus_Rel[i], Voice_3_Att_dec[i], Voice_3_Control[i], Voice_3_Pw[i], Voice_3_Freq[i],
		                   Voice_2_Sus_Rel[i], Voice_2_Att_dec[i], Voice_2_Control[i], Voice_2_Pw[i], Voice_2_Freq[i],
		                   Voice_1_Sus_Rel[i], Voice_1_Att_dec[i], Voice_1_Control[i], Voice_1_Pw[i], Voice_1_Freq[i]};
		assign top_d[i] = {(i == 0) ? filter_so : ss_si, top_q[i][286:1]};
		assign ss_v3_si = top_q[i][0];

		sid_voice v1
		(
			.clock(clk),
			.ce_1m(ce_1m),
			.reset(reset),
			.mode(mode[i]),
			.freq(Voice_1_Freq[i]),
			.pw(Voice_1_Pw[i]),
			.control(Voice_1_Control[i]),
			.att_dec(Voice_1_Att_dec[i]),
			.sus_rel(Voice_1_Sus_Rel[i]),
			.osc_msb_in(voice_3_PA_MSB[i]),
			.osc_msb_out(voice_1_PA_MSB[i]),
			.voice_out(voice_1[i]),
			._st_out(_st_out[i*3+0]),
			.p_t_out(p_t_out[i*3+0]),
			.ps__out(ps__out[i*3+0]),
			.pst_out(pst_out[i*3+0]),
			.acc_t(acc_t[i*3+0]),
			.ss_en(ss_en),
			.stop(stop),
			.ss_si(ss_v1_si),
			.ss_so(chip_so[i])
		);

		sid_voice v2
		(
			.clock(clk),
			.ce_1m(ce_1m),
			.reset(reset),
			.mode(mode[i]),
			.freq(Voice_2_Freq[i]),
			.pw(Voice_2_Pw[i]),
			.control(Voice_2_Control[i]),
			.att_dec(Voice_2_Att_dec[i]),
			.sus_rel(Voice_2_Sus_Rel[i]),
			.osc_msb_in(voice_1_PA_MSB[i]),
			.osc_msb_out(voice_2_PA_MSB[i]),
			.voice_out(voice_2[i]),
			._st_out(_st_out[i*3+1]),
			.p_t_out(p_t_out[i*3+1]),
			.ps__out(ps__out[i*3+1]),
			.pst_out(pst_out[i*3+1]),
			.acc_t(acc_t[i*3+1]),
			.ss_en(ss_en),
			.stop(stop),
			.ss_si(ss_v2_si),
			.ss_so(ss_v1_si)
		);

		sid_voice v3
		(
			.clock(clk),
			.ce_1m(ce_1m),
			.reset(reset),
			.mode(mode[i]),
			.freq(Voice_3_Freq[i]),
			.pw(Voice_3_Pw[i]),
			.control(Voice_3_Control[i]),
			.att_dec(Voice_3_Att_dec[i]),
			.sus_rel(Voice_3_Sus_Rel[i]),
			.osc_msb_in(voice_2_PA_MSB[i]),
			.osc_msb_out(voice_3_PA_MSB[i]),
			.voice_out(voice_3[i]),
			.osc_out(Misc_Osc3[i]),
			.env_out(Misc_Env3[i]),
			._st_out(_st_out[i*3+2]),
			.p_t_out(p_t_out[i*3+2]),
			.ps__out(ps__out[i*3+2]),
			.pst_out(pst_out[i*3+2]),
			.acc_t(acc_t[i*3+2]),
			.ss_en(ss_en),
			.stop(stop),
			.ss_si(ss_v3_si),
			.ss_so(ss_v2_si)
		);
		
		always @(posedge clk) Fc_offset[i] <= i ? fc_offset_r : fc_offset_l;

		// Register Decoding
		always @(posedge clk) begin
			if (reset) begin
				Voice_1_Freq[i]    <= 0;
				Voice_1_Pw[i]      <= 0;
				Voice_1_Control[i] <= 0;
				Voice_1_Att_dec[i] <= 0;
				Voice_1_Sus_Rel[i] <= 0;
				Voice_2_Freq[i]    <= 0;
				Voice_2_Pw[i]      <= 0;
				Voice_2_Control[i] <= 0;
				Voice_2_Att_dec[i] <= 0;
				Voice_2_Sus_Rel[i] <= 0;
				Voice_3_Freq[i]    <= 0;
				Voice_3_Pw[i]      <= 0;
				Voice_3_Control[i] <= 0;
				Voice_3_Att_dec[i] <= 0;
				Voice_3_Sus_Rel[i] <= 0;
				Filter_Fc[i]       <= 0;
				Filter_Res_Filt[i] <= 0;
				Filter_Mode_Vol[i] <= 0;
			end
			else if(cs[i] && !stop) begin
				if (we) begin
					bus_data[i] <= data_in;
					case (addr)
						5'h00: Voice_1_Freq[i][7:0] <= data_in;
						5'h01: Voice_1_Freq[i][15:8]<= data_in;
						5'h02: Voice_1_Pw[i][7:0]   <= data_in;
						5'h03: Voice_1_Pw[i][11:8]  <= data_in[3:0];
						5'h04: Voice_1_Control[i]   <= data_in;
						5'h05: Voice_1_Att_dec[i]   <= data_in;
						5'h06: Voice_1_Sus_Rel[i]   <= data_in;
						5'h07: Voice_2_Freq[i][7:0] <= data_in;
						5'h08: Voice_2_Freq[i][15:8]<= data_in;
						5'h09: Voice_2_Pw[i][7:0]   <= data_in;
						5'h0a: Voice_2_Pw[i][11:8]  <= data_in[3:0];
						5'h0b: Voice_2_Control[i]   <= data_in;
						5'h0c: Voice_2_Att_dec[i]   <= data_in;
						5'h0d: Voice_2_Sus_Rel[i]   <= data_in;
						5'h0e: Voice_3_Freq[i][7:0] <= data_in;
						5'h0f: Voice_3_Freq[i][15:8]<= data_in;
						5'h10: Voice_3_Pw[i][7:0]   <= data_in;
						5'h11: Voice_3_Pw[i][11:8]  <= data_in[3:0];
						5'h12: Voice_3_Control[i]   <= data_in;
						5'h13: Voice_3_Att_dec[i]   <= data_in;
						5'h14: Voice_3_Sus_Rel[i]   <= data_in;
						5'h15: Filter_Fc[i][2:0]    <= data_in[2:0];
						5'h16: Filter_Fc[i][10:3]   <= data_in;
						5'h17: Filter_Res_Filt[i]   <= data_in;
						5'h18: Filter_Mode_Vol[i]   <= data_in;
					endcase
				end
				else begin
					case (addr)
						5'h19: bus_data[i] = i ? pot_x_r : pot_x_l;
						5'h1a: bus_data[i] = i ? pot_y_r : pot_y_l;
						5'h1b: bus_data[i] = Misc_Osc3[i];
						5'h1c: bus_data[i] = Misc_Env3[i];
					endcase
				end
			end
			if (ss_en) {bus_data[i], Filter_Mode_Vol[i], Filter_Res_Filt[i], Filter_Fc[i],
			            Voice_3_Sus_Rel[i], Voice_3_Att_dec[i], Voice_3_Control[i], Voice_3_Pw[i], Voice_3_Freq[i],
			            Voice_2_Sus_Rel[i], Voice_2_Att_dec[i], Voice_2_Control[i], Voice_2_Pw[i], Voice_2_Freq[i],
			            Voice_1_Sus_Rel[i], Voice_1_Att_dec[i], Voice_1_Control[i], Voice_1_Pw[i], Voice_1_Freq[i]} <= top_d[i][190:0];
		end
	end
endgenerate

wire [15:0] F0;
wire n = DUAL && state[3];

sid_tables #(MULTI_FILTERS) sid_tables
(
	.clock(clk),
	.mode(mode[n]),

	.acc_t(f_acc_t),
	._st_out(f__st_out),
	.p_t_out(f_p_t_out),
	.ps__out(f_ps__out),
	.pst_out(f_pst_out),
	
	.cfg(cfg[n*2 +:2]),
	.Fc(Filter_Fc[n]),
	.Fc_offset(Fc_offset[n]),
	.F0(F0),
	.ld_clk(ld_clk),
	.ld_addr(ld_addr),
	.ld_data(ld_data),
	.ld_wr(ld_wr)
);

wire  [7:0] f__st_out;
wire  [7:0] f_p_t_out;
wire  [7:0] f_ps__out;
wire  [7:0] f_pst_out;
reg  [11:0] f_acc_t;
reg   [3:0] state;
reg   [2:0] v;

reg  [17:0] audio0;

// shared pipeline and output samples (SID1): audio[N-1], audio[0], audio0, f_acc_t, v, state
wire [72:0] pipe_q = {audio[N-1], audio[0], audio0, f_acc_t, v, state};
wire [72:0] pipe_d = {ss_pipe_si, pipe_q[72:1]};

always @(posedge clk) begin
	if (!stop) begin
	if(~&state) state <= state + 1'd1;
	if(ce_1m) state <= 0;

	case(state)
		1,3,5,7,9,11: begin
			f_acc_t <= acc_t[state[3:1]];
			v <= state[3:1];
		end
	endcase

	case(state)
		3,5,7: begin
			_st_out[v] <= f__st_out;
			p_t_out[v] <= f_p_t_out;
			ps__out[v] <= f_ps__out;
			pst_out[v] <= f_pst_out;
		end
		9,11,13: if(DUAL) begin
			_st_out[v] <= f__st_out;
			p_t_out[v] <= f_p_t_out;
			ps__out[v] <= f_ps__out;
			pst_out[v] <= f_pst_out;
		end
	endcase
	end

	if (ss_en) begin
		{f_acc_t, v, state} <= pipe_d[18:0];
		{pst_out[2], pst_out[1], pst_out[0], ps__out[2], ps__out[1], ps__out[0],
		 p_t_out[2], p_t_out[1], p_t_out[0], _st_out[2], _st_out[1], _st_out[0]} <= top_d[0][286:191];
		if (DUAL)
			{pst_out[(N-1)*3+2], pst_out[(N-1)*3+1], pst_out[(N-1)*3], ps__out[(N-1)*3+2], ps__out[(N-1)*3+1], ps__out[(N-1)*3],
			 p_t_out[(N-1)*3+2], p_t_out[(N-1)*3+1], p_t_out[(N-1)*3], _st_out[(N-1)*3+2], _st_out[(N-1)*3+1], _st_out[(N-1)*3]} <= top_d[N-1][286:191];
	end
end

wire [17:0] faudio;

sid_filter sid_filter
(
	.clk(clk),
	.state(state[2:0]),
	.mode(mode[n]),

	.F0(F0),
	.Res_Filt(Filter_Res_Filt[n]),
	.Mode_Vol(Filter_Mode_Vol[n]),
	.voice1(voice_1[n]),
	.voice2(voice_2[n]),
	.voice3(voice_3[n]),
	.ext_in(22'(signed'({n ? ext_in_r : ext_in_l, 3'b000}))),

	.audio(faudio),

	.ss_en(ss_en),
	.stop(stop),
	.ss_si(pipe_q[0]),
	.ss_so(filter_so)
);

always @(posedge clk) begin
	// faudio is two states later than upstream (was 6) because sid_filter
	// pipelines the compressor across filter-states 5-7 to close timing; the
	// first-pass result lands at state 8 and the DUAL slot at 15 (was 14).
	if (!stop) begin
		if(state == 8)  audio0 <= faudio;
		if(state == 15) begin
			audio[n] <= faudio;
			audio[0] <= audio0;
		end
	end
	if (ss_en) {audio[N-1], audio[0], audio0} <= pipe_d[72:19];
end

assign data_out = cs[0] ? bus_data[0] : bus_data[N-1];

assign audio_l = audio[0];
assign audio_r = audio[N-1];

endmodule
