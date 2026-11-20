// Savestate engine for C64_MiSTer (WP A2, fast transport D13).
//
// Ported from the savestate engine of the TurboGrafx16 core (rtl/savestates.vhd,
// based on the NES_MiSTer savestate framework by Robert Peip): same request
// handshake, settle delay, header protocol towards Main (STATESIZE + change
// counter, header cleared first and written last) and forced-boundary rules.
// What changes for the C64:
//   - registers travel on one serial scan chain (rtl/savestate/ss_chain.sv),
//     no 64-bit shadow bus: the CHAIN region keeps the 128-word layout of
//     savestate/map.yaml, word w carries SS_WORD_NBITS[w] chain bits;
//   - memories are TLV regions (tag, length, data): the SDRAM ones (RAM, REU,
//     GeoRAM, cartridge RAM and flash) move in 256-byte transfers of
//     ss_sdram_port, the block RAM ones through a byte bus; unknown tags are
//     skipped on load, optional regions are written only when present;
//   - the REU keeps only its 4 KiB pages written since power on (format 2,
//     tag REU_PAGES): one record word {4096, page index} and the page per
//     written page. A load zeroes the REU pages the slot does not hold that
//     the machine has written: zero is the power-on content (D13);
//   - a payload header (format version, chain length, build hash, config mask,
//     CRC-32 of the payload computed in fabric, 8 bytes per clock); a load
//     first reads the whole slot and checks it, and only then restores
//     anything.
// Every payload word goes through one 64-word FIFO: a save pushes them in
// slot order and writes them to DDR3 in bursts of 32, a load reads the slot
// in bursts of 32 and consumes them in order (verify pass, then restore).
//
// Slot layout (64-bit words from slot_addr, see docs/SAVESTATES.md):
//   w0  {STATESIZE[31:0] (32-bit words incl. this header), change counter[31:0]}
//   w1  {build_hash[31:0], chain_bits[15:0], format_version[15:0]}
//   w2  {config_mask[31:0], crc32[31:0]}   crc over w3 .. end marker
//   w3  TLV: {length in bytes[31:0], 24'd0, tag[7:0]}, then ceil(length/8) words
//       (region byte k is byte k%8 of word k/8, little endian)
//   ... more TLVs, first CHAIN (tag 0x40), then the map.yaml regions in order
//   end {32'd0, 32'd0} (tag 0)
// REU_PAGES data: records of one word {32'd4096, page index[31:0]} and the
// 512 words of the page, page indexes strictly increasing; format 1 slots
// hold the whole REU under REU_RAM and load as well.

`include "c64_savestates.vh"

module savestates #(
	parameter [31:0] BUILD_HASH = 32'd0,
	parameter [31:0] SLOT_BYTES = `SS_SLOT_BYTES,
	parameter        SETTLE     = 100,
	parameter        WDOG_BITS  = 22,      // 2^WDOG_BITS clocks without progress abort the operation
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

	// regions: rgn_tag and rgn_addr (byte offset) place a byte access of a
	// block RAM region (one per rgn_req, rgn_ack ends it) or a 256-byte SDRAM
	// transfer (sd_req)
	output reg  [7:0] rgn_tag = 0,
	output reg [23:0] rgn_addr = 0,
	output reg        rgn_req = 0,
	output reg        rgn_we = 0,
	output reg  [7:0] rgn_wdata = 0,
	input       [7:0] rgn_rdata,
	input             rgn_ack,

	// SDRAM transfers (ss_sdram_port)
	output reg        sd_req = 0,    // 1 clock, only while sd_ready
	output reg        sd_we = 0,
	output reg        sd_zero = 0,   // write zeros
	input             sd_ready,
	input             sd_rvalid,     // a read word
	input      [63:0] sd_rdata,
	input             sd_wtake,      // the port took the FIFO head
	output     [63:0] sd_wdata,

	// REU page map (4 KiB pages written since power on): q of map_addr two clocks later
	output reg [11:0] map_addr = 0,
	input             map_q,
	output reg        map_we = 0,
	output reg        map_wdata = 0,

	// DDR3 Avalon master (ss_ddram_arb)
	output reg [28:0] ddr_addr = 0,
	output reg  [7:0] ddr_burstcnt = 1,
	output reg        ddr_rd = 0,
	output reg        ddr_we = 0,
	output     [63:0] ddr_wdata,
	output reg  [7:0] ddr_be = 8'hFF,
	input             ddr_busy,
	input      [63:0] ddr_rdata,
	input             ddr_rvalid
);

localparam RES_OK       = 4'd0;
localparam RES_FORCED   = 4'd1;  // save: no boundary within the watchdog, abandoned
localparam RES_TOOBIG   = 4'd2;  // save: does not fit in the slot
localparam RES_EMPTY    = 4'd3;  // load: no valid header (empty or torn slot)
localparam RES_VERSION  = 4'd4;  // load: other format version or chain length
localparam RES_CONFIG   = 4'd5;  // load: other hardware configuration
localparam RES_CRC      = 4'd6;  // load: CRC or TLV structure error, missing region
localparam RES_INHIBIT  = 4'd7;  // request refused or cancelled before the first write
localparam RES_TIMEOUT  = 4'd8;  // DDR, SDRAM or region access stuck

