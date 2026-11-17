// Savestate engine for C64_MiSTer (WP A2).
//
// Ported from the savestate engine of the TurboGrafx16 core (rtl/savestates.vhd,
// based on the NES_MiSTer savestate framework by Robert Peip): same request
// handshake, settle delay, header protocol towards Main (STATESIZE + change
// counter, header cleared first and written last) and forced-boundary rules.
// What changes for the C64:
//   - registers travel on one serial scan chain (rtl/savestate/ss_chain.sv),
//     no 64-bit shadow bus: the CHAIN region keeps the 128-word layout of
//     savestate/map.yaml, word w carries SS_WORD_NBITS[w] chain bits;
//   - memories are TLV regions (tag, length, data) walked through a byte bus;
//     unknown tags are skipped on load, optional regions are written only when
//     present (rgn_present);
//   - a payload header (format version, chain length, build hash, config mask,
//     CRC-32 of the payload computed in fabric while streaming); a load first
//     reads the whole slot and checks it, and only then restores anything.
//
// Slot layout (64-bit words from slot_addr, see docs/SAVESTATES.md):
//   w0  {STATESIZE[31:0] (32-bit words incl. this header), change counter[31:0]}
//   w1  {build_hash[31:0], chain_bits[15:0], format_version[15:0]}
//   w2  {config_mask[31:0], crc32[31:0]}   crc over w3 .. end marker
//   w3  TLV: {length in bytes[31:0], 24'd0, tag[7:0]}, then ceil(length/8) words
//       (region byte k is byte k%8 of word k/8, little endian)
//   ... more TLVs, first CHAIN (tag 0x40), then the map.yaml regions in order
//   end {32'd0, 32'd0} (tag 0)

