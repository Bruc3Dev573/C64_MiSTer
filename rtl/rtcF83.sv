//============================================================================
//
//  RTC PCF8583
//  Copyright (C) 2021 Alexey Melnikov
//
//  This program is free software; you can redistribute it and/or modify it
//  under the terms of the GNU General Public License as published by the Free
//  Software Foundation; either version 2 of the License, or (at your option)
//  any later version.
//
//  This program is distributed in the hope that it will be useful, but WITHOUT
//  ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
//  FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License for
//  more details.
//
//  You should have received a copy of the GNU General Public License along
//  with this program; if not, write to the Free Software Foundation, Inc.,
//  51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
//
//============================================================================

// Savestate (WP A7): the I2C side runs on every clock from the cassette port
// lines and the time base on ce; both hold while the machine is stopped
// (stop, ce is gated by the caller), so the clock seen by the C64 restarts
// from the saved time after a load (virtual RTC: the host time is only taken
// at core load, on the RTC[64] toggle). flg follows that host toggle: off
// the chain, updated only while running, so a host update during a stop is
// applied at the resume. sda_o drives the cassette read line on every clock:
// the chain carries the copy ss_sda_o (follows it until ss_hold), written back
// on ss_load_done. Field order: savestate/map.yaml (RTC).
module rtcF83 #(parameter CLOCK_RATE, HAS_RAM = 1)
(
	input        clk,
	input        ce,
	input        reset,

	input [64:0] RTC,
	
	input        scl_i,
	input        sda_i,
	output reg   sda_o,

	input        stop,
	input        ss_en,
	input        ss_hold,
	input        ss_load_done,
	input        ss_si,
	output       ss_so
);

localparam CTL  = 0;
localparam FSEC = 1;
localparam SEC  = 2;
localparam MIN  = 3;
localparam HR   = 4;
localparam DATE = 5;
localparam MON  = 6;
localparam YEAR = 16;