localparam [7:0] TAG_CHAIN = 8'h40;
localparam [7:0] TAG_PAGES = `SS_TAG_REU_PAGES;
localparam       NRGN      = `SS_REGION_COUNT;
localparam       NREG      = NRGN + 1;          // index 0 = CHAIN, 1 + r = map region r
localparam [4:0] NREG5     = NREG;
localparam [4:0] REU_IDX   = 1 + `SS_RGN_REU_RAM;
localparam       CWORDS    = `SS_CHAIN_WORDS;   // 64-bit words of the CHAIN region
localparam       CWB       = $clog2(CWORDS);
localparam [7*CWORDS-1:0] NBITS_MAP = `SS_WORD_NBITS;
localparam [5*CWORDS-1:0] WSEG      = `SS_WORD_SEG;
localparam [8*NRGN-1:0]   RTAGS     = `SS_REGION_TAGS;
localparam [25*NRGN-1:0]  RSIZES    = `SS_REGION_SIZES;
localparam [21:0] SLOT_WORDS = SLOT_BYTES[24:3];
localparam [15:0] FMT_VERSION = `SS_FORMAT_VERSION;
localparam [31:0] PAGE_BYTES  = `SS_REU_PAGE_BYTES;   // 4096: 16 transfers, 512 words, 513 with its record word

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

