// MT48LC16M16A2 command-level model; no controller timing is inferred from ce.
// Micron 256Mb_sdr.pdf Rev. W, AC tables (-6A/-7E/-75), initialization and
// auto-precharge sections: https://www.alliancememory.com/wp-content/uploads/Micron_256M_SDRAM_PartNo.MT48LC16M16A2.pdf
// Use the conservative -75 envelope: tRCD/tRP=20ns, tRAS=44ns..120us,
// tRC/tRFC=66ns, manual tWR=15ns, auto tWR=1 clock+7.5ns, tMRD=2 clocks.
// -6A: 18/18/42/60/60/12ns, auto tWR=1 clock+6ns;
// -7E: 15/15/37/60/66/14ns, auto tWR=1 clock+7ns.
// BL=1 READs may follow each other on every clock (tCCD 1): each drives its
// data CAS 2 clocks later, at most two are in flight.
module sim_mt48lc16m16 (
	input             clk,
	input             cke,
	input             cs_n,
	input             ras_n,
	input             cas_n,
	input             we_n,
	input      [12:0]  addr,
	input      [1:0]   ba,
	input      [1:0]   dqm,
	inout      [15:0]  dq,
	input             ss_own
);

localparam real TCK_NS = 1000.0 / 63.0559;
localparam integer TRCD = integer'($ceil(20.0 / TCK_NS));
localparam integer TRP  = integer'($ceil(20.0 / TCK_NS));
localparam integer TRAS = integer'($ceil(44.0 / TCK_NS));
localparam integer TRC  = integer'($ceil(66.0 / TCK_NS));
localparam integer TRFC = integer'($ceil(66.0 / TCK_NS));
localparam integer TWR  = integer'($ceil(15.0 / TCK_NS));
localparam integer TWRA = 1 + integer'($ceil(7.5 / TCK_NS));
localparam integer TRASMAX = integer'($floor(120000.0 / TCK_NS));
localparam integer TREF = integer'($floor(64000000.0 / TCK_NS));
localparam integer NERR = 13;
localparam [2:0] LMR=0, REF=1, PRE=2, ACT=3, WR=4, RD=5, BST=6, NOP=7;
wire [2:0] cmd = cs_n ? NOP : {ras_n, cas_n, we_n};

// Public view uses the controller's byte address, not a second RAM copy:
// [24]=DQ lane, [23]=column[8], [22:21]=bank, [20:8]=row, [7:0]=column[7:0].
reg [7:0] mem [1<<25] /*verilator public_flat_rw*/;
reg [7:0] written [1<<22] /*verilator public_flat_rw*/;
reg [63:0] ss_conflicts /*verilator public_flat_rd*/ = 0;
reg [63:0] violations [2][NERR];
reg [63:0] clocks [2], refreshes [2], max_gap [2], unwritten [2];
reg [63:0] cycle = 0;
reg [3:0] opened = 0, activated = 0, wrote = 0;
reg [12:0] row [4];
reg [63:0] active_at [4], write_at [4], precharge_at [4], available_at [4];
reg [3:0] auto_pending = 0;
reg precharged = 0, mode_loaded = 0, initialized = 0;
reg [1:0] init_refreshes = 0;
reg [63:0] mode_at = 0, refresh_at = 0, init_at = 0;
reg [63:0] refresh_history [8192];
reg [12:0] refresh_row = 0;
reg [13:0] refresh_count = 0;
reg refresh_late = 0;
reg [1:0] rp_v = 0;                 // READ data pending: [0] older, [1] newer
reg [63:0] rp_at [2];
reg [23:0] rp_addr [2];
reg rp_owner [2];
reg out_now;
reg [3:0] ras_late = 0;            // tRAS max reported for the open row
reg [1:0] dqm_d1 = 3, dqm_d2 = 3, dq_mask = 3;
reg [15:0] dq_out = 0;
reg dq_valid = 0;
assign dq[7:0]  = dq_valid && !dq_mask[0] ? dq_out[7:0]  : 8'bz;
assign dq[15:8] = dq_valid && !dq_mask[1] ? dq_out[15:8] : 8'bz;

function automatic string command_name(input [2:0] c);
	case(c)
		LMR: command_name="LOAD_MODE"; REF: command_name="AUTO_REFRESH";
		PRE: command_name="PRECHARGE"; ACT: command_name="ACTIVE";
		WR: command_name="WRITE"; RD: command_name="READ";
		BST: command_name="BURST_TERMINATE"; default: command_name="NOP";
	endcase