wire [7:0] year = {1'b0,RTC[47:44],3'b000} + {3'b000,RTC[47:44],1'b0} + RTC[43:40];
wire [7:0] hr   = {1'b0,RTC[23:20],3'b000} + {3'b000,RTC[23:20],1'b0} + RTC[19:16];
wire [7:0] hrh  = (hr >= 12) ? (hr - 8'd12) : hr;
wire [5:0] hr12 = (!hrh) ? 6'h12 : (hrh == 11) ? 6'h11 : (hrh == 10) ? 6'h10 : hrh[5:0];
wire       pm   = (hr >= 12);

reg  [1:0] sda_sr, scl_sr;
reg        old_sda, old_scl;
reg        sda, scl;
reg  [7:0] tmp;
reg  [3:0] cnt = 0;
reg [10:0] bcnt = 0;
reg        ack;
reg        i2c_rw;
reg  [7:0] ptr;
reg  [7:0] data[256];
reg  [7:0] tm[17];
reg        flg = 0;
reg [31:0] seccnt = 1;
reg  [7:0] scl_d;
reg  [7:0] sda_d;
reg  [7:0] bt;
reg        ss_sda_o;

wire [233:0] ss_q = {tmp, tm[16], tm[15], tm[14], tm[13], tm[12], tm[11], tm[10], tm[9], tm[8], tm[7], tm[6], tm[5],
                     tm[4], tm[3], tm[2], tm[1], tm[0], seccnt, sda_sr, ss_sda_o, sda_d, sda, scl_sr, scl_d, scl, ptr,
                     old_sda, old_scl, i2c_rw, cnt, bt, bcnt, ack};
wire [233:0] ss_d = {ss_si, ss_q[233:1]};
assign ss_so = ss_q[0];

always @(posedge clk) begin
	if (ss_en)         ss_sda_o <= ss_d[55];
	else if (!ss_hold) ss_sda_o <= sda_o;
end

always @(posedge clk) begin
	if (!stop) bt <= HAS_RAM ? data[ptr] : 8'h00;

	// the reset is a level (held while the tape is in use): it must not clear
	// ptr/cnt while their chain cells carry other bits
	if(reset & ~ss_hold) begin
		sda_o <= 1;
		ptr <= 0;
		cnt <= 0;
	end
	else if (!stop) begin
		sda_sr <= {sda_sr[0],sda_i};
		if(sda_sr[0] == sda_sr[1]) sda <= sda_sr[1];
		old_sda <= sda;
		sda_d <= (sda_d << 1) | sda;

		scl_sr <= {scl_sr[0],scl_i};
		if(scl_sr[0] == scl_sr[1]) scl <= scl_sr[1];
		old_scl <= scl;
		scl_d <= (scl_d << 1) | scl;

		//start
		if(old_scl & scl & old_sda & ~sda) begin
			cnt <= 9;
			bcnt <= 0;
			ack <= 0;
			i2c_rw <= 0;
		end

		//stop
		if(old_scl & scl & ~old_sda & sda) begin
			cnt <= 0;
		end

		//data latch
		if(~old_scl && scl && cnt) begin
			tmp <= {tmp[6:0], sda};
			cnt <= cnt - 1'd1;
		end

		if(!cnt) sda_o <= 1;

		//data set
		if(old_scl && ~scl) begin
			sda_o <= 1;
			if(cnt == 1) begin
				if(!bcnt) begin
					if(tmp[7:1] == 'h50) begin
						sda_o <= 0;
						ack <= 1;
						i2c_rw <= tmp[0];
						bcnt <= bcnt + 1'd1;
						cnt <= 10;
					end
					else begin
						// wrong address, stop
						cnt <= 0;
					end
				end
				else if(ack) begin
					ptr <= ptr + 1'd1;
					if(~i2c_rw) begin
						if(bcnt == 1) ptr <= tmp;
						if(ptr<=16) tm[ptr] <= tmp;
						else if(HAS_RAM) data[ptr] <= tmp;
					end
					if(~&bcnt) bcnt <= bcnt + 1'd1;
					sda_o <= 0;
					cnt <= 10;
				end
			end
			else if(i2c_rw && ack && cnt) begin
				sda_o <= (ptr<=16) ? tm[ptr][cnt[2:0] - 2'd2] : bt[cnt[2:0] - 2'd2];
			end
		end
	end

	if(ce) begin
		seccnt <= seccnt + 1;
		if(seccnt >= CLOCK_RATE/100) begin
			seccnt <= 1;
			if(!tm[CTL][7]) begin
				if (tm[FSEC][3:0] != 9) tm[FSEC][3:0] <= tm[FSEC][3:0] + 1'd1;
				else begin
					tm[FSEC][3:0] <= 0;
					if (tm[FSEC][7:4] != 9) tm[FSEC][7:4] <= tm[FSEC][7:4] + 1'd1;
					else begin
						tm[FSEC][7:4] <= 0;
						if (tm[SEC][3:0] != 9) tm[SEC][3:0] <= tm[SEC][3:0] + 1'd1;
						else begin
							tm[SEC][3:0] <= 0;
							if (tm[SEC][7:4] != 5) tm[SEC][7:4] <= tm[SEC][7:4] + 1'd1;
							else begin
								tm[SEC][7:4] <= 0;
								if (tm[MIN][3:0] != 9) tm[MIN][3:0] <= tm[MIN][3:0] + 1'd1;
								else begin
									tm[MIN][3:0] <= 0;
									if (tm[MIN][7:4] != 5) tm[MIN][7:4] <= tm[MIN][7:4] + 1'd1;
									else begin
										tm[MIN][7:4] <= 0;
										if (tm[HR][3:0] == 9) begin
											tm[HR][3:0] <= 0;
											tm[HR][5:4] <= tm[HR][5:4] + 1'd1;
										end
										else if (tm[HR] == {2'b10,6'h12}) begin
											tm[HR][3:0] <= 1;
											tm[HR][5:4] <= 1;
										end
										else if ((tm[HR] != {2'b11,6'h12}) && (tm[HR] != 8'h23)) tm[HR][3:0] <= tm[HR][3:0] + 1'd1;
										else begin
											if (tm[HR][7]) tm[HR][6:0] <= 1;
											else tm[HR][6:0] <= 0;
											
											tm[MON][7:5] <= (tm[MON][7:5] == 6) ? 3'd0 : (tm[MON][7:5] + 1'd1);

											if (({tm[MON][4:0], 2'b00, tm[DATE][5:0]} == 13'h0228) ||
												 ({tm[MON][4:0], 2'b00, tm[DATE][5:0]} == 13'h0430) ||
												 ({tm[MON][4:0], 2'b00, tm[DATE][5:0]} == 13'h0630) ||
												 ({tm[MON][4:0], 2'b00, tm[DATE][5:0]} == 13'h0930) ||
												 ({tm[MON][4:0], 2'b00, tm[DATE][5:0]} == 13'h1130) ||
												 (tm[DATE][5:0] == 6'h31)) begin
												
												tm[DATE][5:0] <= 1;
												if (tm[MON][3:0] == 9) tm[MON][4:0] <= 'h10;
												else if (tm[MON][4:0] != 'h12) tm[MON][3:0] <= tm[MON][3:0] + 1'd1;
												else begin 
													tm[MON][4:0] <= 1;
													tm[DATE][7:6] <= tm[DATE][7:6] + 1'd1;
												end
											end
											else if (tm[DATE][3:0] != 9) tm[DATE][3:0] <= tm[DATE][3:0] + 1'd1;
											else begin
												tm[DATE][3:0] <= 0;
												tm[DATE][5:4] <= tm[DATE][5:4] + 1'd1;
											end
										end
									end
								end
							end
						end
					end
				end
			end
		end
	end

	if (!stop) begin
		flg <= RTC[64];
		if (flg != RTC[64]) begin
			tm[CTL]  <= 0;
			tm[FSEC] <= 0;
			tm[SEC]  <= RTC[6:0];
			tm[MIN]  <= RTC[15:8];
			tm[HR]   <= {1'b1,pm, hr12};
			tm[DATE] <= {year[1:0],RTC[29:24]};
			tm[MON]  <= {RTC[50:48],RTC[36:32]};
			tm[YEAR] <= year;
			seccnt   <= 1;
		end
	end

	if (ss_en) begin
		{tmp, tm[16], tm[15], tm[14], tm[13], tm[12], tm[11], tm[10], tm[9], tm[8], tm[7], tm[6], tm[5],
		 tm[4], tm[3], tm[2], tm[1], tm[0], seccnt, sda_sr} <= ss_d[233:56];
		{sda_d, sda, scl_sr, scl_d, scl, ptr, old_sda, old_scl, i2c_rw, cnt, bt, bcnt, ack} <= ss_d[54:0];
	end
	if (ss_load_done) sda_o <= ss_sda_o;
end

endmodule