`include "c64_savestates.vh"

module savestates #(
	parameter [31:0] BUILD_HASH = 32'd0,
	parameter [31:0] SLOT_BYTES = `SS_SLOT_BYTES,
	parameter        SETTLE     = 100,
	parameter        WDOG_BITS  = 22,      // one DDR/region access longer than 2^WDOG_BITS clocks aborts
	// map.yaml segments that are instrumented ("live"), bit k = segment k in
	// map order (`SS_SEG_<NAME>). Only live segments are on the chain and
	// shifted; the words of the others are written as 0 and skipped on load.
	// Each chip WP sets its bit when it inserts its segment in the chain.
	parameter [31:0] LIVE       = 32'd0
)
(
	input             clk,
	input             reset,

	// requests (one clock, from statemanager / self-test)
	input             save,
	input             load,
	input      [28:0] slot_addr,     // 64-bit word address of the slot in DDR3
	input             hold,          // keep the machine frozen after the operation
	input             sd_count,      // write the change counter (Main copies the slot to SD)
	input             inhibit,       // refuse new requests (downloads, reset)
	output            busy,
	output reg        done = 0,      // 1 clock when an accepted operation ends
	output reg  [3:0] result = 0,    // with done: 0 ok, see RES_*
	output reg        result_load = 0,
	output reg [31:0] last_crc = 0,  // payload CRC of the last save or verified load

	// machine freeze (ss_freeze)
	output            freeze_req,
	input             freeze_ack,
	input             freeze_forced,

	// configuration
	input      [31:0] config_mask,
	input  [`SS_REGION_COUNT:0] rgn_present, // bit 1 + `SS_RGN_<NAME>: region exists (bit 0 = CHAIN, forced)
	input      [24:0] reu_bytes,     // size of REU_RAM (from the OSD option)

	// scan chain (clk)
	output reg        chain_en = 0,
	output            chain_so,      // into the last segment
	input             chain_si,      // from the first segment (map.yaml order)
	output reg        loading = 0,   // a load is writing machine state
	output reg        load_done = 0, // 1 clock after a load, before the release

	// regions: byte bus, one access per req, ack (1 clock) ends it
	output reg  [7:0] rgn_tag = 0,
	output reg [23:0] rgn_addr = 0,
	output reg        rgn_req = 0,
	output reg        rgn_we = 0,
	output reg  [7:0] rgn_wdata = 0,
	input       [7:0] rgn_rdata,
	input             rgn_ack,

	// DDR3, one 64-bit word per req (ss_ddram_arb), ack ends it (read data valid)
	output reg [28:0] ddr_addr = 0,
	output reg [63:0] ddr_wdata = 0,
	output reg  [7:0] ddr_be = 8'hFF,
	output reg        ddr_req = 0,
	output reg        ddr_we = 0,
	input      [63:0] ddr_rdata,
	input             ddr_ack
);

localparam RES_OK       = 4'd0;
localparam RES_FORCED   = 4'd1;  // save: no boundary within the watchdog, abandoned
localparam RES_TOOBIG   = 4'd2;  // save: does not fit in the slot (REU)
localparam RES_EMPTY    = 4'd3;  // load: no valid header (empty or torn slot)
localparam RES_VERSION  = 4'd4;  // load: other format version or chain length
localparam RES_CONFIG   = 4'd5;  // load: other hardware configuration
localparam RES_CRC      = 4'd6;  // load: CRC or TLV structure error, missing region
localparam RES_INHIBIT  = 4'd7;  // request refused or cancelled before the first write
localparam RES_TIMEOUT  = 4'd8;  // DDR or region access stuck

localparam [7:0] TAG_CHAIN = 8'h40;
localparam       NRGN      = `SS_REGION_COUNT;
localparam       NREG      = NRGN + 1;          // index 0 = CHAIN, 1 + r = map region r
localparam [4:0] NREG5     = NREG;
localparam       CWORDS    = `SS_CHAIN_WORDS;   // 64-bit words of the CHAIN region
localparam       CWB       = $clog2(CWORDS);
localparam [7*CWORDS-1:0] NBITS_MAP = `SS_WORD_NBITS;
localparam [5*CWORDS-1:0] WSEG      = `SS_WORD_SEG;
localparam [8*NRGN-1:0]   RTAGS     = `SS_REGION_TAGS;
localparam [25*NRGN-1:0]  RSIZES    = `SS_REGION_SIZES;
localparam [21:0] SLOT_WORDS = SLOT_BYTES[24:3];
localparam [15:0] FMT_VERSION = `SS_FORMAT_VERSION;

// chain bits per word of the live segments only, and their total
function [7*CWORDS-1:0] live_nbits(input dummy);
	integer w;
	reg [4:0] sg;
	begin
		live_nbits = 0;
		for (w = 0; w < CWORDS; w = w + 1) begin
			sg = WSEG[5*w +: 5];
			if (sg != 5'd31 && LIVE[sg]) live_nbits[7*w +: 7] = NBITS_MAP[7*w +: 7];
		end
	end
endfunction
localparam [7*CWORDS-1:0] NBITS = live_nbits(1'b0);

function [15:0] live_total(input dummy);
	integer w;
	begin
		live_total = 0;
		for (w = 0; w < CWORDS; w = w + 1) live_total = live_total + NBITS[7*w +: 7];
	end
endfunction
localparam [15:0] CHAIN_BITS = live_total(1'b0);   // recorded in the slot, checked on load

// ---------------------------------------------------------------- regions
function [7:0] rtag(input [4:0] i);
	rtag = (i == 0) ? TAG_CHAIN : (i <= NRGN) ? RTAGS[8*(i-1) +: 8] : 8'hFF;
endfunction

function [24:0] rlen_f(input [4:0] i, input [24:0] reu);
	if (i == 0) rlen_f = CWORDS * 8;
	else if (i > NRGN) rlen_f = 0;
	else if (RTAGS[8*(i-1) +: 8] == `SS_TAG_REU_RAM) rlen_f = reu;
	else rlen_f = RSIZES[25*(i-1) +: 25];
endfunction

wire [NREG-1:0] present = rgn_present | 1'd1;