endfunction
function automatic string error_name(input integer n);
	case(n)
		0: error_name="bank_state"; 1: error_name="tRCD"; 2: error_name="tRP";
		3: error_name="tRAS"; 4: error_name="tRC"; 5: error_name="tRFC";
		6: error_name="tWR"; 7: error_name="refresh_64ms";
		8: error_name="initialization"; 9: error_name="mode";
		10: error_name="tMRD"; 11: error_name="DQ_overlap";
		default: error_name="tRAS_max";
	endcase
endfunction
task automatic violation(input integer kind, input integer bank, input string detail);
	begin
		violations[ss_own][kind] = violations[ss_own][kind] + 1;
		ss_conflicts = ss_conflicts + 1;
		if(ss_conflicts <= 16)
			$display("SDRAM violation %m clk64=%0d time_ns=%.2f owner=%s cmd=%s bank=%0d row=%h addr=%h kind=%s %s",
				cycle, real'(cycle)*TCK_NS, ss_own ? "engine" : "normal", command_name(cmd),
				bank, row[bank], addr, error_name(kind), detail);
	end
endtask
task automatic precharge_bank(input integer bank);
	begin
		if(opened[bank]) begin
			if(cycle-active_at[bank] < TRAS) violation(3, bank, "precharge before minimum row-active time");
			if(wrote[bank] && cycle-write_at[bank] < TWR) violation(6, bank, "precharge before write recovery");
		end
		opened[bank] = 0;
		auto_pending[bank] = 0;
		ras_late[bank] = 0;
		available_at[bank] = cycle + TRP;
	end
endtask