// SDRAM regions: 256-byte transfers of ss_sdram_port
function is_sd(input [7:0] t);
	is_sd = (t == `SS_TAG_RAM) || (t == `SS_TAG_CART_RAM) || (t == `SS_TAG_CART_FLASH) ||
	        (t == `SS_TAG_GEORAM) || (t == `SS_TAG_REU_RAM);
endfunction

// region index of a tag (NREG when unknown); REU_PAGES is the REU region
function [4:0] ridx_of(input [7:0] t);
	integer i;
	begin
		ridx_of = NREG5;
		for (i = NREG - 1; i >= 0; i = i - 1) if (rtag(i[4:0]) == t) ridx_of = i[4:0];
		if (t == TAG_PAGES) ridx_of = REU_IDX;
	end
endfunction

wire [NREG-1:0] present = rgn_present | 1'd1;

// slot words a save of the current configuration may need: the REU counts
// as fully written (one record word per page)
reg [22:0] need_words;
always @* begin : need_calc
	integer i;
	reg [24:0] l;
	need_words = 23'd4;                  // w0..w2 + end marker
	for (i = 0; i < NREG; i = i + 1) begin
		l = rlen_f(i[4:0], reu_bytes);
		if (present[i] && l != 0)
			need_words = need_words + 23'd1 + {1'b0, l[24:3]} + (|l[2:0]) +
			             ((i == REU_IDX) ? {10'd0, l[24:12]} : 23'd0);
	end
end

// ---------------------------------------------------------------- CRC-32
// IEEE 802.3 (reflected, 0xEDB88320, init and final xor 0xFFFFFFFF) of the
// payload bytes in slot order; a 64-bit word is its 8 bytes low byte first,
// i.e. its bits from 0 to 63: one word per clock
function [31:0] crc64(input [31:0] c, input [63:0] d);
	integer k;
	reg [31:0] x;
	begin
		x = c;
		for (k = 0; k < 64; k = k + 1) x = (x[0] ^ d[k]) ? ((x >> 1) ^ 32'hEDB88320) : (x >> 1);
		crc64 = x;
	end
endfunction

reg  [31:0] crc = 32'hFFFFFFFF;
wire [31:0] crc_val = ~crc;

// ---------------------------------------------------------------- state
localparam [5:0]
	S_IDLE      = 0,
	S_FREEZE    = 1,
	S_W0        = 2,
	S_NEXT      = 3,
	S_CH_SHIFT  = 4,
	S_RG_RD     = 5,
	S_RG_RDW    = 6,
	S_SD        = 7,     // SDRAM chunk, save and load
	S_RU_SCAN   = 8,
	S_RU_PAGE   = 9,
	S_FLUSH     = 10,
	S_PH        = 11,
	S_FINISH    = 12,
	L_FREEZE    = 13,
	L_H0        = 14,
	L_H1        = 15,
	L_H2        = 16,
	V_TLV       = 17,
	V_HDR       = 18,
	V_DATA      = 19,
	V_REC       = 20,
	V_DONE      = 21,
	V_STOP      = 22,
	R_TLV       = 23,
	R_POP       = 24,
	R_HDR       = 25,
	R_CH_SHIFT  = 26,
	R_RG_WR     = 27,
	R_RG_WRW    = 28,
	R_SKIP      = 29,
	R_MAP       = 30,
	R_RU_REC    = 31,
	R_RU_GAP    = 32,
	R_RU_GAPQ   = 33,
	R_DONE      = 34;

reg   [5:0] state = S_IDLE;
reg   [5:0] ret = S_IDLE;           // next state after S_SD, V_DATA, R_POP
reg         is_load = 0;
reg         vpass = 0;              // verify pass: the popped words go into the CRC
reg  [31:0] counter = 0;            // change counter of the header
reg  [31:0] ld_counter = 0;
reg  [21:0] slot_words = 0;         // words of the slot being loaded (from STATESIZE)
reg  [21:0] vend = 0;               // word after the end marker (verified)
reg  [31:0] crc_exp = 0;
reg  [28:0] base = 0;
reg  [21:0] vptr = 0;               // load: offset of the next word consumed
reg   [4:0] ridx = 0;
reg  [24:0] rlen = 0;
reg  [21:0] rwords = 0;             // data words of the current TLV (load) or record
reg  [21:0] rpos = 0;               // data word of the current TLV
reg  [21:0] twords = 0;             // REU_PAGES: words of the TLV left
reg   [2:0] bsel = 0;               // byte of the word
reg   [6:0] nb = 0;
reg   [6:0] cnt = 0;
reg  [63:0] wbuf = 0;
reg  [NREG-1:0] seen = 0;
reg   [7:0] settle = 0;
reg  [WDOG_BITS-1:0] wdog = 0;
reg         hstep = 0;              // header word in flight (S_PH)
reg   [1:0] hnum = 0;               // header word of S_PH: w1, w2, w0

// SDRAM transfers of the current chunk
reg  [23:0] x_off = 0;              // byte offset of the next transfer
reg  [16:0] x_left = 0;             // transfers left to start
reg         x_fly = 0;              // a transfer is in flight
reg         x_busy = 0;             // ... and the port has taken it

// REU pages
reg  [12:0] npages = 0;             // pages of the REU region
reg  [12:0] pg = 0;                 // page scanned / next page not handled
reg  [12:0] pcnt = 0;               // written pages (save)
reg  [12:0] prev = 0;               // verify: lowest allowed page index of the next record
reg         pv1 = 0, pv2 = 0;       // S_RU_SCAN: map_q of a page in one / two clocks
reg         tail = 0;               // restore: no record left, zero to the end of the REU

wire  [7:0] hdr_be = sd_count ? 8'hFF : 8'hF0;
wire [21:0] need = need_words[21:0];

assign busy       = (state != S_IDLE);
assign freeze_req = busy | hold;
assign chain_so   = is_load ? wbuf[0] : chain_si;   // save rotates the chain

// the TLV header in wbuf
wire  [7:0] tlv_tag   = wbuf[7:0];
wire [31:0] tlv_len   = wbuf[63:32];
wire  [4:0] tlv_idx   = ridx_of(tlv_tag);
wire [21:0] tlv_words = tlv_len[24:3] + (|tlv_len[2:0]);

// ---------------------------------------------------------------- FIFO
// 64 words, show-ahead (MLAB, asynchronous read). Save: the engine and the
// SDRAM read words push, the DDR3 write bursts pop. Load: the DDR3 read
// beats push, the engine and the SDRAM write words pop.
(* ramstyle = "MLAB, no_rw_check" *) reg [63:0] fmem [0:63];
reg   [5:0] f_wp = 0, f_rp = 0;
reg   [6:0] f_cnt = 0;
reg         f_clr = 0;
reg         p_push = 0;             // engine push of p_word (registered)
reg  [63:0] p_word = 0;
wire [63:0] f_head = fmem[f_rp];
wire  [7:0] f_used = f_cnt + p_push;   // words in, or being pushed by the engine
wire        f_have = (f_cnt != 0);
wire        f_room = ~p_push & (f_cnt < 7'd63);

reg         m_single = 0;           // the DDR3 write is a header word (hword)
reg         m_srd = 0;              // header read outstanding
reg   [5:0] m_beats = 0;            // write beats left
reg   [6:0] m_out = 0;              // read beats outstanding into the FIFO
reg  [63:0] hword = 0;              // header word to write / read
reg         s_go = 0, s_we = 0;     // header access request
reg   [1:0] s_word = 0;
reg         s_ack = 0;
reg         w_run = 0, w_flush = 0; // save: write the FIFO to base + w_ptr
reg  [21:0] w_ptr = 0;
reg         r_run = 0;              // load: read base + r_ptr .. r_end into the FIFO
reg  [21:0] r_ptr = 0, r_end = 0;

// engine pops: one word per clock in the consuming states
wire        rec_ok = (twords >= 22'd513);
wire        c_pop  = f_have & (
	(state == V_TLV && vptr < slot_words) |
	(state == V_DATA && rpos != rwords) |
	(state == V_REC && rec_ok) |
	(state == R_POP));

wire        r_beat = ddr_rvalid & ~m_srd;
wire        f_push = is_load ? r_beat : (p_push | sd_rvalid);
wire [63:0] f_din  = is_load ? ddr_rdata : (sd_rvalid ? sd_rdata : p_word);
wire        w_beat = ddr_we & ~ddr_busy & ~m_single;
wire        f_pop  = is_load ? (c_pop | sd_wtake) : w_beat;

assign ddr_wdata = m_single ? hword : f_head;
assign sd_wdata  = f_head;

always @(posedge clk) if (f_push) fmem[f_wp] <= f_din;

always @(posedge clk) begin
	if (f_clr) begin
		f_wp  <= 0;
		f_rp  <= 0;
		f_cnt <= 0;
	end
	else begin
		f_wp  <= f_wp + f_push;
		f_rp  <= f_rp + f_pop;
		f_cnt <= f_cnt + f_push - f_pop;
	end
end

// DDR3 master: header words, write bursts out of the FIFO, read bursts into it
wire        m_idle  = ~ddr_we & ~ddr_rd & ~m_srd;
wire [21:0] r_left  = r_end - r_ptr;
wire  [6:0] r_n     = (r_left >= 22'd32) ? 7'd32 : r_left[6:0];
wire        r_issue = m_idle & ~s_go & r_run & (r_left != 0) & ({1'b0, f_cnt} + m_out + r_n <= 8'd64);
wire  [6:0] w_n     = (f_cnt >= 7'd32) ? 7'd32 : f_cnt;
wire        w_issue = m_idle & ~s_go & w_run & (f_cnt >= 7'd32 || (w_flush && f_cnt != 0));
wire        m_quiet = m_idle & (m_out == 0) & ~s_go;   // nothing in flight on the DDR3 port

always @(posedge clk) begin
	done      <= 0;
	load_done <= 0;
	rgn_req   <= 0;
	sd_req    <= 0;
	map_we    <= 0;
	p_push    <= 0;
	f_clr     <= 0;
	s_ack     <= 0;

	// CRC: a save the pushed words, a verify the popped words
	if (is_load ? (vpass & c_pop) : f_push) crc <= crc64(crc, is_load ? f_head : f_din);

	// ------------------------------------------------------------ DDR3 master
	if (ddr_we & ~ddr_busy) begin
		m_beats <= m_beats - 1'd1;
		if (m_beats == 6'd1) begin
			ddr_we <= 0;
			if (m_single) begin
				m_single <= 0;
				s_ack    <= 1;
			end
		end
	end
	if (ddr_rd & ~ddr_busy) ddr_rd <= 0;
	if (ddr_rvalid & m_srd) begin
		m_srd <= 0;
		hword <= ddr_rdata;
		s_ack <= 1;
	end
	m_out <= m_out + (r_issue ? r_n : 7'd0) - (r_beat ? 7'd1 : 7'd0);
	if (m_idle) begin
		if (s_go) begin
			s_go         <= 0;
			ddr_addr     <= base + s_word;
			ddr_burstcnt <= 8'd1;
			ddr_be       <= (s_word == 2'd0) ? hdr_be : 8'hFF;
			if (s_we) begin
				ddr_we   <= 1;
				m_single <= 1;
				m_beats  <= 6'd1;
			end
			else begin
				ddr_rd <= 1;
				m_srd  <= 1;
			end
		end
		else if (w_issue) begin
			ddr_addr     <= base + w_ptr;
			ddr_burstcnt <= {1'b0, w_n};
			ddr_be       <= 8'hFF;
			ddr_we       <= 1;
			m_beats      <= w_n[5:0];
			w_ptr        <= w_ptr + w_n;
		end
		else if (r_issue) begin
			ddr_addr     <= base + r_ptr;
			ddr_burstcnt <= {1'b0, r_n};
			ddr_be       <= 8'hFF;
			ddr_rd       <= 1;
			r_ptr        <= r_ptr + r_n;
		end
	end

	// ------------------------------------------------------------ SDRAM transfer in flight
	if (x_fly & ~sd_req) begin
		if (~sd_ready) x_busy <= 1;
		else if (x_busy) begin
			x_fly  <= 0;
			x_busy <= 0;
		end
	end

	// ------------------------------------------------------------ watchdog
	// any word, header, byte, chain bit, map write or transfer is progress; the
	// map scans are bounded loops; waiting for the freeze has its own watchdog
	// (ss_freeze)
	if (state == S_IDLE || state == S_FREEZE || state == L_FREEZE || state == S_RU_SCAN ||
	    (state == S_RU_PAGE && !(cnt[1] && map_q)) || state == R_RU_GAP || state == R_RU_GAPQ ||
	    f_push || f_pop || s_ack || rgn_ack || chain_en || (x_fly & x_busy & sd_ready) || map_we) wdog <= 0;
	else wdog <= wdog + 1'd1;

	case (state)
	S_IDLE: begin
		is_load  <= 0;
		vpass    <= 0;
		chain_en <= 0;
		loading  <= 0;
		settle   <= 0;
		sd_zero  <= 0;
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
			hword  <= 64'd0;
			s_word <= 2'd0;
			s_we   <= 1;
			s_go   <= 1;
			npages <= reu_bytes[24:12];
			state  <= S_W0;
		end
	end

	S_W0: if (s_ack) begin
		crc   <= 32'hFFFFFFFF;
		w_ptr <= 22'd3;
		w_run <= 1;
		ridx  <= 0;
		state <= S_NEXT;
	end

	// next present region: its TLV header into the FIFO
	S_NEXT: if (f_room) begin
		rpos <= 0;
		bsel <= 0;
		cnt  <= 0;
		wbuf <= 64'd0;
		if (ridx == NREG5) begin
			p_word <= 64'd0;                  // end marker
			p_push <= 1;
			state  <= S_FLUSH;
		end
		else if (~present[ridx] || rlen_f(ridx, reu_bytes) == 0) ridx <= ridx + 1'd1;
		else begin
			rlen    <= rlen_f(ridx, reu_bytes);
			rgn_tag <= rtag(ridx);
			if (ridx == REU_IDX) begin
				// count the written pages first: the TLV length precedes them
				pg    <= 0;
				pcnt  <= 0;
				pv1   <= 0;
				pv2   <= 0;
				state <= S_RU_SCAN;
			end
			else begin
				p_word <= {7'd0, rlen_f(ridx, reu_bytes), 24'd0, rtag(ridx)};
				p_push <= 1;
				if (ridx == 0) begin
					nb    <= NBITS[6:0];
					state <= S_CH_SHIFT;
				end
				else if (is_sd(rtag(ridx))) begin
					x_off  <= 0;
					x_left <= rlen_f(ridx, reu_bytes) >> 8;
					ridx   <= ridx + 1'd1;
					ret    <= S_NEXT;
					state  <= S_SD;
				end
				else state <= S_RG_RD;
			end
		end
	end

	S_CH_SHIFT: begin
		if (chain_en) begin
			wbuf[cnt[5:0]] <= chain_si;
			cnt <= cnt + 1'd1;
			if (cnt + 1'd1 == nb) chain_en <= 0;
		end
		else if (cnt == nb) begin
			if (f_room) begin
				p_word <= wbuf;
				p_push <= 1;
				wbuf   <= 64'd0;
				cnt    <= 0;
				rpos   <= rpos + 1'd1;
				nb     <= NBITS[7*(rpos[CWB-1:0] + 1'd1) +: 7];
				if (rpos + 1'd1 == CWORDS) begin
					ridx  <= ridx + 1'd1;
					state <= S_NEXT;
				end
			end
		end
		else chain_en <= 1;
	end

	// block RAM regions: 8 byte reads per word (cnt[0]: the word is complete)
	S_RG_RD: begin
		if (cnt[0] || {rpos, bsel} >= rlen) begin
			if (f_room) begin
				p_word <= wbuf;                   // the padding of a last partial word stays 0
				p_push <= 1;
				wbuf   <= 64'd0;
				bsel   <= 0;
				cnt    <= 0;
				rpos   <= rpos + 1'd1;
				if ({rpos + 1'd1, 3'b000} >= rlen) begin
					ridx  <= ridx + 1'd1;
					state <= S_NEXT;
				end
			end
		end
		else begin
			rgn_addr <= {rpos[20:0], bsel};
			rgn_we   <= 0;
			rgn_req  <= 1;
			state    <= S_RG_RDW;
		end
	end

	S_RG_RDW: if (rgn_ack) begin
		wbuf[{bsel, 3'b000} +: 8] <= rgn_rdata;
		bsel <= bsel + 1'd1;
		if (bsel == 3'd7) cnt <= 1;
		state <= S_RG_RD;
	end

	// SDRAM chunk: x_left transfers from x_off. Save: read, with room for its
	// 32 words; load: write the 32 words of the FIFO, or zeros
	S_SD: if (~x_fly & ~sd_req) begin
		if (x_left == 0) state <= ret;
		// a word the port takes or gives on this clock counts already
		else if (sd_ready && (is_load ? (sd_zero || f_cnt >= 7'd32 + sd_wtake) : (f_used + sd_rvalid <= 8'd32))) begin
			rgn_addr <= x_off;
			sd_req   <= 1;
			sd_we    <= is_load;
			x_fly    <= 1;
			x_off    <= x_off + 24'd256;
			x_left   <= x_left - 1'd1;
		end
	end

	// REU: count the pages written since power on
	S_RU_SCAN: begin
		map_addr <= pg[11:0];
		pv1      <= (pg != npages);
		pv2      <= pv1;
		if (pv2) pcnt <= pcnt + map_q;
		if (pg != npages) pg <= pg + 1'd1;
		else if (~pv1 & ~pv2 & f_room) begin
			// TLV: a record of 4104 bytes per written page
			p_word <= {({6'd0, pcnt, 12'd0} + {16'd0, pcnt, 3'd0}), 24'd0, TAG_PAGES};
			p_push <= 1;
			pg     <= 0;
			cnt    <= 0;
			state  <= S_RU_PAGE;
		end
	end

	// REU: a record and its 16 transfers per written page
	S_RU_PAGE: begin
		if (pg == npages) begin
			ridx  <= ridx + 1'd1;
			state <= S_NEXT;
		end
		else if (cnt[1:0] == 2'd0) begin
			map_addr <= pg[11:0];
			cnt      <= 1;
		end
		else if (cnt[1:0] == 2'd1) cnt <= 2;
		else if (~map_q) begin
			cnt <= 0;
			pg  <= pg + 1'd1;
		end
		else if (f_room) begin
			cnt    <= 0;
			p_word <= {PAGE_BYTES, 19'd0, pg};
			p_push <= 1;
			x_off  <= {pg[11:0], 12'd0};
			x_left <= 17'd16;
			pg     <= pg + 1'd1;
			ret    <= S_RU_PAGE;
			state  <= S_SD;
		end
	end

	// all words pushed: write what is left, then the payload header
	S_FLUSH: begin
		w_flush <= 1;
		if (~p_push && f_cnt == 0 && m_quiet) begin
			w_run   <= 0;
			w_flush <= 0;
			hstep   <= 0;
			hnum    <= 0;
			state   <= S_PH;
		end
	end

	// payload header w1, w2 (the CRC is final), then w0 (publishes the slot)
	S_PH: begin
		if (~hstep) begin
			if (~s_go & m_idle) begin
				hstep <= 1;
				s_we  <= 1;
				s_go  <= 1;
				case (hnum)
				2'd0: begin
					s_word   <= 2'd1;
					hword    <= {BUILD_HASH, CHAIN_BITS, FMT_VERSION};
					last_crc <= crc_val;
				end
				2'd1: begin
					s_word <= 2'd2;
					hword  <= {config_mask, last_crc};
				end
				default: begin
					// Main sees the counter change and copies STATESIZE 32-bit words
					s_word <= 2'd0;
					hword  <= {9'd0, w_ptr, 1'b0, counter};
				end
				endcase
			end
		end
		else if (s_ack) begin
			hstep <= 0;
			hnum  <= hnum + 1'd1;
			if (hnum == 2'd2) begin
				result <= RES_OK;
				state  <= S_FINISH;
			end
		end
	end

	S_FINISH: begin
		chain_en <= 0;
		w_run    <= 0;
		r_run    <= 0;
		if (m_quiet & ~x_fly & ~sd_req) begin
			f_clr       <= 1;
			loading     <= 0;
			result_load <= is_load;
			done        <= 1;
			state       <= S_IDLE;
		end
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
			s_word <= 2'd0;
			s_we   <= 0;
			s_go   <= 1;
			npages <= reu_bytes[24:12];
			state  <= L_H0;
		end
	end

	L_H0: if (s_ack) begin
		// STATESIZE: whole 64-bit words, at least header + payload header +
		// chain + end marker, and the slot must hold it
		if (hword[32] || hword[63:32] < 32'd2 * (32'd4 + 32'd1 + CWORDS) ||
		    hword[63:33] > {9'd0, SLOT_WORDS}) begin
			result <= RES_EMPTY;
			state  <= S_FINISH;
		end
		else begin
			ld_counter <= hword[31:0];
			slot_words <= hword[54:33];
			s_word     <= 2'd1;
			s_go       <= 1;
			state      <= L_H1;
		end
	end

	L_H1: if (s_ack) begin
		// format 1 (the whole REU under REU_RAM) loads as well
		if ((hword[15:0] != FMT_VERSION && hword[15:0] != 16'd1) || hword[31:16] != CHAIN_BITS) begin
			result <= RES_VERSION;
			state  <= S_FINISH;
		end
		else begin
			s_word <= 2'd2;
			s_go   <= 1;
			state  <= L_H2;
		end
	end

	L_H2: if (s_ack) begin
		if (hword[63:32] != config_mask) begin
			result <= RES_CONFIG;
			state  <= S_FINISH;
		end
		else begin
			// verify pass: read the payload, check CRC and TLV structure
			crc_exp <= hword[31:0];
			crc     <= 32'hFFFFFFFF;
			seen    <= 0;
			vpass   <= 1;
			vptr    <= 22'd3;
			r_ptr   <= 22'd3;
			r_end   <= slot_words;
			r_run   <= 1;
			state   <= V_TLV;
		end
	end

	// a TLV header (popped, c_pop), checked in V_HDR
	V_TLV: begin
		if (vptr >= slot_words) begin
			result <= RES_CRC;
			state  <= V_STOP;
		end
		else if (f_have) begin
			wbuf  <= f_head;
			vptr  <= vptr + 1'd1;
			state <= V_HDR;
		end
	end

	V_HDR: begin
		rpos <= 0;
		ret  <= V_TLV;
		if (tlv_tag == 8'd0) begin
			if (tlv_len == 0) state <= V_DONE;
			else begin
				result <= RES_CRC;
				state  <= V_STOP;
			end
		end
		else if (tlv_len[31:25] != 0 || {1'b0, vptr} + {1'b0, tlv_words} > {1'b0, slot_words}) begin
			result <= RES_CRC;
			state  <= V_STOP;
		end
		else if (tlv_tag == TAG_PAGES && present[REU_IDX]) begin
			// records of 513 words, page indexes strictly increasing below npages
			if (tlv_len[2:0] != 0) begin
				result <= RES_CRC;
				state  <= V_STOP;
			end
			else begin
				seen[REU_IDX] <= 1;
				twords <= tlv_len[24:3];
				prev   <= 0;
				state  <= V_REC;
			end
		end
		else if (tlv_tag != TAG_PAGES && tlv_idx != NREG5 && present[tlv_idx] &&
		         tlv_len[24:0] != rlen_f(tlv_idx, reu_bytes)) begin
			result <= RES_CRC;
			state  <= V_STOP;
		end
		else begin
			if (tlv_idx != NREG5 && present[tlv_idx]) seen[tlv_idx] <= 1;
			rwords <= tlv_words;
			state  <= V_DATA;
		end
	end

	// data words into the CRC (popped while rpos != rwords)
	V_DATA: begin
		if (rpos == rwords) state <= ret;
		else if (f_have) begin
			rpos <= rpos + 1'd1;
			vptr <= vptr + 1'd1;
		end
	end

	// REU_PAGES: a record word {4096, page}, then the 512 words of the page
	V_REC: begin
		if (twords == 0) state <= V_TLV;
		else if (~rec_ok) begin
			result <= RES_CRC;
			state  <= V_STOP;
		end
		else if (f_have) begin
			vptr   <= vptr + 1'd1;
			twords <= twords - 22'd513;
			if (f_head[63:32] != PAGE_BYTES || f_head[31:13] != 0 || f_head[12:0] >= npages || f_head[12:0] < prev) begin
				result <= RES_CRC;
				state  <= V_STOP;
			end
			else begin
				prev   <= f_head[12:0] + 1'd1;
				rwords <= 22'd512;
				rpos   <= 0;
				ret    <= V_REC;
				state  <= V_DATA;
			end
		end
	end

	V_DONE: begin
		if (crc_val != crc_exp || (seen & present) != present) begin
			result <= RES_CRC;
			state  <= V_STOP;
		end
		else begin
			// commit: from here the machine state is overwritten
			last_crc <= crc_val;
			vend     <= vptr;
			vpass    <= 0;
			state    <= V_STOP;
		end
	end

	// stop the reader; refused (vpass): finish, verified: read it again
	V_STOP: begin
		r_run <= 0;
		if (m_quiet & ~r_run) begin
			f_clr <= 1;
			if (vpass) state <= S_FINISH;
			else begin
				loading <= 1;
				vptr    <= 22'd3;
				r_ptr   <= 22'd3;
				r_end   <= vend;
				r_run   <= 1;
				state   <= R_TLV;
			end
		end
	end

	R_TLV: begin
		rpos  <= 0;
		bsel  <= 0;
		ret   <= R_HDR;
		state <= R_POP;
	end

	// the next word into wbuf (c_pop), then ret
	R_POP: if (f_have) begin
		wbuf  <= f_head;
		vptr  <= vptr + 1'd1;
		cnt   <= 0;
		nb    <= NBITS[7*rpos[CWB-1:0] +: 7];
		state <= ret;
	end

	R_HDR: begin
		rlen    <= tlv_len[24:0];
		rwords  <= tlv_words;
		ridx    <= tlv_idx;
		rgn_tag <= (tlv_tag == TAG_PAGES) ? `SS_TAG_REU_RAM : tlv_tag;
		if (tlv_tag == 8'd0) state <= R_DONE;
		else if (tlv_idx == NREG5 || ~present[tlv_idx]) state <= R_SKIP;   // unknown or absent here
		else if (tlv_tag == TAG_PAGES) begin
			twords <= tlv_len[24:3];
			pg     <= 0;
			tail   <= 0;
			state  <= R_RU_REC;
		end
		else if (tlv_words == 0) state <= R_TLV;
		else if (tlv_idx == 0) begin
			ret   <= R_CH_SHIFT;
			state <= R_POP;
		end
		else if (is_sd(tlv_tag)) begin
			// a whole region; a format 1 REU marks every page written
			x_off   <= 0;
			x_left  <= tlv_len[24:8];
			sd_zero <= 0;
			pg      <= 0;
			ret     <= R_TLV;
			state   <= (tlv_tag == `SS_TAG_REU_RAM) ? R_MAP : S_SD;
		end
		else begin
			ret   <= R_RG_WR;
			state <= R_POP;
		end
	end

	R_SKIP: begin
		if (rpos == rwords) state <= R_TLV;
		else begin
			rpos  <= rpos + 1'd1;
			ret   <= R_SKIP;
			state <= R_POP;
		end
	end

	R_CH_SHIFT: begin
		// wbuf holds the word; shift NBITS[rpos] bits into the chain
		if (chain_en) begin
			wbuf <= wbuf >> 1;
			cnt  <= cnt + 1'd1;
			if (cnt + 1'd1 == nb) chain_en <= 0;
		end
		else if (cnt == nb) begin
			rpos <= rpos + 1'd1;
			if (rpos + 1'd1 == rwords) state <= R_TLV;
			else begin
				ret   <= R_CH_SHIFT;
				state <= R_POP;
			end
		end
		else chain_en <= 1;
	end

	// block RAM regions: 8 byte writes per word (cnt[0]: the word is done)
	R_RG_WR: begin
		if (cnt[0] || {rpos, bsel} >= rlen) begin
			bsel <= 0;
			cnt  <= 0;
			rpos <= rpos + 1'd1;
			if (rpos + 1'd1 == rwords) state <= R_TLV;
			else begin
				ret   <= R_RG_WR;
				state <= R_POP;
			end
		end
		else begin
			rgn_addr  <= {rpos[20:0], bsel};
			rgn_we    <= 1;
			rgn_wdata <= wbuf[{bsel, 3'b000} +: 8];
			rgn_req   <= 1;
			state     <= R_RG_WRW;
		end
	end

	R_RG_WRW: if (rgn_ack) begin
		bsel <= bsel + 1'd1;
		if (bsel == 3'd7) cnt <= 1;
		state <= R_RG_WR;
	end

	// format 1 REU: every page counts as written, then the whole region
	R_MAP: begin
		if (pg == npages) state <= S_SD;
		else begin
			map_addr  <= pg[11:0];
			map_wdata <= 1;
			map_we    <= 1;
			pg        <= pg + 1'd1;
		end
	end

	// REU_PAGES: before each record, and after the last one to the end of the
	// REU, zero the pages the slot does not hold that the machine has written
	R_RU_REC: begin
		if (twords == 0) begin
			tail  <= 1;
			state <= R_RU_GAP;
		end
		else begin
			twords <= twords - 22'd513;
			ret    <= R_RU_GAP;
			state  <= R_POP;               // the record word: its page in wbuf[12:0]
		end
	end

	R_RU_GAP: begin
		if (pg != (tail ? npages : wbuf[12:0])) begin
			map_addr <= pg[11:0];
			cnt      <= 0;
			state    <= R_RU_GAPQ;
		end
		else if (tail) state <= R_TLV;
		else begin
			// the record page: 16 transfers out of the FIFO, written since power on
			map_addr  <= pg[11:0];
			map_wdata <= 1;
			map_we    <= 1;
			x_off     <= {pg[11:0], 12'd0};
			x_left    <= 17'd16;
			sd_zero   <= 0;
			pg        <= pg + 1'd1;
			ret       <= R_RU_REC;
			state     <= S_SD;
		end
	end

	R_RU_GAPQ: begin
		if (~cnt[0]) cnt <= 1;             // map_q of map_addr on the next clock
		else begin
			cnt <= 0;
			pg  <= pg + 1'd1;
			if (map_q) begin
				// written since power on, not in the slot: back to zero
				map_wdata <= 0;
				map_we    <= 1;
				x_off     <= {pg[11:0], 12'd0};
				x_left    <= 17'd16;
				sd_zero   <= 1;
				ret       <= R_RU_GAP;
				state     <= S_SD;
			end
			else state <= R_RU_GAP;
		end
	end

	R_DONE: begin
		// the next save counts on from the loaded slot (Main sees a change)
		counter   <= ld_counter;
		load_done <= 1;
		result    <= RES_OK;
		state     <= S_FINISH;
	end

	default: state <= S_IDLE;
	endcase

	if (&wdog) begin
		ddr_rd   <= 0;
		ddr_we   <= 0;
		m_srd    <= 0;
		m_single <= 0;
		m_out    <= 0;
		s_go     <= 0;
		x_fly    <= 0;
		x_busy   <= 0;
		result   <= RES_TIMEOUT;
		state    <= S_FINISH;
	end

	if (reset) begin
		state    <= S_IDLE;
		ddr_rd   <= 0;
		ddr_we   <= 0;
		m_srd    <= 0;
		m_single <= 0;
		m_out    <= 0;
		s_go     <= 0;
		w_run    <= 0;
		r_run    <= 0;
		x_fly    <= 0;
		x_busy   <= 0;
		chain_en <= 0;
		loading  <= 0;
		f_clr    <= 1;
	end
end

endmodule