// slot words needed by a save with the current configuration
reg [22:0] need_words;
always @* begin : need_calc
	integer i;
	reg [24:0] l;
	need_words = 23'd4;                  // w0..w2 + end marker
	for (i = 0; i < NREG; i = i + 1) begin
		l = rlen_f(i[4:0], reu_bytes);
		if (present[i] && l != 0) need_words = need_words + 23'd1 + {1'b0, l[24:3]} + (|l[2:0]);
	end
end

// ---------------------------------------------------------------- CRC-32
// IEEE 802.3 (reflected, 0xEDB88320, init and final xor 0xFFFFFFFF), one
// byte per clock, the 8 bytes of a word low byte first.
function [31:0] crc_byte(input [31:0] c, input [7:0] d);
	integer k;
	reg [31:0] x;
	begin
		x = c ^ {24'd0, d};
		for (k = 0; k < 8; k = k + 1) x = x[0] ? ((x >> 1) ^ 32'hEDB88320) : (x >> 1);
		crc_byte = x;
	end
endfunction

reg  [31:0] crc = 32'hFFFFFFFF;
reg  [63:0] crc_sh = 0;
reg   [3:0] crc_n = 0;
wire        crc_busy = |crc_n;
wire [31:0] crc_val = ~crc;

// ---------------------------------------------------------------- state
localparam [5:0]
	S_IDLE      = 0,
	S_FREEZE    = 1,
	S_CLR       = 2,
	S_NEXT      = 3,
	S_TLV_WR    = 4,
	S_CH_SHIFT  = 5,
	S_DATA_WR   = 6,
	S_RG_RD     = 7,
	S_RG_RDW    = 8,
	S_END_WR    = 9,
	S_PH_WR     = 10,
	S_HDR_WR    = 11,
	S_FINISH    = 12,
	L_FREEZE    = 13,
	L_H0        = 14,
	L_H1        = 15,
	L_H2        = 16,
	V_TLV       = 17,
	V_DATA      = 18,
	V_DONE      = 19,
	R_TLV       = 20,
	R_CH_RD     = 21,
	R_CH_SHIFT  = 22,
	R_RG_RD     = 23,
	R_RG_WR     = 24,
	R_RG_WRW    = 25,
	R_DONE      = 26,
	DDR_WAIT    = 27;

reg   [5:0] state = S_IDLE;
reg   [5:0] ret = S_IDLE;           // state after DDR_WAIT
reg         is_load = 0;
reg  [31:0] counter = 0;            // change counter of the header
reg  [31:0] ld_counter = 0;
reg  [31:0] statesize = 0;          // 32-bit words
reg  [21:0] slot_words = 0;         // words of the slot being loaded (from STATESIZE)
reg  [31:0] crc_exp = 0;
reg  [28:0] base = 0;
reg  [21:0] ptr = 0;                // word offset in the slot
reg   [4:0] ridx = 0;
reg  [24:0] rlen = 0;
reg  [21:0] rwords = 0;             // data words of the current TLV
reg  [21:0] rpos = 0;               // data word of the current TLV
reg   [2:0] bsel = 0;               // byte of the word
reg   [6:0] nb = 0;
reg   [6:0] cnt = 0;
reg  [63:0] wbuf = 0;
reg  [NREG-1:0] seen = 0;
reg   [7:0] settle = 0;
reg  [WDOG_BITS-1:0] wdog = 0;
reg         save_ok = 0;

wire  [7:0] hdr_be = sd_count ? 8'hFF : 8'hF0;
wire [21:0] need = need_words[21:0];

assign busy       = (state != S_IDLE);
assign freeze_req = busy | hold;
assign chain_so   = is_load ? wbuf[0] : chain_si;   // save rotates the chain

// region index of a tag (NREG when unknown)
function [4:0] ridx_of(input [7:0] t);
	integer i;
	begin
		ridx_of = NREG5;
		for (i = NREG - 1; i >= 0; i = i - 1) if (rtag(i[4:0]) == t) ridx_of = i[4:0];
	end
endfunction

// the last word read (DDR_WAIT keeps it in wbuf: read data is valid with ack only)
wire [7:0]  tlv_tag   = wbuf[7:0];
wire [31:0] tlv_len   = wbuf[63:32];
wire [4:0]  tlv_idx   = ridx_of(tlv_tag);
wire [24:0] tlv_exp   = rlen_f(tlv_idx, reu_bytes);
wire [21:0] tlv_words = tlv_len[24:3] + (|tlv_len[2:0]);

always @(posedge clk) begin
	done      <= 0;
	load_done <= 0;
	rgn_req   <= 0;

	// CRC: one byte per clock while crc_n != 0
	if (crc_busy) begin
		crc    <= crc_byte(crc, crc_sh[7:0]);
		crc_sh <= crc_sh >> 8;
		crc_n  <= crc_n - 1'd1;
	end

	// access watchdog: an access that never completes aborts the operation
	if (state == DDR_WAIT || state == S_RG_RDW || state == R_RG_WRW) wdog <= wdog + 1'd1;
	else wdog <= 0;

	case (state)
	S_IDLE: begin
		is_load  <= 0;
		chain_en <= 0;
		loading  <= 0;
		settle   <= 0;
		if (reset) ;
		else if ((save | load) & inhibit) begin
			result_load <= load & ~save;
			result      <= RES_INHIBIT;
			done        <= 1;
		end
		else if (save) begin
			state   <= S_FREEZE;
			base    <= slot_addr;
			counter <= counter + 1'd1;
		end
		else if (load) begin
			state   <= L_FREEZE;
			is_load <= 1;
			base    <= slot_addr;
		end
	end

	// ------------------------------------------------------------ save
	S_FREEZE: begin
		if (inhibit) begin
			result <= RES_INHIBIT;
			state  <= S_FINISH;
		end
		else if (~freeze_ack) settle <= 0;
		else if (settle != SETTLE[7:0]) settle <= settle + 1'd1;
		else if (freeze_forced) begin
			// a forced boundary cannot produce a restorable save: leave the slot alone
			result <= RES_FORCED;
			state  <= S_FINISH;
		end
		else if (need > SLOT_WORDS) begin
			result <= RES_TOOBIG;
			state  <= S_FINISH;
		end
		else begin
			// invalidate the slot first: a torn save leaves a slot the load rejects
			statesize <= {9'd0, need, 1'b0};
			crc       <= 32'hFFFFFFFF;
			ptr       <= 22'd3;
			ridx      <= 0;
			ddr_addr  <= base;
			ddr_wdata <= 64'd0;
			ddr_be    <= hdr_be;
			ddr_we    <= 1;
			ddr_req   <= 1;
			ret       <= S_NEXT;
			state     <= DDR_WAIT;
		end
	end

	S_NEXT: begin
		if (ridx == NREG5) begin
			wbuf  <= 64'd0;               // end marker
			state <= S_END_WR;
		end
		else if (~present[ridx]) ridx <= ridx + 1'd1;
		else if (rlen_f(ridx, reu_bytes) == 0) ridx <= ridx + 1'd1;
		else begin
			rlen   <= rlen_f(ridx, reu_bytes);
			wbuf   <= {7'd0, rlen_f(ridx, reu_bytes), 24'd0, rtag(ridx)};
			rpos   <= 0;
			state  <= S_TLV_WR;
		end
	end

	S_TLV_WR, S_DATA_WR, S_END_WR: if (~crc_busy) begin
		crc_sh    <= wbuf;
		crc_n     <= 4'd8;
		ddr_addr  <= base + ptr;
		ddr_wdata <= wbuf;
		ddr_be    <= 8'hFF;
		ddr_we    <= 1;
		ddr_req   <= 1;
		ptr       <= ptr + 1'd1;
		state     <= DDR_WAIT;
		if (state == S_END_WR) ret <= S_PH_WR;
		else begin
			if (state == S_DATA_WR) rpos <= rpos + 1'd1;
			// next data word, or the next region
			if (state == S_DATA_WR && ({rpos + 1'd1, 3'b000} >= rlen)) begin
				ridx <= ridx + 1'd1;
				ret  <= S_NEXT;
			end
			else ret <= (ridx == 0) ? S_CH_SHIFT : S_RG_RD;
			cnt  <= 0;
			bsel <= 0;
			nb   <= (ridx == 0) ? NBITS[7*((state == S_DATA_WR) ? rpos[CWB-1:0] + 1'd1 : 1'd0) +: 7] : 7'd0;
			wbuf <= 64'd0;
		end
	end

	S_CH_SHIFT: begin
		if (chain_en) begin
			wbuf[cnt[5:0]] <= chain_si;
			cnt <= cnt + 1'd1;
			if (cnt + 1'd1 == nb) begin
				chain_en <= 0;
				state    <= S_DATA_WR;
			end
		end
		else if (nb == 0) state <= S_DATA_WR;
		else chain_en <= 1;
	end

	S_RG_RD: begin
		if ({rpos, bsel} >= rlen) state <= S_DATA_WR;   // padding of the last word stays 0
		else begin
			rgn_tag  <= rtag(ridx);
			rgn_addr <= {rpos[20:0], bsel};
			rgn_we   <= 0;
			rgn_req  <= 1;
			state    <= S_RG_RDW;
		end
	end

	S_RG_RDW: if (rgn_ack) begin
		wbuf[{bsel, 3'b000} +: 8] <= rgn_rdata;
		bsel <= bsel + 1'd1;
		state <= (bsel == 3'd7) ? S_DATA_WR : S_RG_RD;
	end
	else if (&wdog) begin
		result <= RES_TIMEOUT;
		state  <= S_FINISH;
	end

	S_PH_WR: if (~crc_busy) begin
		// payload header: w1 then w2 (CRC is final now)
		ddr_addr  <= base + 29'd1;
		ddr_wdata <= {BUILD_HASH, CHAIN_BITS, FMT_VERSION};
		ddr_be    <= 8'hFF;
		ddr_we    <= 1;
		ddr_req   <= 1;
		last_crc  <= crc_val;
		cnt       <= 0;
		ret       <= S_HDR_WR;
		state     <= DDR_WAIT;
	end

	S_HDR_WR: begin
		ddr_we  <= 1;
		ddr_req <= 1;
		state   <= DDR_WAIT;
		if (cnt == 0) begin
			ddr_addr  <= base + 29'd2;
			ddr_wdata <= {config_mask, last_crc};
			ddr_be    <= 8'hFF;
			cnt       <= 1;
			ret       <= S_HDR_WR;
		end
		else begin
			// publish the slot: Main sees the counter change and copies it
			ddr_addr  <= base;
			ddr_wdata <= {statesize, counter};
			ddr_be    <= hdr_be;
			result    <= RES_OK;
			ret       <= S_FINISH;
		end
	end

	S_FINISH: begin
		chain_en    <= 0;
		loading     <= 0;
		result_load <= is_load;
		done        <= 1;
		state       <= S_IDLE;
	end

	// ------------------------------------------------------------ load
	L_FREEZE: begin
		// a forced boundary is accepted: the load overwrites the machine anyway
		if (~freeze_ack) settle <= 0;
		else if (settle != SETTLE[7:0]) settle <= settle + 1'd1;
		else if (inhibit) begin
			result <= RES_INHIBIT;
			state  <= S_FINISH;
		end
		else begin
			ddr_addr <= base;
			ddr_we   <= 0;
			ddr_req  <= 1;
			ret      <= L_H0;
			state    <= DDR_WAIT;
		end
	end

	L_H0: begin
		// STATESIZE: whole 64-bit words, at least header + payload header +
		// chain + end marker, and the slot must hold it
		if (wbuf[32] || wbuf[63:32] < 32'd2 * (32'd4 + 32'd1 + CWORDS) ||
		    wbuf[63:33] > {9'd0, SLOT_WORDS}) begin
			result <= RES_EMPTY;
			state  <= S_FINISH;
		end
		else begin
			ld_counter <= wbuf[31:0];
			statesize  <= wbuf[63:32];
			slot_words <= wbuf[54:33];
			ddr_addr   <= base + 29'd1;
			ddr_req    <= 1;
			ret        <= L_H1;
			state      <= DDR_WAIT;
		end
	end

	L_H1: begin
		if (wbuf[15:0] != FMT_VERSION || wbuf[31:16] != CHAIN_BITS) begin
			result <= RES_VERSION;
			state  <= S_FINISH;
		end
		else begin
			ddr_addr <= base + 29'd2;
			ddr_req  <= 1;
			ret      <= L_H2;
			state    <= DDR_WAIT;
		end
	end

	L_H2: begin
		if (wbuf[63:32] != config_mask) begin
			result <= RES_CONFIG;
			state  <= S_FINISH;
		end
		else begin
			// verify pass: read the payload, check CRC and TLV structure
			crc_exp  <= wbuf[31:0];
			crc      <= 32'hFFFFFFFF;
			seen     <= 0;
			ptr      <= 22'd3;
			state    <= V_TLV;
		end
	end

	V_TLV: if (~crc_busy) begin
		if (ptr >= slot_words) begin
			result <= RES_CRC;
			state  <= S_FINISH;
		end
		else begin
			ddr_addr <= base + ptr;
			ddr_req  <= 1;
			ptr      <= ptr + 1'd1;
			ret      <= V_DATA;
			rpos     <= 0;
			rwords   <= 0;
			cnt      <= 1;            // first V_DATA visit checks the TLV header
			state    <= DDR_WAIT;
		end
	end

	V_DATA: begin
		if (cnt[0]) begin
			// TLV header just read
			cnt    <= 0;
			crc_sh <= wbuf;
			crc_n  <= 4'd8;
			if (tlv_tag == 8'd0) begin
				if (tlv_len == 0) state <= V_DONE;
				else begin
					result <= RES_CRC;
					state  <= S_FINISH;
				end
			end
			else if (tlv_len[31:25] != 0 || ptr + tlv_words > slot_words ||
			         (tlv_idx != NREG5 && present[tlv_idx] && tlv_len[24:0] != tlv_exp)) begin
				result <= RES_CRC;
				state  <= S_FINISH;
			end
			else begin
				if (tlv_idx != NREG5) seen[tlv_idx] <= 1;
				rwords <= tlv_words;
				if (tlv_words == 0) state <= V_TLV;
			end
		end
		else begin
			if (cnt[1]) begin
				// data word just read: into the CRC
				cnt    <= 0;
				crc_sh <= wbuf;
				crc_n  <= 4'd8;
			end
			if (rpos == rwords) state <= V_TLV;
			else if (~crc_busy & ~cnt[1]) begin
				ddr_addr <= base + ptr;
				ddr_req  <= 1;
				ptr      <= ptr + 1'd1;
				rpos     <= rpos + 1'd1;
				ret      <= V_DATA;
				cnt      <= 2;
				state    <= DDR_WAIT;
			end
		end
	end

	V_DONE: if (~crc_busy) begin
		if (crc_val != crc_exp || (seen & present) != present) begin
			result <= RES_CRC;
			state  <= S_FINISH;
		end
		else begin
			// commit: from here the machine state is overwritten
			last_crc <= crc_val;
			loading  <= 1;
			ptr      <= 22'd3;
			state    <= R_TLV;
		end
	end

	R_TLV: begin
		ddr_addr <= base + ptr;
		ddr_req  <= 1;
		ptr      <= ptr + 1'd1;
		ret      <= R_CH_RD;
		cnt      <= 1;
		state    <= DDR_WAIT;
	end

	R_CH_RD: begin
		if (cnt[0]) begin
			// TLV header
			cnt  <= 0;
			rpos <= 0;
			rlen <= tlv_len[24:0];
			ridx <= tlv_idx;
			rwords <= tlv_words;
			if (tlv_tag == 8'd0) state <= R_DONE;
			else if (tlv_idx == NREG5 || ~present[tlv_idx]) begin
				ptr   <= ptr + tlv_words;   // unknown or absent here: skip it
				state <= R_TLV;
			end
			else if (tlv_words == 0) state <= R_TLV;
			else begin
				ddr_addr <= base + ptr;
				ddr_req  <= 1;
				ptr      <= ptr + 1'd1;
				ret      <= (tlv_idx == 0) ? R_CH_SHIFT : R_RG_WR;
				state    <= DDR_WAIT;
			end
		end
	end

	R_CH_SHIFT: begin
		// wbuf holds the word (DDR_WAIT); shift NBITS[rpos] bits into the chain
		if (chain_en) begin
			wbuf <= wbuf >> 1;
			cnt  <= cnt + 1'd1;
			if (cnt + 1'd1 == nb) chain_en <= 0;
		end
		else if (cnt == nb) begin
			rpos <= rpos + 1'd1;
			if (rpos + 1'd1 == rwords) state <= R_TLV;
			else begin
				ddr_addr <= base + ptr;
				ddr_req  <= 1;
				ptr      <= ptr + 1'd1;
				ret      <= R_CH_SHIFT;
				state    <= DDR_WAIT;
			end
		end
		else chain_en <= 1;
	end

	R_RG_WR: begin
		if ({rpos, bsel} >= rlen) begin
			rpos <= rpos + 1'd1;
			if (rpos + 1'd1 == rwords) state <= R_TLV;
			else begin
				ddr_addr <= base + ptr;
				ddr_req  <= 1;
				ptr      <= ptr + 1'd1;
				ret      <= R_RG_WR;
				state    <= DDR_WAIT;
			end
		end
		else begin
			rgn_tag   <= rtag(ridx);
			rgn_addr  <= {rpos[20:0], bsel};
			rgn_we    <= 1;
			rgn_wdata <= wbuf[{bsel, 3'b000} +: 8];
			rgn_req   <= 1;
			state     <= R_RG_WRW;
		end
	end

	R_RG_WRW: if (rgn_ack) begin
		bsel <= bsel + 1'd1;
		if (bsel == 3'd7) begin
			rpos <= rpos + 1'd1;
			if (rpos + 1'd1 == rwords) state <= R_TLV;
			else begin
				ddr_addr <= base + ptr;
				ddr_req  <= 1;
				ptr      <= ptr + 1'd1;
				ret      <= R_RG_WR;
				state    <= DDR_WAIT;
			end
		end
		else state <= R_RG_WR;
	end
	else if (&wdog) begin
		result <= RES_TIMEOUT;
		state  <= S_FINISH;
	end

	R_DONE: begin
		// the next save counts on from the loaded slot (Main sees a change)
		counter   <= ld_counter;
		loading   <= 0;
		load_done <= 1;
		result    <= RES_OK;
		state     <= S_FINISH;
	end

	// ------------------------------------------------------------ DDR access
	DDR_WAIT: if (ddr_ack) begin
		ddr_req <= 0;
		ddr_we  <= 0;
		state   <= ret;
		if (~ddr_we) begin
			wbuf <= ddr_rdata;
			cnt  <= (ret == R_CH_SHIFT) ? 7'd0 : cnt;
			bsel <= 0;
			if (ret == R_CH_SHIFT) nb <= NBITS[7*rpos[CWB-1:0] +: 7];
		end
	end
	else if (&wdog) begin
		ddr_req <= 0;
		ddr_we  <= 0;
		result  <= RES_TIMEOUT;
		state   <= S_FINISH;
	end

	default: state <= S_IDLE;
	endcase

	if (reset) begin
		state    <= S_IDLE;
		ddr_req  <= 0;
		ddr_we   <= 0;
		chain_en <= 0;
		loading  <= 0;
	end
end

endmodule