integer b, lane, slot;
reg [24:0] byte_addr;
reg [63:0] gap, deadline, earliest;
always @(posedge clk) begin
	cycle = cycle + 1;
	clocks[ss_own] = clocks[ss_own] + 1;
	dq_valid <= 0;
	dq_mask <= dqm_d2;
	dqm_d2 <= dqm_d1;
	dqm_d1 <= dqm;
	for(b=0; b<4; b=b+1) begin
		if(auto_pending[b] && cycle >= precharge_at[b]) begin
			opened[b] = 0;
			auto_pending[b] = 0;
		end
		if(opened[b] && !auto_pending[b] && cycle-active_at[b] > TRASMAX && !ras_late[b]) begin
			violation(12, b, "row open longer than tRAS max");
			ras_late[b] = 1;
		end
	end
	out_now = 0;
	if(rp_v[0] && cycle == rp_at[0]) begin
		dq_out <= {mem[{1'b1, rp_addr[0]}], mem[{1'b0, rp_addr[0]}]};
		dq_valid <= 1;
		out_now = 1;
		for(lane=0; lane<2; lane=lane+1) begin
			byte_addr = {lane[0], rp_addr[0]};
			if(!dqm_d2[lane] && !written[byte_addr[24:3]][byte_addr[2:0]]) begin
				unwritten[rp_owner[0]] = unwritten[rp_owner[0]] + 1;
				if(unwritten[rp_owner[0]] <= 2)
					$display("SDRAM info %m clk64=%0d owner=%s unwritten_byte=%h (zero, not a violation)",
						cycle, rp_owner[0] ? "engine" : "normal", byte_addr);
			end
		end
		rp_v[0] = rp_v[1];
		rp_at[0] = rp_at[1];
		rp_addr[0] = rp_addr[1];
		rp_owner[0] = rp_owner[1];
		rp_v[1] = 0;
	end
	if(!initialized && precharged && mode_loaded && init_refreshes == 2 &&
		cycle-mode_at >= 2 && cycle-refresh_at >= TRFC) begin
		initialized = 1;
		init_at = cycle;
	end
	if(initialized) begin
		gap = cycle-refresh_at;
		if(gap > max_gap[ss_own]) max_gap[ss_own] = gap;
		// A rolling 8192-refresh window permits legal burst refresh; a gap
		// above 7.8125us alone is not a retention violation.
		deadline = (refresh_count == 8192 ? refresh_history[refresh_row] : init_at) + TREF;
		if(cycle > deadline && !refresh_late) begin
			violation(7, ba, $sformatf("row=%0d last_refresh=%0d deadline=%0d gap=%0d", refresh_row,
				refresh_count == 8192 ? refresh_history[refresh_row] : init_at, deadline, gap));
			refresh_late = 1;
		end
	end
	if(!cke) violation(9, ba, "CKE low: power-down/self-refresh is outside this controller model");
	else if(cmd != NOP) begin
		if(refresh_at != 0 && cycle-refresh_at < TRFC) violation(5, ba, "command during refresh recovery");
		if(mode_loaded && cycle-mode_at < 2) violation(10, ba, "command during mode-register recovery");
		if((cmd == ACT || cmd == RD || cmd == WR) && !initialized)
			violation(8, ba, $sformatf("precharge_all=%0d mode=%0d initial_refreshes=%0d", precharged, mode_loaded, init_refreshes));
		case(cmd)
			PRE: begin
				for(b=0; b<4; b=b+1) if(addr[10] || ba == b) precharge_bank(b);
				if(addr[10]) precharged = 1;
			end
			LMR, REF: begin
				if(!precharged) violation(8, ba, "PRECHARGE ALL required before initialization");
				for(b=0; b<4; b=b+1) begin
					if(opened[b]) violation(0, b, "all banks must be idle");
					if(cycle < available_at[b]) violation(2, b, "bank still precharging");
				end
				if(cmd == LMR) begin
					// BL=1, sequential, CL=2, standard operation; M9 may be 0 or 1.
					if(ba != 0 || (addr & 13'h1dff) != 13'h020)
						violation(9, ba, "only BL=1, sequential, CAS=2 is implemented");
					mode_loaded = 1;
					mode_at = cycle;
				end
				else begin
					refreshes[ss_own] = refreshes[ss_own] + 1;
					refresh_at = cycle;
					refresh_late = 0;
					if(init_refreshes < 2) init_refreshes = init_refreshes + 1;
					if(initialized) begin
						refresh_history[refresh_row] = cycle;
						refresh_row = refresh_row + 1'b1;
						if(refresh_count < 8192) refresh_count = refresh_count + 1;
					end
				end
			end
			ACT: begin
				if(opened[ba]) violation(0, ba, "ACTIVE on an open bank");
				if(cycle < available_at[ba]) violation(2, ba, "ACTIVE before precharge completed");
				if(activated[ba] && cycle-active_at[ba] < TRC) violation(4, ba, "ACTIVE before minimum row cycle");
				opened[ba] = 1;
				activated[ba] = 1;
				wrote[ba] = 0;
				auto_pending[ba] = 0;
				ras_late[ba] = 0;
				row[ba] = addr;
				active_at[ba] = cycle;
			end
			RD, WR: begin
				if(!opened[ba] || auto_pending[ba]) violation(0, ba, "column command without an available open row");
				if(cycle-active_at[ba] < TRCD) violation(1, ba, "column command too soon after ACTIVE");
				byte_addr = {1'b0, addr[8], ba, row[ba], addr[7:0]};
				if(cmd == WR) begin
					if(dq_valid || out_now || rp_v != 0) violation(11, ba, "WRITE overlaps read data");
					for(lane=0; lane<2; lane=lane+1) if(!dqm[lane]) begin
						byte_addr[24] = lane[0];
						mem[byte_addr] = dq[8*lane +: 8];
						written[byte_addr[24:3]][byte_addr[2:0]] = 1;
					end
					wrote[ba] = 1;
					write_at[ba] = cycle;
				end
				else begin
					if(rp_v[1]) violation(11, ba, "more than two READs in flight");
					else begin
						slot = rp_v[0] ? 1 : 0;
						rp_at[slot] = cycle+2;
						rp_addr[slot] = byte_addr[23:0];
						rp_owner[slot] = ss_own;
						rp_v[slot] = 1;
					end
				end
				if(addr[10]) begin
					earliest = cycle + (cmd == WR ? TWRA : 1);
					precharge_at[ba] = earliest > active_at[ba]+TRAS ? earliest : active_at[ba]+TRAS;
					available_at[ba] = precharge_at[ba]+TRP;
					auto_pending[ba] = 1;
				end
			end
			default: violation(9, ba, "burst terminate is outside BL=1 controller operation");
		endcase
	end
end

integer owner, kind;
reg [63:0] total;
final begin
	for(owner=0; owner<2; owner=owner+1) begin
		total = 0;
		for(kind=0; kind<NERR; kind=kind+1) total = total + violations[owner][kind];
		$display("SDRAM summary %m owner=%s violations=%0d clocks=%0d refreshes=%0d max_gap_clk64=%0d max_gap_ns=%.2f unwritten_reads=%0d initialized=%0d",
			owner ? "engine" : "normal", total, clocks[owner], refreshes[owner], max_gap[owner],
			real'(max_gap[owner])*TCK_NS, unwritten[owner], initialized);
		for(kind=0; kind<NERR; kind=kind+1) if(violations[owner][kind] != 0)
			$display("SDRAM count %m owner=%s kind=%s count=%0d", owner ? "engine" : "normal", error_name(kind), violations[owner][kind]);
	end
end
endmodule
