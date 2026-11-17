// C64_MiSTer whole-core Verilator harness.
//
//   Vemu boot [--max-frames N] [--shot file.ppm] [--status-hex H]
//       power on, run until "READY." is on the screen (or N frames), dump the
//       last complete frame as PPM.
//
//   Vemu pausetest [--t0 C] [--hold F] [--after C] [--trigger key|joy]
//                  [--max-frames N] [--prg file]
//       two instances of the core in lockstep. A runs continuously, B gets a
//       user pause (Pause/Break key strobe or the "Pause" pad button) at
//       clk_sys cycle C after READY, released F video frames (PAL 628992,
//       NTSC 6567R8 547040 clk_sys each) after the machine actually stopped.
//       Every clk_sys cycle in which the machine is running contributes one sample
//       of C64-visible state (CPU address/data/we, RAM strobes, VIC RGB, CIA TOD
//       source, cassette lines, audio mix). The two sample streams must be
//       identical: B is A shifted by the paused time. Compares --after C
//       samples after the resume.
//
// Common: --prg file  loads a PRG through ioctl (index 1) once READY is seen
//         (Reset & Run PRG is the default, so it runs).
//         --tap file  loads a TAP (index 0xC1) once READY is seen.
//         --disk file.d64|.g64|.d81  mounts the image on drive 8 at power on
//                     (full model only; a D81 makes it a 1581, its sectors
//                     are served over the SD block interface); the READY
//                     snapshot is kept per disk.
//         --trace-drive  boot mode: prints drive 8 LED and head moves (and
//                     the SD sector transfers of a D81).
//         --type "TEXT\n" types text on the keyboard once READY (and after PRG).
//         --status 14,57  status bits set at power on (14: Standard C64 KERNAL,
//                     DolphinDOS, the default, has no tape routines).
//         --status-ready 96  status bits set once READY is reached (the cached
//                     READY snapshot is reused; 96: Tape Auto Unload off).
//         --kbuf "LOAD\r"  puts the text in the KERNAL keyboard buffer (instant).
//         --ram-prg file  puts a PRG straight into RAM after READY (no ioctl, no
//                     reset; BASIC end pointers set for $0801), then --kbuf 'RUN\r'.
//         --run-cycles C  extra clk_sys cycles to run after READY in boot mode.
//         --no-cache  do not reuse/write ready.state, the READY snapshot.
//         --opl, --clk50  also run clk48 for OPL3 / CLK_50M, off by default.
//
// Savestates (WP A2). DDR3 is modelled (sparse 64-bit words, random
// waitrequest, read latency), so the engine writes real slots:
//         --freeze-at C|$ADDR  boot mode: after READY/PRG, save the state to
//                     slot 1 at clk_sys cycle C (counted from there) or when
//                     the CPU fetches the opcode at $ADDR (hex), like the OSD
//                     "Save state"; --slot file.ss then gets the slot image.
//         --load-slot file.ss  boot mode: put the image in slot 1 and restore
//                     it after READY/PRG (before --run-cycles).
//
//   Vemu sstest [--prg fill.prg --kbuf "SYS2061\r"] [--freeze-at C] [--slot f.ss]
//       (the PRG is put into RAM directly, --kbuf starts it)
//       acceptance of A2: save at READY+C, screenshot A; run the PRG (it
//       changes screen and Color RAM), screenshot B; load the slot: RAM and
//       Color RAM must equal their state at the save, screenshot C must equal
//       A (a key held down across the load must not show: D3); then the OSD
//       self-test (save/save and save/load/save CRCs).
//
//   Vemu ssdiff [--ram-prg f.prg --kbuf 'RUN\r'] [--t0 C] [--t1 C] [--after C] [--slot prefix]
//       B3 differential of the live chain segments: two instances in
//       lockstep from READY (+PRG). B saves slot 2 at clk_sys C0, runs on to
//       C1, takes the user pause, saves slot 1, loads slot 2 (an older state
//       of every live segment and of the RAM), loads slot 1 and resumes. A
//       runs on. Every running sample of B (pausetest sample) must equal A's:
//       all live state came back from slot 1, and nothing outside the chain
//       was disturbed by the two saves and two loads. --slot writes
//       prefix1.ss / prefix2.ss.
//       --reject reu-off|reu-on|crc|version|chain|video-standard: refuse a bad
//       slot and compare every running sample with A after the refusal.
//       video-standard takes a real opposite-standard image via --load-slot.
//       --build-hash: change only the saved build hash; loading must still
//       replay exactly (format version and chain length define compatibility).
//       --mouse: replay moving 1351 packets on each instance's running clock.
//       --paddles: move live paddles on the same running-clock schedule.
//       --mouse-freeze: send a packet during a save and another during a load.
//       --turbo-check: require accelerated CPU cycles before and after loads.
//       --fifo-sync 0|2|3: dcfifo pointer crossing stages (default 3, 0 legacy).
//       --rewind: B saves slot 2 at C0, runs on to C1, takes the user pause,
//       loads slot 2 and resumes; from there every running sample of B must
//       equal A's from C0 (a load of a state from another moment: registers
//       rebuilt at the load must come from the loaded state); --slot writes
//       prefix2.ss.
//       --slotphase: save C0/C1/C2 to manual slots, load C1 then C0, and
//       re-pause after each load; --gap counts running clocks between points.
//   pausetest --load-slot file.ss: both instances start from a slot
//       image (e.g. saved on the board; the sim build needs the same
//       BUILD_DATE=yymmdd and chain).

#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cstdint>
#include <string>
#include <vector>
#include <deque>
#include <unordered_map>
#include <memory>
#include <chrono>
#include <fstream>

#include "verilated.h"
#include "verilated_save.h"
#include <strings.h>
#include <sys/stat.h>
#include <unistd.h>
#include "Vemu.h"
#include "Vemu___024root.h"
// Verilator keeps emu as its own class (rootp->emu) or flattens it into the
// root (rootp->emu__DOT__x) depending on the design size: EM(x) hides it.
#if __has_include("Vemu_emu.h")
#include "Vemu_emu.h"
#define EMO(o, x) (o).e->x
#else
#define EMO(o, x) (o).r->emu__DOT__##x
#endif
#define EM(x) EMO(*this, x)
#ifdef SIM_SDRAM_REAL
#define SDRAM(o, x) EMO(o, sdram_chip__DOT__##x)
#else
#define SDRAM(o, x) EMO(o, sdram__DOT__##x)
#endif

typedef uint64_t u64;
struct Sim;
static std::vector<Sim *> sim_instances;
[[noreturn]] static void finish(int rc);

// clock half periods in femtoseconds. clk48 is exactly 3/2 clk_sys as on the
// board (both divide the VCO of the core PLL), so a pause of whole C64 cycles
// leaves the phase of clk48 to clk_sys as it was
static const u64 HALF64 = 7929501;    // clk64  63.055900 MHz (clk_sys = clk64/2 = 31.527950 MHz)
static const u64 HALF48 = 10572668;   // clk48  47.291925 MHz (HALF64 * 4/3)
static const u64 HALF50 = 10000000;   // CLK_50M
static int g_fifo_sync = 3;

static std::vector<uint8_t> read_file(const char *path) {
	std::ifstream f(path, std::ios::binary);
	if (!f) { fprintf(stderr, "cannot open %s\n", path); exit(2); }
	return std::vector<uint8_t>((std::istreambuf_iterator<char>(f)), std::istreambuf_iterator<char>());
}

// D64 -> G64 as Main's c64_synthesize_g64_image() (support/c64/c64.cpp):
// 84 half tracks, data on the even ones, same header/gap layout.
// shortcut: single-sided D64 (35/40/42 tracks) only, add D71 when a test needs it.
static std::vector<uint8_t> d64_to_g64(const std::vector<uint8_t> &d64) {
	static const uint8_t lut[16] = {0x0a,0x0b,0x12,0x13,0x0e,0x0f,0x16,0x17,0x09,0x19,0x1a,0x1b,0x0d,0x1d,0x1e,0x15};
	auto spt = [](int t) { return t <= 17 ? 21 : t <= 24 ? 19 : t <= 30 ? 18 : 17; };
	int tracks = 35;
	for (int n : {35, 40, 42}) {
		tracks = n;
		int s = 0;
		for (int t = 1; t <= n; t++) s += spt(t);
		if (d64.size() <= (size_t)s * 257) break;
	}
	uint8_t id0 = d64.size() > 0x165a3 ? d64[0x165a2] : 0, id1 = d64.size() > 0x165a3 ? d64[0x165a3] : 0;
	const int NT = 84;
	std::vector<uint8_t> g(12 + NT * 8, 0);
	memcpy(g.data(), "GCR-1541", 8);
	g[9] = NT;
	auto put32 = [&](size_t at, uint32_t v) { for (int k = 0; k < 4; k++) g[at + k] = v >> (8 * k); };
	size_t sector = 0;
	for (int t = 0; t < NT; t += 2) {
		int th = t / 2 + 1;
		if (th > tracks) break;
		std::vector<uint8_t> trk(2);
		u64 acc = 0;
		int cnt = 0;
		auto bin = [&](uint8_t b) {
			acc = acc << 10 | (u64)lut[b >> 4] << 5 | lut[b & 15];
			if (++cnt == 4) { cnt = 0; for (int k = 4; k >= 0; k--) trk.push_back(acc >> (8 * k)); }
		};
		auto raw = [&](uint8_t b, int n) { trk.insert(trk.end(), n, b); };
		for (int s = 0; s < spt(th); s++, sector++) {
			const uint8_t *d = sector * 256 + 256 <= d64.size() ? &d64[sector * 256] : nullptr;
			cnt = 0;
			raw(0xFF, 5);
			for (uint8_t b : {(uint8_t)0x08, (uint8_t)(s ^ th ^ id0 ^ id1), (uint8_t)s, (uint8_t)th, id1, id0, (uint8_t)0x0F, (uint8_t)0x0F}) bin(b);
			raw(0x55, 9);
			raw(0xFF, 5);
			bin(0x07);
			uint8_t cs = 0;
			for (int i = 0; i < 256; i++) { uint8_t b = d ? d[i] : 0; cs ^= b; bin(b); }
			bin(cs); bin(0); bin(0);
			raw(0x55, th < 18 ? 8 : th < 25 ? 17 : th < 31 ? 12 : 9);
		}
		size_t len = trk.size() - 2;
		trk[0] = len; trk[1] = len >> 8;
		put32(12 + t * 4, g.size());
		put32(12 + NT * 4 + t * 4, th < 18 ? 3 : th < 25 ? 2 : th < 31 ? 1 : 0);
		g.insert(g.end(), trk.begin(), trk.end());
	}
	return g;
}

// PS/2 set 2 codes for typing
struct Key { uint8_t code; bool ext; bool shift; };
static bool ascii_key(char c, Key &k) {
	static const char *row = "abcdefghijklmnopqrstuvwxyz";
	static const uint8_t letters[26] = {0x1C,0x32,0x21,0x23,0x24,0x2B,0x34,0x33,0x43,0x3B,0x42,0x4B,0x3A,0x31,0x44,0x4D,0x15,0x2D,0x1B,0x2C,0x3C,0x2A,0x1D,0x22,0x35,0x1A};
	static const uint8_t digits[10] = {0x45,0x16,0x1E,0x26,0x25,0x2E,0x36,0x3D,0x3E,0x46};
	k = {0, false, false};
	if (c >= 'A' && c <= 'Z') c = c - 'A' + 'a';
	if (c >= 'a' && c <= 'z') { k.code = letters[strchr(row, c) - row]; return true; }
	if (c >= '0' && c <= '9') { k.code = digits[c - '0']; return true; }
	switch (c) {
	case ' ':  k.code = 0x29; return true;
	case '\n': k.code = 0x5A; return true;
	case '"':  k.code = 0x1E; k.shift = true; return true;   // C64 layout: shift+2
	case ',':  k.code = 0x41; return true;
	case '.':  k.code = 0x49; return true;
	case ':':  k.code = 0x4C; return true;                   // ; key position
	case '$':  k.code = 0x25; k.shift = true; return true;
	case '*':  k.code = 0x7C; return true;
	case '=':  k.code = 0x55; return true;
	}
	return false;
}

struct Sim {
	VerilatedContext ctx;
	std::unique_ptr<Vemu> top;
	Vemu___024root *r;
#if __has_include("Vemu_emu.h")
	Vemu_emu *e;
#endif
	u64 t = 0, n64 = HALF64, n48 = HALF48, n50 = HALF50;
	static const u64 NEVER = ~0ull;
	u64 sys_cycles = 0;
	u64 frames = 0;
	bool rose_sys = false;

	// ioctl download state
	std::vector<uint8_t> dl;
	size_t dl_pos = 0;
	int dl_state = 0;          // 0 idle, 1 start, 2 streaming, 3 end
	int dl_gap = 0;

	// keyboard queue: (code|ext<<8, pressed) with spacing
	std::deque<std::pair<uint16_t, bool>> keys;
	int key_gap = 0;

	// video capture
	std::vector<uint32_t> line, frame_cur, frame_done;
	int fw = 0, fh = 0, cur_w = 0, cur_h = 0;
	std::vector<std::vector<uint32_t>> lines_cur, lines_done;
	bool old_hs = false, old_vs = false, any_de = false;

	// DDR3 model (Avalon, clk_sys): sparse 64-bit words, random waitrequest,
	// read bursts returned after a latency, as the HPS bridge does. The drive
	// track cache (word addresses below the self-test area 0x07B00000) gets
	// its waitrequest and latency from an RNG that steps only on clocks where
	// the drives run, and its read beats count down and arrive only then: an
	// instance that pauses or saves sees the same drive DMA timing as one that
	// never stops (the drives issue no request while stopped). The drives run
	// on the next clock when c64_pause was low on the previous one (c1541_multi stop).
	struct Beat { uint32_t addr; int wait; bool drv; };
	std::unordered_map<uint32_t, std::vector<u64>> ddr;
	std::deque<Beat> rdq;
	uint32_t ddr_rng = 12345, drv_rng = 54321;
	uint8_t phist = 0;     // c64_pause after the last three clocks, bit 0 = last
	u64 ddr_wr = 0, ddr_rd = 0;
	u64 &ddr_word(uint32_t a) {
		auto &pg = ddr[a >> 16];
		if (pg.empty()) pg.assign(65536, 0);
		return pg[a & 0xFFFF];
	}
	void ddram() {
		ddr_rng = ddr_rng * 1103515245u + 12345u;
		phist = (uint8_t)((phist << 1) | EM(c64_pause));
		bool run = !(phist & 2);
		if (run) drv_rng = drv_rng * 1103515245u + 12345u;
		bool drv = top->DDRAM_ADDR < 0x07B00000u;
		uint32_t rng = drv ? drv_rng : ddr_rng;
		bool busy = ((rng >> 16) & 7) == 0;
		top->DDRAM_BUSY = busy;
		if (!busy && top->DDRAM_WE) {
			u64 &w = ddr_word(top->DDRAM_ADDR);
			u64 d = top->DDRAM_DIN;
			for (int i = 0; i < 8; i++)
				if ((top->DDRAM_BE >> i) & 1) w = (w & ~(0xFFull << (8 * i))) | (d & (0xFFull << (8 * i)));
			ddr_wr++;
		}
		if (!busy && top->DDRAM_RD) {
			int n = top->DDRAM_BURSTCNT ? top->DDRAM_BURSTCNT : 1;
			for (int i = 0; i < n; i++) rdq.push_back({top->DDRAM_ADDR + i, i == 0 ? 4 + (int)((rng >> 8) & 7) : 0, drv});
			ddr_rd++;
		}
		top->DDRAM_DOUT_READY = 0;
		top->DDRAM_DOUT = ((u64)ddr_rng << 32) ^ ddr_rng;   // readdata valid only with readdatavalid
		if (!rdq.empty() && (run || !rdq.front().drv)) {
			if (rdq.front().wait > 0) rdq.front().wait--;
			else {
				top->DDRAM_DOUT = ddr_word(rdq.front().addr);
				top->DDRAM_DOUT_READY = 1;
				rdq.pop_front();
			}
		}
	}
	// host side of B at the fork of a two-instance test: B starts as A
	void copy_host(const Sim &o) {
		ddr = o.ddr; rdq = o.rdq; ddr_rng = o.ddr_rng; drv_rng = o.drv_rng; phist = o.phist;
		mount_cnt = o.mount_cnt; sd_ack_cnt = o.sd_ack_cnt;
		sdimg[0] = o.sdimg[0]; sdimg[1] = o.sdimg[1]; sdx = o.sdx;
	}

	// savestate slots: 4 x 8 MiB at DDR3 0x3E000000 (word 0x07C00000)
	static uint32_t slot_base(int n) { return 0x07C00000u + 0x100000u * n; }
	std::vector<uint8_t> slot_image(int n) {
		uint32_t b = slot_base(n);
		uint32_t words = (uint32_t)(ddr_word(b) >> 33);
		if (words > 0x100000) words = 0;
		std::vector<uint8_t> v(words * 8);
		for (uint32_t i = 0; i < words; i++) {
			u64 w = ddr_word(b + i);
			for (int k = 0; k < 8; k++) v[i * 8 + k] = (w >> (8 * k)) & 0xFF;
		}
		return v;
	}
	void put_slot(int n, const std::vector<uint8_t> &v) { put_ddr(slot_base(n), v); }
	void put_ddr(uint32_t word, const std::vector<uint8_t> &v) {
		for (size_t i = 0; i < v.size(); i += 8) {
			u64 w = 0;
			for (int k = 0; k < 8 && i + k < v.size(); k++) w |= (u64)v[i + k] << (8 * k);
			ddr_word(word + i / 8) = w;
		}
	}
	// --disk: Main 260923 puts the G64 (a D64 synthesized to G64) in DDR3 at
	// 0x30000000 + drive * 0x200000 (core word 0x06000000 + drive * 0x40000),
	// sets the extension index and pulses img_mounted. The 1541 reads tracks
	// from there; its write-back requests (sd_wr) are acknowledged and dropped.
	// A D81 is not copied to DDR3 (empty g64): the 1581 asks for its sectors
	// over the SD block interface (sd_serve).
	int mount_cnt = 0, sd_ack_cnt = 0;
	void mount(int drive, const std::vector<uint8_t> &g64, size_t file_size, int ext) {
		put_ddr(0x06000000u + 0x40000u * drive, g64);
		EM(hps_io__DOT__h_ioctl_index) = ext << 6 | drive;
		EM(hps_io__DOT__h_img_size) = file_size;
		EM(hps_io__DOT__h_img_readonly) = 0;
		EM(hps_io__DOT__h_img_mounted) = 1 << drive;
		mount_cnt = 16;
	}
	// Sector requests of a drive with an image in sdimg are served from it as
	// hps_io does: BLKSZ 1, i.e. sd_blk_cnt+1 blocks of 256 bytes at block
	// sd_lba; a read writes the drive's buffer through sd_buff_addr,
	// sd_buff_dout and sd_buff_wr, a write reads sd_buff_din into the
	// in-memory copy (the file is not touched). Like the drive DDR3 traffic
	// the model steps only when the drives run on the next clock, so a paused
	// or saving instance sees a transfer at the same drive time as one that
	// never stopped.
	std::vector<uint8_t> sdimg[2];
	struct SdXfer { int st = 0, drv = 0, step = 0; bool wr = false; uint32_t pos = 0, len = 0; size_t off = 0; } sdx;
	bool sd_trace = false;
	void sd_serve(bool run) {
		EM(hps_io__DOT__h_sd_buff_wr) = 0;
		if (!run) return;
		if (sdx.st == 0) {   // idle: take the request of a drive with an image
			uint32_t rd = EM(hps_io__DOT__o_sd_rd), wr = EM(hps_io__DOT__o_sd_wr);
			for (int d = 0; d < 2; d++) {
				if (sdimg[d].empty() || !(((rd | wr) >> d) & 1)) continue;
				sdx.drv = d;
				sdx.wr  = (wr >> d) & 1;
				sdx.off = (size_t)(d ? EM(hps_io__DOT__o_sd_lba1) : EM(hps_io__DOT__o_sd_lba0)) * 256;
				sdx.len = ((d ? EM(hps_io__DOT__o_sd_blk_cnt1) : EM(hps_io__DOT__o_sd_blk_cnt0)) + 1u) * 256;
				sdx.pos = 0;
				sdx.step = 200;   // host latency before the acknowledge
				sdx.st = 1;
				if (sd_trace) printf("clk_sys %llu: drive %d SD %s at byte %zu, %u bytes\n", (unsigned long long)sys_cycles,
					d + 8, sdx.wr ? "write" : "read", sdx.off, sdx.len);
				break;
			}
			return;
		}
		if (sdx.st == 1) {
			if (!--sdx.step) { EM(hps_io__DOT__h_sd_ack) |= 1u << sdx.drv; sdx.st = 2; }
			return;
		}
		// one byte every 4 drive clocks
		std::vector<uint8_t> &img = sdimg[sdx.drv];
		size_t a = sdx.off + sdx.pos;
		if (sdx.step == 0) {
			EM(hps_io__DOT__h_sd_buff_addr) = sdx.pos;
			if (!sdx.wr) {
				EM(hps_io__DOT__h_sd_buff_dout) = a < img.size() ? img[a] : 0;
				EM(hps_io__DOT__h_sd_buff_wr) = 1;
			}
		}
		else if (sdx.step == 2 && sdx.wr && a < img.size())
			img[a] = sdx.drv ? EM(hps_io__DOT__o_sd_buff_din1) : EM(hps_io__DOT__o_sd_buff_din0);
		if (++sdx.step == 4) {
			sdx.step = 0;
			if (++sdx.pos == sdx.len) { EM(hps_io__DOT__h_sd_ack) &= ~(1u << sdx.drv); sdx.st = 0; }
		}
	}
	// OSD "R" option: status bit high for a while, the core takes the edge
	int osd_bit = -1, osd_cnt = 0;
	void osd(int bit) { osd_bit = bit; osd_cnt = 2000; set_status_bit(bit, true); }

	// clk48 only runs the OPL3, CLK_50M only the PAL/NTSC PLL reconfiguration:
	// both are off unless asked for (--opl, --clk50); each saves ~3 evals per
	// clk_sys cycle.
	explicit Sim(const char *name, bool opl = false, bool clk50 = false) {
		if (!opl) n48 = NEVER;
		if (!clk50) n50 = NEVER;
		ctx.randReset(0);
		top.reset(new Vemu(&ctx, name));
		r = top->rootp;
#if __has_include("Vemu_emu.h")
		e = r->emu;
#endif
		top->CLK_50M = 0;
		top->RESET = 0;
		top->OSD_STATUS = 0;
		top->HDMI_WIDTH = 1920;
		top->HDMI_HEIGHT = 1080;
		top->USER_IN = 0x7f;
		top->UART_RXD = 1;
		top->UART_CTS = 0;
		top->UART_DSR = 0;
		top->SD_MISO = 1;
		top->SD_CD = 1;
		top->DDRAM_BUSY = 0;
		top->DDRAM_DOUT_READY = 0;
		top->CLK_AUDIO = 0;
		top->eval();
		EM(opl_inst__DOT__opl3__DOT__in_queue__DOT__dcfifo_component__DOT__sim_sync_stages) = g_fifo_sync;
		sim_instances.push_back(this);
	}

	void set_status_bit(int bit, bool v) {
		uint32_t &w = EM(hps_io__DOT__h_status)[bit / 32];
		if (v) w |= 1u << (bit % 32); else w &= ~(1u << (bit % 32));
	}
	bool status_bit(int bit) { return (EM(hps_io__DOT__h_status)[bit / 32] >> (bit % 32)) & 1; }
	u64 frame_cycles() { return status_bit(2) ? 263ull * 65 * 32 : 312ull * 63 * 32; }

	void ps2(uint16_t code_ext, bool pressed) {
		uint16_t k = EM(hps_io__DOT__h_ps2_key);
		k = ((~k) & 0x400) | (pressed ? 0x200 : 0) | (code_ext & 0x1ff);
		EM(hps_io__DOT__h_ps2_key) = k;
	}

	void type(const std::string &s) {
		for (char c : s) {
			Key k;
			if (!ascii_key(c, k)) continue;
			if (k.shift) keys.push_back({0x12, true});
			keys.push_back({(uint16_t)(k.code | (k.ext ? 0x100 : 0)), true});
			keys.push_back({(uint16_t)(k.code | (k.ext ? 0x100 : 0)), false});
			if (k.shift) keys.push_back({0x12, false});
		}
	}

	void download(const std::vector<uint8_t> &data, int index, uint32_t ext) {
		dl = data;
		dl_pos = 0;
		dl_state = 1;
		EM(hps_io__DOT__h_ioctl_index) = index;
		EM(hps_io__DOT__h_ioctl_file_ext) = ext;
	}

	// per clk_sys cycle host-side activity (called after the rising edge)
	void host() {
		ddram();
		if (osd_cnt && !--osd_cnt) set_status_bit(osd_bit, false);
		if (mount_cnt && !--mount_cnt) EM(hps_io__DOT__h_img_mounted) = 0;
		// drives without an image in sdimg (1541 write-back): acknowledged, no data
		uint32_t own = (sdimg[0].empty() ? 0u : 1u) | (sdimg[1].empty() ? 0u : 2u);
		uint32_t req = (EM(hps_io__DOT__o_sd_wr) | EM(hps_io__DOT__o_sd_rd)) & ~own;
		if (sd_ack_cnt) { if (!--sd_ack_cnt) EM(hps_io__DOT__h_sd_ack) &= own; }
		else if (req) {
			EM(hps_io__DOT__h_sd_ack) |= req;
			sd_ack_cnt = 64;
		}
		sd_serve(!(phist & 2));   // the drives run on the next clock (ddram)
		EM(hps_io__DOT__h_ioctl_wr) = 0;
		switch (dl_state) {
		case 1:
			EM(hps_io__DOT__h_ioctl_download) = 1;
			dl_state = 2; dl_gap = 4;
			break;
		case 2:
			if (dl_gap) { dl_gap--; break; }
			if (EM(hps_io__DOT__o_ioctl_wait)) break;
			if (dl_pos < dl.size()) {
				EM(hps_io__DOT__h_ioctl_addr) = dl_pos;
				EM(hps_io__DOT__h_ioctl_dout) = dl[dl_pos++];
				EM(hps_io__DOT__h_ioctl_wr) = 1;
				dl_gap = 8;
			} else { dl_state = 3; dl_gap = 8; }
			break;
		case 3:
			if (dl_gap) { dl_gap--; break; }
			if (EM(hps_io__DOT__o_ioctl_wait)) break;
			EM(hps_io__DOT__h_ioctl_download) = 0;
			dl_state = 0;
			break;
		}
		if (key_gap) key_gap--;
		else if (!keys.empty()) {
			ps2(keys.front().first, keys.front().second);
			keys.pop_front();
			key_gap = 31528 * 30;   // 30 ms between events: the KERNAL scans at 60 Hz
		}
	}

	// pausetest: core video output (sync, blank, RGB) at every pixel sample
	bool vrec = false;
	std::vector<uint32_t> vstream;
	std::vector<uint8_t> vpaused;   // c64_pause at that sample

	void video() {
		// sampled on clk64 rising edges with CE_PIXEL
		if (!top->CE_PIXEL) return;
		if (vrec) {
			vstream.push_back(((uint32_t)top->VGA_HS << 31) | ((uint32_t)top->VGA_VS << 30) | ((uint32_t)top->VGA_DE << 29) |
				(top->VGA_DE ? ((top->VGA_R << 16) | (top->VGA_G << 8) | top->VGA_B) : 0));
			vpaused.push_back(EM(c64_pause));
		}
		bool hs = top->VGA_HS, vs = top->VGA_VS;
		if (hs && !old_hs) {
			if (!line.empty()) lines_cur.push_back(line);
			line.clear();
		}
		if (vs && !old_vs) {
			if (lines_cur.size() > 100) { lines_done.swap(lines_cur); frames++; }
			lines_cur.clear();
		}
		old_hs = hs; old_vs = vs;
		if (top->VGA_DE) line.push_back((top->VGA_R << 16) | (top->VGA_G << 8) | top->VGA_B);
	}

	// Output sync as the scaler (ascal) and hps_io's video_calc see it, on
	// clk64: the core's hsync_out/vsync_out (video_sync) and the freezer
	// outputs of video_mixer (the core's sync, or the one video_freezer
	// regenerates while HDMI_FREEZE is high). Once armed (sm.on):
	// - every hsync and vsync period is the selected VIC line and frame;
	// - video_calc (sys/hps_io.sv) on the freezer outputs at CE_PIXEL sees
	//   one active size: a frame of another width or height restarts its
	//   15-frame timeout, at the end of which vid_nres counts and Main shows
	//   the video info as for a mode change (the first frame after arming
	//   sets the reference);
	// - the VIC raster coordinates video_sync takes its stop position from
	//   keep their offset while the machine runs: hsync_out rises at VIC X
	//   397 + its first dot (10 PAL, 16 NTSC), vsync_out on VIC line 296 PAL
	//   / 12 NTSC, vic_y steps only at X 404 PAL / 420 NTSC (the last line
	//   too), the machine stops at X = 8n+6;
	// - a stop that resumes on the VIC position it stopped on (plain pause,
	//   save, a load of the same state) lasts whole frames;
	// - no pause release by the watchdog.
	// Every stop is logged with its length, the loads in it and the VIC
	// raster position (line/X) at the stop and at the resume.
	struct Edge { bool v = false; u64 at = 0; };
	struct SyncMon {
		bool on = false, log = true;
		Edge hs[2], vs[2];             // 0 core output, 1 freezer output
		u64 t = 0, bad = 0, frames = 0;
		bool vc_vs = false, vc_de = false, calch = false;
		uint32_t hcnt = 0, vcnt = 0, vid_hcnt = 0, vid_vcnt = 0, sizes = 0;
		int resto = 0, nres = 0;
		bool primed = false, sprimed = false;   // first sample after construction/restore: history only
		bool old_pause = false, old_hold = false, old_busy = false, wd = false;
		u64 stop_at = 0, stops = 0, loads = 0, load_stops = 0, max_wait = 0, whole = 0;
		int stop_loads = 0;
		uint32_t y0 = 0, x0 = 0, old_y = 0;
		u64 freed_at = 0;              // clk_sys of the release in this stop
	} sm;
	uint32_t vic_x() { return EM(vic_x); }
	uint32_t vic_y() { return EM(vic_y); }
	bool sm_bad() { return sm.on && ++sm.bad <= 20; }
	void sync_mon() {
		SyncMon &m = sm;
		m.t++;
		bool ntsc = EM(ntsc), run = !EM(c64_pause);
		u64 line = (ntsc ? 520 : 504) * 8ull, frame = line * (ntsc ? 263 : 312);
		static const char *src[2] = {"core", "scaler"};
		bool hs[2] = {(bool)EM(hsync_out), (bool)EM(video_mixer__DOT__frz_hs)};
		bool vs[2] = {(bool)EM(vsync_out), (bool)EM(video_mixer__DOT__frz_vs)};
		if (!m.primed) {
			for (int i = 0; i < 2; i++) { m.hs[i] = {hs[i], 0}; m.vs[i] = {vs[i], 0}; }
			m.vc_vs = vs[1]; m.vc_de = !EM(video_mixer__DOT__frz_hbl) && !EM(video_mixer__DOT__frz_vbl);
			m.primed = true;
			return;
		}
		auto edge = [&](Edge &e, bool v, u64 want, const char *what, int i) {
			if (v && !e.v) {
				if (e.at && m.t - e.at != want && sm_bad())
					printf("sync: %s %s period %llu clk64, expected %llu (%+lld) at %s clk_sys %llu (machine %s, HDMI_FREEZE %d, VIC raster %u/%u)\n",
						src[i], what, (unsigned long long)(m.t - e.at), (unsigned long long)want, (long long)(m.t - e.at) - (long long)want,
						top->name(), (unsigned long long)sys_cycles, run ? "running" : "stopped", (int)top->HDMI_FREEZE, vic_y(), vic_x());
				e.at = m.t;
				return true;
			}
			return false;
		};
		for (int i = 0; i < 2; i++) {
			bool h = edge(m.hs[i], hs[i], line, "hsync", i), f = edge(m.vs[i], vs[i], frame, "vsync", i);
			m.hs[i].v = hs[i]; m.vs[i].v = vs[i];
			if (i) continue;
			m.frames += f && m.on;
			if (!run) continue;
			uint32_t want_x = 397 + (ntsc ? 16 : 10), want_y = ntsc ? 12 : 296;
			if (h && vic_x() != want_x && sm_bad())
				printf("sync: %s hsync_out at VIC X %u, expected %u, clk_sys %llu\n", top->name(), vic_x(), want_x, (unsigned long long)sys_cycles);
			if (f && vic_y() != want_y && sm_bad())
				printf("sync: %s vsync_out on VIC line %u, expected %u, clk_sys %llu\n", top->name(), vic_y(), want_y, (unsigned long long)sys_cycles);
		}
		if (!top->CE_PIXEL) return;
		// video_calc: every condition sees the values before this sample (nonblocking)
		bool v = vs[1], de = !EM(video_mixer__DOT__frz_hbl) && !EM(video_mixer__DOT__frz_vbl);
		if (m.vc_vs && !v) {
			if (m.hcnt && m.vcnt) {
				int r0 = m.resto;
				if (r0) m.resto = (r0 + 1) & 15;
				if (!m.vid_vcnt) ;   // first frame after arming: reference size
				else if (m.vid_hcnt != m.hcnt || m.vid_vcnt != m.vcnt) {
					m.resto = 1;
					if (m.on && ++m.sizes <= 20)
						printf("video_calc: %s frame %ux%u after %ux%u at clk_sys %llu: resolution timeout restarted\n", top->name(),
							m.hcnt, m.vcnt, m.vid_hcnt, m.vid_vcnt, (unsigned long long)sys_cycles);
				}
				if (r0 == 15) {
					m.nres++;
					if (m.on) printf("video_calc: %s vid_nres %d at clk_sys %llu (Main shows the video info)\n", top->name(), m.nres, (unsigned long long)sys_cycles);
				}
				if (!m.on) m.vid_vcnt = 0;
				else { m.vid_hcnt = m.hcnt; m.vid_vcnt = m.vcnt; }
			}
			m.vcnt = 0; m.hcnt = 0; m.calch = true;
		}
		else {
			if (!v && !m.vc_de && de) m.vcnt++;
			if (m.calch && de) m.hcnt++;
			if (m.vc_de && !de) m.calch = false;
		}
		m.vc_vs = v; m.vc_de = de;
	}
	// once per clk_sys: VIC line steps, stops of the machine (the release is
	// the last fall of the user/OSD freeze or of the engine's freeze in the
	// stop, or an engine request, which lets a stopped machine run to a
	// boundary: from there it waits for its video position, at most one
	// frame) and the pause release watchdog
	void stop_mon() {
		SyncMon &m = sm;
		bool p = EM(c64_pause), hold = EM(freeze) || EM(ss_frz_ack), busy = EM(ss_busy), ntsc = EM(ntsc);
		u64 frame = ntsc ? 263ull * 65 * 32 : 312ull * 63 * 32;
		uint32_t x = vic_x(), y = vic_y(), y_step = ntsc ? 420 : 404;
		if (!m.sprimed) { m.old_y = y; m.old_pause = p; m.old_hold = hold; m.old_busy = busy; m.sprimed = true; return; }
		if (y != m.old_y && !p && !m.old_pause && x != y_step && sm_bad())
			printf("sync: %s VIC line %u -> %u at X %u, expected X %u, clk_sys %llu\n", top->name(), m.old_y, y, x, y_step, (unsigned long long)sys_cycles);
		m.old_y = y;
		if (p && !m.old_pause) {
			m.stop_at = m.freed_at = sys_cycles; m.stop_loads = 0; m.y0 = y; m.x0 = x;
			if (x % 8 != 6 && sm_bad())
				printf("sync: %s machine stopped at VIC X %u, expected 8n+6, clk_sys %llu\n", top->name(), x, (unsigned long long)sys_cycles);
		}
		if (EM(ss_load_done)) { m.stop_loads++; m.loads++; }
		if ((m.old_hold && !hold) || (busy && !m.old_busy)) m.freed_at = sys_cycles;
		if (!p && m.old_pause && m.on) {
			m.stops++;
			u64 len = sys_cycles - m.stop_at, wait = sys_cycles - m.freed_at;
			if (m.stop_loads) m.load_stops++;
			m.max_wait = std::max(m.max_wait, wait);
			if (wait > frame + 64 && sm_bad())
				printf("sync: %s resumed %llu clk_sys after the release, more than a frame\n", top->name(), (unsigned long long)wait);
			if (y == m.y0 && x == m.x0) {
				m.whole++;
				if (len % frame && sm_bad())
					printf("sync: %s resumed on its stop position after %llu clk_sys, not whole frames (%llu each)\n", top->name(),
						(unsigned long long)len, (unsigned long long)frame);
			}
			if (m.log && (m.stop_loads || m.stops <= 8))
				printf("stop: %s stopped %llu clk_sys (%.3f frames) at VIC raster %u/%u, %d load(s), resumed at %u/%u %llu clk_sys after the release\n",
					top->name(), (unsigned long long)len, len / (double)frame, m.y0, m.x0, m.stop_loads, y, x, (unsigned long long)wait);
		}
		if (m.on && !m.wd && EM(pause_wd) == 0x3FFFFF) {
			m.wd = true; m.bad++;
			printf("sync: %s pause released by the watchdog at clk_sys %llu (no video alignment)\n", top->name(), (unsigned long long)sys_cycles);
		}
		m.old_pause = p; m.old_hold = hold; m.old_busy = busy;
	}
	// end of a test: the monitor's verdict
	bool sync_report() {
		SyncMon &m = sm;
		bool ok = m.on && !m.bad && !m.sizes && m.frames > 2;
		char checks[96];
		if (m.bad) snprintf(checks, sizeof checks, "%llu errors (sync: lines)", (unsigned long long)m.bad);
		else snprintf(checks, sizeof checks, "hsync/vsync periods regular at the core and the scaler, VIC raster offsets held");
		printf("sync %s: %s, %llu frames, %llu stops (%llu back on their VIC position, %llu with %llu loads; resume at most %llu clk_sys "
			"= %.3f frames after the release); %s; video_calc %ux%u, %u size changes, vid_nres +%d\n",
			top->name(), ok ? "PASS" : "FAIL", (unsigned long long)m.frames, (unsigned long long)m.stops, (unsigned long long)m.whole,
			(unsigned long long)m.load_stops, (unsigned long long)m.loads, (unsigned long long)m.max_wait, m.max_wait / (double)frame_cycles(),
			checks, m.vid_hcnt, m.vid_vcnt, m.sizes, m.nres);
		return ok;
	}

	// --opl: the OPL register file as the FM firmware took it from the register
	// queue (index and value entries); the reset of the FM part zeroes it, as the
	// firmware zeroes every register
	uint8_t oplreg[256] = {}, oplidx = 0;
	uint32_t oplrp = 0;
	void opl_track() {
		if (EM(opl_inst__DOT__opl3__DOT__reset)) { memset(oplreg, 0, sizeof oplreg); oplidx = 0; oplrp = 0; return; }
		for (uint32_t rp = EM(opl_inst__DOT__opl3__DOT__in_queue__DOT__dcfifo_component__DOT__rp); oplrp != rp; oplrp = (oplrp + 1) & 0x7FF) {
			uint16_t e = EM(opl_inst__DOT__opl3__DOT__in_queue__DOT__dcfifo_component__DOT__mem)[oplrp & 0x3FF];
			if (e & 0x100) oplreg[oplidx] = e & 0xFF; else oplidx = e & 0xFF;
		}
	}
	bool opl_queue_empty() {
		return EM(opl_inst__DOT__opl3__DOT__in_queue__DOT__dcfifo_component__DOT__wp) ==
		       EM(opl_inst__DOT__opl3__DOT__in_queue__DOT__dcfifo_component__DOT__rp);
	}

	// advance until one clk_sys rising edge has been evaluated
	void step() {
		rose_sys = false;
		while (!rose_sys) {
			u64 nt = std::min(n64, std::min(n48, n50));
			t = nt;
			bool rise64 = false;
			if (n64 == nt) {
				EM(pll__DOT__clk64) ^= 1;
				if (EM(pll__DOT__clk64)) {
					rise64 = true;
					EM(pll__DOT__clksys) ^= 1;
					if (EM(pll__DOT__clksys)) rose_sys = true;
				}
				n64 += HALF64;
			}
			if (n48 == nt) { EM(pll__DOT__clk48) ^= 1; n48 += HALF48; }
			if (n50 == nt) { top->CLK_50M ^= 1; n50 += HALF50; }
			top->eval();
			if (rise64) { video(); sync_mon(); }
		}
		sys_cycles++;
		if (sys_cycles == 64) EM(pll__DOT__lock) = 1;
		host();
		if (n48 != NEVER) opl_track();
		stop_mon();
	}

	// whole model + harness clock state (needs verilator --savable)
	void save(const char *path) {
		VerilatedSave os;
		os.open(path);
		os << *top;
		u64 h[6] = {t, n64, n48, n50, sys_cycles, frames};
		os.write(h, sizeof h);
		os.close();
	}
	void restore(const char *path) {
		VerilatedRestore is;
		is.open(path);
		is >> *top;
		u64 h[6];
		is.read(h, sizeof h);
		is.close();
		t = h[0]; n64 = h[1];
		n48 = n48 == NEVER ? NEVER : h[2];
		n50 = n50 == NEVER ? NEVER : h[3];
		sys_cycles = h[4]; frames = h[5];
		lines_cur.clear(); line.clear();
		sm.primed = sm.sprimed = false;   // the monitor takes the restored signals as its history
	}

	uint8_t ram(uint32_t a) { return SDRAM(*this, mem)[a]; }
	void poke_ram(uint32_t a, uint8_t value) {
		SDRAM(*this, mem)[a] = value;
#ifdef SIM_SDRAM_REAL
		SDRAM(*this, written)[a >> 3] |= 1u << (a & 7);
#endif
	}
	uint8_t cram(uint32_t a) { return EM(fpga64__DOT__colorram__DOT__ram)[a] & 15; }

	// one savestate operation through the OSD (bit 102 save, 103 restore);
	// returns the engine result, -1 on timeout. on_freeze runs once when the
	// machine is frozen for the engine (before any slot data moves).
	template <class F> int ss_op(int bit, F on_freeze, u64 max_cycles = 400000000ull) {
		osd(bit);
		bool seen_busy = false, froze = false;
		for (u64 i = 0; i < max_cycles; i++) {
			step();
			if (EM(ss_busy)) seen_busy = true;
			if (!froze && EM(ss_frz_ack)) { froze = true; on_freeze(); }
			if (EM(ss_done)) return EM(ss_result);
			if (!seen_busy && i > 100000) return -2;
		}
		return -1;
	}

	bool ready_on_screen() {
		static const uint8_t pat[6] = {0x12, 0x05, 0x01, 0x04, 0x19, 0x2E}; // "READY."
		for (uint32_t a = 0x400; a < 0x400 + 1000 - 6; a++) {
			int i = 0;
			while (i < 6 && ram(a + i) == pat[i]) i++;
			if (i == 6) return true;
		}
		return false;
	}

	void screen_text(FILE *f) {
		for (int y = 0; y < 25; y++) {
			for (int x = 0; x < 40; x++) {
				uint8_t c = ram(0x400 + y * 40 + x) & 0x7f;
				char ch = c == 0 ? '@' : c < 27 ? 'A' + c - 1 : (c >= 32 && c < 64) ? c : c == 0x1b ? '[' : '.';
				fputc(ch, f);
			}
			fputc('\n', f);
		}
	}

	bool save_ppm(const char *path) {
		if (lines_done.empty()) return false;
		size_t w = 0;
		for (auto &l : lines_done) w = std::max(w, l.size());
		FILE *f = fopen(path, "wb");
		if (!f) return false;
		fprintf(f, "P6\n%zu %zu\n255\n", w, lines_done.size());
		for (auto &l : lines_done)
			for (size_t x = 0; x < w; x++) {
				uint32_t p = x < l.size() ? l[x] : 0;
				fputc(p >> 16, f); fputc((p >> 8) & 255, f); fputc(p & 255, f);
			}
		fclose(f);
		return true;
	}

	// one sample of the C64-visible state, valid when the machine runs
	bool running() { return !EM(c64_pause) && EM(reset_n); }
	u64 sample() {
		u64 s = EM(c64_addr);
		s |= (u64)EM(c64_data_out) << 16;
		s |= (u64)EM(ram_we) << 24;
		s |= (u64)EM(ram_ce) << 25;
		s |= (u64)EM(fpga64__DOT__todclk) << 26;
		s |= (u64)EM(cass_read) << 27;
		s |= (u64)EM(cass_motor) << 28;
		s |= (u64)EM(cass_sense) << 29;
		s |= (u64)(EM(r) ^ (EM(g) << 3) ^ (EM(b) << 5)) << 30;
		s |= (u64)(uint16_t)EM(alo) << 40;
		return s;
	}
};

// Core video output of a pausetest (B paused, A not). B must show A's
// picture before the pause, replay the last frame while paused (each sample
// equal to the one a frame earlier), show A's picture shifted by the paused
// time after the resume, and keep a regular h/v sync all along.
static bool check_pause_video(Sim &a, Sim &b, u64 paused_cycles) {
	const auto &A = a.vstream, &B = b.vstream;
	if (paused_cycles % 4) { printf("FAIL video: paused time is not a whole number of dots\n"); return false; }
	size_t n = paused_cycles / 4;   // one pixel sample per dot (4 clk_sys)
	// sync periods from B's output
	auto edges = [&](int bit) {
		std::vector<size_t> e;
		for (size_t i = 1; i < B.size(); i++)
			if (((B[i] >> bit) & 1) && !((B[i - 1] >> bit) & 1)) e.push_back(i);
		return e;
	};
	auto hs = edges(31), vs = edges(30);
	if (hs.size() < 3 || vs.size() < 3) { printf("FAIL video: no sync on the output\n"); return false; }
	size_t hp = hs[1] - hs[0], vp = vs[1] - vs[0];
	size_t want_hp = b.status_bit(2) ? 520 : 504, want_vp = b.frame_cycles() / 4;
	if (hp != want_hp || vp != want_vp) {
		printf("FAIL video: %zu/%zu dots per line/frame, expected %zu/%zu\n", hp, vp, want_hp, want_vp);
		return false;
	}
	for (size_t i = 1; i < hs.size(); i++)
		if (hs[i] - hs[i - 1] != hp) { printf("FAIL video: hsync period %zu at sample %zu (expected %zu)\n", hs[i] - hs[i - 1], hs[i], hp); return false; }
	for (size_t i = 1; i < vs.size(); i++)
		if (vs[i] - vs[i - 1] != vp) { printf("FAIL video: vsync period %zu at sample %zu (expected %zu)\n", vs[i] - vs[i - 1], vs[i], vp); return false; }
	size_t p0 = 0, p1 = 0;
	while (p0 < B.size() && !b.vpaused[p0]) p0++;
	p1 = p0;
	while (p1 < B.size() && b.vpaused[p1]) p1++;
	if (p1 >= B.size() || p0 < vp) { printf("FAIL video: pause not found in the recording\n"); return false; }
	if (p1 - p0 != n) { printf("FAIL video: %zu paused samples, %zu expected\n", p1 - p0, n); return false; }
	const size_t M = 4;    // output pipeline latency (dots) around the pause edges
	size_t replayed = 0;
	for (size_t i = 0; i < B.size(); i++) {
		bool pre = i < A.size() && B[i] == A[i];
		bool rep = B[i] == B[i - (i >= vp ? vp : 0)];
		bool post = i >= n && i - n < A.size() && B[i] == A[i - n];
		bool ok;
		if (i < p0) ok = pre;
		else if (i < p0 + M) ok = pre || rep;
		else if (i < p1) ok = rep;
		else if (i < p1 + M) ok = rep || post;
		else ok = post;
		if (i >= p0 && i < p1 && (B[i] >> 29 & 1)) replayed++;
		if (!ok) {
			printf("FAIL video: sample %zu (pause at %zu..%zu): B=%08x A=%08x A-shifted=%08x B-frame=%08x\n", i, p0, p1, B[i],
				i < A.size() ? A[i] : 0, i >= n ? A[i - n] : 0, i >= vp ? B[i - vp] : 0);
			return false;
		}
	}
	printf("video: PASS, hsync every %zu dots and vsync every %zu dots across the pause, %zu visible dots replayed while paused, output after the resume = A shifted by %zu dots\n",
		hp, vp, replayed, n);
	return true;
}

static const char *arg(int argc, char **argv, const char *name, const char *def) {
	for (int i = 1; i < argc - 1; i++) if (!strcmp(argv[i], name)) return argv[i + 1];
	return def;
}
static bool has(int argc, char **argv, const char *name) {
	for (int i = 1; i < argc; i++) if (!strcmp(argv[i], name)) return true;
	return false;
}

static double now() {
	return std::chrono::duration<double>(std::chrono::steady_clock::now().time_since_epoch()).count();
}

// the snapshot is valid while it is newer than the verilated model (the
// generated root header next to the binary), so rebuilding only the
// harness keeps it
static bool newer_than_model(const char *path) {
	char buf[4096];
	ssize_t n = readlink("/proc/self/exe", buf, sizeof buf - 1);
	if (n <= 0) return false;
	std::string exe(buf, n);
	std::string model = exe.substr(0, exe.rfind('/')) + "/Vemu___024root.h";
	struct stat a, b;
	if (stat(path, &a) || stat(model.c_str(), &b)) return false;
	return a.st_mtime >= b.st_mtime;
}

// power on and run to the READY prompt. The state at READY is cached in
// ready.state (run directory) and reused while it is newer than the binary;
// --no-cache forces a real boot.
static bool g_cache = true;
static bool g_opl = false, g_clk50 = false, g_trace_drive = false;
static const char *g_status = nullptr;   // "--status 14,57" : status bits set at power on

static const char *g_status_ready = nullptr;   // "--status-ready 96": set after READY

static void apply_status(Sim &s, const char *bits = g_status) {
	if (!bits) return;
	for (const char *p = bits; *p;) {
		s.set_status_bit(atoi(p), true);
		while (*p && *p != ',') p++;
		if (*p) p++;
	}
}
// --disk: drive 8 gets the image at power on (Main puts a D64 synthesized
// to G64 in DDR3 and pulses img_mounted), so the DOS and the mount sequence
// are done by READY. A restored READY snapshot gets the image back in DDR3
// (the model state does not hold the DDR3 content), without a new mount. A
// D81 (extension 3: img_type 1581) stays a file the SD model serves.
static const char *g_disk = nullptr;
static void mount_disk(Sim &s, bool strobe) {
	// S0,D64G64T64D81: D64 is extension 0, G64 extension 1, D81 extension 3
	std::vector<uint8_t> d = read_file(g_disk);
	size_t n = strlen(g_disk);
	bool g64 = n > 4 && !strcasecmp(g_disk + n - 4, ".g64");
	bool d81 = n > 4 && !strcasecmp(g_disk + n - 4, ".d81");
	if (d81) {
		s.sdimg[0] = d;
		if (strobe) s.mount(0, {}, d.size(), 3);
		return;
	}
	std::vector<uint8_t> img = g64 ? d : d64_to_g64(d);
	if (strobe) s.mount(0, img, d.size(), g64 ? 1 : 0);
	else s.put_ddr(0x06000000u, img);
}
static void check_standard(Sim &s) {
	if (EMO(s, ntsc) != s.status_bit(2)) {
		fprintf(stderr, "FAIL: status video standard did not reach the VIC (CLK_50M/configuration)\n");
		exit(1);
	}
}
static void reach_ready(Sim &s, int max_frames, bool verbose) {
	// one snapshot per model variant, status, disk and clk48: ready-obj.state, ready-obj-nodrv.state, ...
	static std::string name;
	if (name.empty()) {
		char buf[4096];
		ssize_t n = readlink("/proc/self/exe", buf, sizeof buf - 1);
		std::string exe = n > 0 ? std::string(buf, n) : "obj/Vemu";
		std::string dir = exe.substr(0, exe.rfind('/'));
		std::string disk = g_disk ? std::string(g_disk) : std::string();
		if (!disk.empty()) disk = "-" + disk.substr(disk.rfind('/') + 1);
		name = "ready-" + dir.substr(dir.rfind('/') + 1) + (g_status ? std::string("-") + g_status : std::string()) + disk +
		       (g_opl ? "-opl-fifo" + std::to_string(g_fifo_sync) : "") + (g_clk50 ? "-clk50" : "") + ".state";
	}
	const char *cache = name.c_str();
	if (g_cache && newer_than_model(cache)) {
		s.restore(cache);
		if (g_disk) mount_disk(s, false);
		if (verbose) printf("READY state restored from %s (clk_sys %llu)\n", cache, (unsigned long long)s.sys_cycles);
		check_standard(s);
		return;
	}
	double t0 = now();
	if (g_disk) {
		mount_disk(s, true);
		if (verbose) printf("%s mounted on drive 8\n", g_disk);
	}
	while (!s.ready_on_screen()) {
		s.step();
		if ((int)s.frames > max_frames) { fprintf(stderr, "READY not found after %d frames\n", max_frames); s.screen_text(stderr); finish(1); }
	}
	if (verbose) printf("READY after %llu clk_sys cycles (%.1f k C64 cycles), %.1f s, %.0f clk_sys/s\n",
		(unsigned long long)s.sys_cycles, s.sys_cycles / 32 / 1000.0, now() - t0, s.sys_cycles / (now() - t0));
	while (s.sdx.st) s.step();   // the SD model state is not in the snapshot
	check_standard(s);
	if (g_cache) s.save(cache);
}

// PRG straight into RAM (no ioctl, so no "Reset & Run PRG" reboot): a BASIC
// program at $0801 also gets the end pointers the KERNAL LOAD sets, so
// --kbuf 'RUN\r' starts it
static void poke_prg(Sim &s, const char *path, bool verbose) {
	std::vector<uint8_t> d = read_file(path);
	uint32_t a = d[0] | d[1] << 8, end = (a + d.size() - 2) & 0xFFFF;
	for (size_t i = 2; i < d.size(); i++) s.poke_ram((a + i - 2) & 0xFFFF, d[i]);
	if (a == 0x0801)
		for (int p = 0x2D; p <= 0x31; p += 2) { s.poke_ram(p, end & 0xFF); s.poke_ram(p + 1, end >> 8); }
	if (verbose) printf("PRG %s put at $%04X-$%04X\n", path, a, (unsigned)((end - 1) & 0xFFFF));
}

// optional PRG/TAP/typing after READY
static const char *g_kbuf = nullptr;
static const char *g_ram_prg = nullptr;   // --ram-prg file: poke_prg before --kbuf
static void load(Sim &s, const char *prg, const char *tap, const char *text, bool verbose) {
	apply_status(s, g_status_ready);
	if (g_ram_prg) poke_prg(s, g_ram_prg, verbose);
	if (prg) {
		// FS1,PRGCRTREUTAP: PRG is extension 0 (index 1), CRT extension 1 (index 0x41)
		size_t n = strlen(prg);
		bool crt = n > 4 && !strcasecmp(prg + n - 4, ".crt");
		s.download(read_file(prg), crt ? 0x41 : 1, crt ? 0x00435254 /* "CRT" */ : 0x00505247 /* "PRG" */);
		while (s.dl_state) s.step();
		if (verbose) printf("%s loaded at clk_sys %llu\n", crt ? "CRT" : "PRG", (unsigned long long)s.sys_cycles);
	}
	if (tap) {
		s.download(read_file(tap), 0xC1, 0x00544150 /* "TAP" */);
		while (s.dl_state) s.step();
		if (verbose) printf("TAP loaded at clk_sys %llu\n", (unsigned long long)s.sys_cycles);
	}
	if (text) {
		std::string t;
		for (const char *p = text; *p; p++) {
			if (p[0] == '\\' && p[1] == 'n') { t += '\n'; p++; } else t += *p;
		}
		s.type(t);
	}
	if (g_kbuf) {
		// KERNAL keyboard buffer ($0277, count in $C6): instant and exact,
		// unlike typing through the matrix. PETSCII = upper-case ASCII here.
		int n = 0;
		for (const char *p = g_kbuf; *p && n < 10; p++) {
			char c = *p;
			if (p[0] == '\\' && p[1] == 'r') { c = 13; p++; }
			if (c >= 'a' && c <= 'z') c -= 32;
			s.poke_ram(0x277 + n++, (uint8_t)c);
		}
		s.poke_ram(0xC6, n);
		if (verbose) printf("keyboard buffer: %d chars\n", n);
	}
}

// Two multithreaded Verilated models in one process deadlock in their
// destructors (VerilatedScope teardown waits on a mutex held by the worker
// pool), which hung pausetest after PASS. Results are on stdout already:
// flush and leave before any model is destroyed.
[[noreturn]] static void finish(int rc) {
	for (Sim *s : sim_instances) {
		s->top->final();
#ifdef SIM_SDRAM_REAL
		if (SDRAM(*s, ss_conflicts)) {
			printf("FAIL: SDRAM %s has %llu protocol/timing violations\n", s->top->name(),
				(unsigned long long)SDRAM(*s, ss_conflicts));
			rc = 1;
		}
#endif
	}
	fflush(stdout);
	fflush(stderr);
	_exit(rc);
}

// --freeze-at: "C" = C clk_sys cycles from now, "$ADDR" = opcode fetch at ADDR
static void run_to(Sim &s, const char *at) {
	if (at[0] == '$') {
		uint32_t a = strtoul(at + 1, nullptr, 16);
		u64 n = 0;
		while (!(EMO(s, c64_cpu_sync) && EMO(s, c64_addr) == a)) {
			s.step();
			if (++n > 400000000ull) { printf("FAIL: PC $%04X not reached\n", a); finish(1); }
		}
		printf("CPU at $%04X (clk_sys %llu)\n", a, (unsigned long long)s.sys_cycles);
	}
	else for (u64 i = 0, n = strtoull(at, nullptr, 0); i < n; i++) s.step();
}

static void write_file(const char *path, const std::vector<uint8_t> &v) {
	FILE *f = fopen(path, "wb");
	if (!f) { fprintf(stderr, "cannot write %s\n", path); finish(2); }
	fwrite(v.data(), 1, v.size(), f);
	fclose(f);
}

static const char *ss_result_name(int r) {
	static const char *n[] = {"ok", "forced boundary", "too big", "empty slot", "version", "config", "CRC/structure", "inhibit", "timeout"};
	return r < 0 ? (r == -1 ? "harness timeout" : "not started") : r < 9 ? n[r] : "?";
}

static void run_frames(Sim &s, int n) {
	u64 f = s.frames;
	while (s.frames < f + n) s.step();
}

static int run_main(int argc, char **argv) {
	Verilated::commandArgs(argc, argv);
	setvbuf(stdout, nullptr, _IOLBF, 0);
	for (int i = 1; i < argc; i++) {
		if (!strcmp(argv[i], "--opl")) g_opl = true;
		if (!strcmp(argv[i], "--clk50")) g_clk50 = true;
		if (!strcmp(argv[i], "--no-cache")) g_cache = false;
		if (!strcmp(argv[i], "--trace-drive")) g_trace_drive = true;
	}
	const char *mode = argc > 1 ? argv[1] : "boot";
	int max_frames = atoi(arg(argc, argv, "--max-frames", "400"));
	const char *prg = arg(argc, argv, "--prg", nullptr);
	const char *tap = arg(argc, argv, "--tap", nullptr);
	const char *text = arg(argc, argv, "--type", nullptr);
	g_kbuf = arg(argc, argv, "--kbuf", nullptr);
	g_ram_prg = arg(argc, argv, "--ram-prg", nullptr);
	g_disk = arg(argc, argv, "--disk", nullptr);
	g_status = arg(argc, argv, "--status", nullptr);
	g_status_ready = arg(argc, argv, "--status-ready", nullptr);
	// NTSC crosses CLK_50M before it reaches the VIC, even with fixed PLL frequencies.
	for (const char *p = g_status; p && *p;) {
		if (atoi(p) == 2) g_clk50 = true;
		while (*p && *p != ',') p++;
		if (*p) p++;
	}
	g_fifo_sync = atoi(arg(argc, argv, "--fifo-sync", "3"));
	if (g_fifo_sync != 0 && g_fifo_sync != 2 && g_fifo_sync != 3) {
		fprintf(stderr, "--fifo-sync must be 0, 2 or 3\n"); finish(2);
	}

	if (!strcmp(mode, "boot")) {
		Sim s("a", g_opl, g_clk50);
		s.sd_trace = g_trace_drive;
		apply_status(s);
		double t0 = now();
		const char *slot_in = arg(argc, argv, "--load-slot", nullptr);
		if (const char *load_at = arg(argc, argv, "--load-at", nullptr)) {
			// a load right after power on: no READY, the slot goes in as soon as
			// the engine takes it from clk_sys C on (it refuses during the reset
			// and the RAM erase); output sync checked from two frames after power
			// on to four frames after the resume
			if (!slot_in) { printf("FAIL: --load-at needs --load-slot\n"); finish(2); }
			s.put_slot(0, read_file(slot_in));
			for (u64 c = strtoull(load_at, nullptr, 0); s.sys_cycles < c;) {
				s.step();
				if (s.sys_cycles == 2 * s.frame_cycles()) s.sm.on = true;
			}
			s.sm.on = true;
			int r, tries = 1;
			u64 c0 = s.sys_cycles;
			while (((r = s.ss_op(103, [] {})) == 7 || r == -2) && tries < 200) { tries++; run_frames(s, 1); c0 = s.sys_cycles; }
			printf("load %s right after power on: %s at clk_sys %llu (attempt %d, %llu clk_sys)\n", slot_in, ss_result_name(r),
				(unsigned long long)c0, tries, (unsigned long long)(s.sys_cycles - c0));
			run_frames(s, 4);
			bool ok = s.sync_report();
			printf("%s: load right after power on\n", r == 0 && ok ? "PASS" : "FAIL");
			finish(r == 0 && ok ? 0 : 1);
		}
		reach_ready(s, max_frames, true);
		load(s, prg, tap, text, true);
		const char *freeze_at = arg(argc, argv, "--freeze-at", nullptr);
		const char *slot_out = arg(argc, argv, "--slot", nullptr);
		if (slot_in) {
			s.put_slot(0, read_file(slot_in));
			u64 c0 = s.sys_cycles;
			int r = s.ss_op(103, [] {});
			printf("load %s: %s (%llu clk_sys)\n", slot_in, ss_result_name(r), (unsigned long long)(s.sys_cycles - c0));
		}
		if (freeze_at) {
			run_to(s, freeze_at);
			u64 c0 = s.sys_cycles;
			int r = s.ss_op(102, [&] { printf("frozen at clk_sys %llu\n", (unsigned long long)s.sys_cycles); });
			printf("save: %s (%llu clk_sys), crc %08x\n", ss_result_name(r), (unsigned long long)(s.sys_cycles - c0), (unsigned)EMO(s, ss_crc));
			if (slot_out) {
				write_file(slot_out, s.slot_image(0));
				printf("slot written to %s\n", slot_out);
			}
		}
		u64 extra = strtoull(arg(argc, argv, "--run-cycles", "0"), nullptr, 0);
		int old_led = -1, old_trk = -1;
		for (u64 i = 0; i < extra || !s.keys.empty(); i++) {
			s.step();
			// drive 8 activity LED and head (half tracks), to place savestates in a disk load
			int led = EMO(s, drive_led) & 1, trk = EMO(s, drive_track)[0];
			if (g_trace_drive && (led != old_led || trk != old_trk)) {
				printf("clk_sys %llu: drive 8 led %d track %d%s\n", (unsigned long long)s.sys_cycles, led, trk / 2 + 1, (trk & 1) ? ".5" : "");
				old_led = led; old_trk = trk;
			}
		}
		// let one more full frame be captured
		u64 f = s.frames;
		while (s.frames < f + 2) s.step();
		const char *shot = arg(argc, argv, "--shot", "screen.ppm");
		if (s.save_ppm(shot)) printf("screenshot %s\n", shot);
		s.screen_text(stdout);
		double dt = now() - t0;
		printf("total %llu clk_sys cycles in %.1f s: %.0f clk_sys/s, %.0f C64 cycles/s\n",
			(unsigned long long)s.sys_cycles, dt, s.sys_cycles / dt, s.sys_cycles / 32 / dt);
		finish(0);
	}

	if (!strcmp(mode, "sstest")) {
		Sim s("a", g_opl, g_clk50);
		apply_status(s);
		reach_ready(s, max_frames, true);
		apply_status(s, g_status_ready);
		s.sm.on = true;   // output sync regular across the save, the load and the self-test
		bool pass = true;
		auto fail = [&](const char *m) { printf("FAIL: %s\n", m); pass = false; };

		// 1. save
		run_to(s, arg(argc, argv, "--freeze-at", "200000"));
		std::vector<uint8_t> ram0(65536), cram0(1024);
		u64 c0 = s.sys_cycles;
		int r = s.ss_op(102, [&] {
			for (int i = 0; i < 65536; i++) ram0[i] = s.ram(i);
			for (int i = 0; i < 1024; i++) cram0[i] = s.cram(i);
		});
		uint32_t crc_save = EMO(s, ss_crc);
		printf("save: %s in %llu clk_sys (%.1f ms), crc %08x, DDR3 %llu writes\n", ss_result_name(r),
			(unsigned long long)(s.sys_cycles - c0), (s.sys_cycles - c0) / 31527.954, crc_save, (unsigned long long)s.ddr_wr);
		if (r != 0) fail("save");
		std::vector<uint8_t> img = s.slot_image(0);
		const char *slot_out = arg(argc, argv, "--slot", "sstest_slot.ss");
		write_file(slot_out, img);
		printf("slot image %zu bytes -> %s\n", img.size(), slot_out);
		// RAM and Color RAM regions of the image = the machine at the freeze
		for (size_t p = 24; p + 8 <= img.size();) {
			uint32_t tag = img[p], len = img[p + 4] | img[p + 5] << 8 | img[p + 6] << 16 | (uint32_t)img[p + 7] << 24;
			if (!tag) break;
			if (tag == 1 && (len != 65536 || memcmp(&img[p + 8], ram0.data(), 65536))) fail("RAM region differs from the RAM at the freeze");
			if (tag == 2) for (int i = 0; i < 1024; i++) if (img[p + 8 + i] != cram0[i]) { fail("Color RAM region differs"); break; }
			p += 8 + (len + 7) / 8 * 8;
		}

		// 2. screenshot A
		run_frames(s, 3);
		auto frame_a = s.lines_done;
		s.save_ppm("sstest_a.ppm");
		printf("screen A (after the save):\n");
		s.screen_text(stdout);

		// 3. change RAM and Color RAM: a PRG (status 50 = no reset, --kbuf starts it) or pokes
		if (prg) {
			// straight into RAM (no ioctl: with "Reset & Run PRG" off the core's
			// RAM-init sequence races the PRG header in the harness)
			poke_prg(s, prg, true);
			load(s, nullptr, nullptr, nullptr, true);   // --kbuf starts it
		}
		else {
			for (int i = 0; i < 1000; i++) s.poke_ram(0x400 + i, 0x18);
			for (int i = 0; i < 1000; i++) EMO(s, fpga64__DOT__colorram__DOT__ram)[i] = 2;
			printf("screen and Color RAM poked by the harness\n");
		}
		run_frames(s, 4);
		s.save_ppm("sstest_b.ppm");
		printf("screen B (changed):\n");
		s.screen_text(stdout);
		int dram = 0, dcram = 0;
		for (int i = 0; i < 65536; i++) dram += s.ram(i) != ram0[i];
		for (int i = 0; i < 1024; i++) dcram += s.cram(i) != cram0[i];
		printf("before the load: %d RAM bytes and %d Color RAM nibbles differ from the save\n", dram, dcram);
		if (!dram || !dcram) fail("the change did not touch RAM and Color RAM");

		// D3: a key held down across the load must not reach the C64 afterwards
		// (the load releases every key): press A, no break until screenshot C
		s.ps2(0x1C, true);
		for (int i = 0; i < 20000; i++) s.step();

		// 4. load: compare at the end of the load, machine still frozen
		c0 = s.sys_cycles;
		r = s.ss_op(103, [] {});
		printf("load: %s in %llu clk_sys (%.1f ms), verified crc %08x\n", ss_result_name(r),
			(unsigned long long)(s.sys_cycles - c0), (s.sys_cycles - c0) / 31527.954, (unsigned)EMO(s, ss_crc));
		if (r != 0) fail("load");
		dram = 0; dcram = 0;
		for (int i = 0; i < 65536; i++) dram += s.ram(i) != ram0[i];
		for (int i = 0; i < 1024; i++) dcram += s.cram(i) != cram0[i];
		printf("after the load: %d RAM bytes and %d Color RAM nibbles differ from the save\n", dram, dcram);
		if (dram || dcram) fail("RAM/Color RAM not restored");

		// 5. screenshot C = A
		run_frames(s, 3);
		s.save_ppm("sstest_c.ppm");
		printf("screen C (after the load):\n");
		s.screen_text(stdout);
		s.ps2(0x1C, false);
		auto &frame_c = s.lines_done;
		size_t diff = 0, total = 0;
		if (frame_a.size() != frame_c.size()) fail("frame size differs");
		else for (size_t y = 0; y < frame_a.size(); y++) {
			size_t w = std::min(frame_a[y].size(), frame_c[y].size());
			total += w;
			for (size_t x = 0; x < w; x++) diff += frame_a[y][x] != frame_c[y][x];
		}
		printf("screenshot C vs A: %zu of %zu pixels differ\n", diff, total);
		if (diff) fail("restored screen differs from the saved one");

		// 6. OSD self-test: save/save and save/load/save on the scratch slot
		s.osd(104);
		c0 = s.sys_cycles;
		bool done = false;
		for (u64 i = 0; i < 1000000000ull && !done; i++) {
			s.step();
			if (EMO(s, ss_test_done)) done = true;
		}
		bool tp = done && EMO(s, ss_test_pass);
		u64 c1 = s.sys_cycles;
		run_frames(s, 1);
		printf("self-test: %s in %llu clk_sys, OSD message %d\n", done ? (tp ? "PASS" : "FAIL") : "timeout",
			(unsigned long long)(c1 - c0), (int)EMO(s, hps_io__DOT__o_info));
		if (!tp) fail("self-test");
		run_frames(s, 3);   // past the video-aligned resume after the self-test
		if (!s.sync_report()) fail("output sync across the load and the self-test");
		printf("%s: sstest\n", pass ? "PASS" : "FAIL");
		finish(pass ? 0 : 1);
	}

	if (!strcmp(mode, "ssdiff")) {
		u64 t0c = strtoull(arg(argc, argv, "--t0", "100000"), nullptr, 0);
		u64 t1c = strtoull(arg(argc, argv, "--t1", "2000000"), nullptr, 0);   // a save takes ~600k clk_sys
		u64 after = strtoull(arg(argc, argv, "--after", "2000000"), nullptr, 0);
		const char *slot_out = arg(argc, argv, "--slot", nullptr);
		Sim a("a", g_opl, g_clk50), b("b", g_opl, g_clk50);
		apply_status(a);
		reach_ready(a, max_frames, true);
		std::string bstate = "ssdiff_b_" + std::to_string(getpid()) + ".state";   // parallel runs share the directory
		a.save(bstate.c_str());   // B starts as an exact copy of A
		b.restore(bstate.c_str());
		b.copy_host(a);
		unlink(bstate.c_str());
		load(a, prg, tap, text, true);
		load(b, prg, tap, text, false);
		if (a.sys_cycles != b.sys_cycles) { printf("FAIL: runs differ before the test\n"); finish(1); }
		a.sm.on = b.sm.on = true;   // output sync of both: A never stops, B saves, loads and pauses
		a.sm.log = false;
		u64 base = b.sys_cycles, idx = 0;
		std::deque<u64> qa, qb;
		const char *phase = "before";
		// --rewind: B saves slot 2 at C0, runs on to C1, loads slot 2 and resumes.
		// From there B must replay A's samples from C0 (rec): registers rebuilt
		// at the load must come from the loaded state, not from the one at C1.
		bool rewind = has(argc, argv, "--rewind"), rec_armed = false, rewound = false;
		std::vector<u64> rec;
		u64 a_count = 0, b_count = 0, s0 = ~0ull, rj = 0;
		bool mouse = has(argc, argv, "--mouse"), turbo_check = has(argc, argv, "--turbo-check");
		bool paddles = has(argc, argv, "--paddles"), mouse_freeze = has(argc, argv, "--mouse-freeze");
		std::vector<u64> frozen_events;
		size_t frozen_delivered = 0;
		int frozen_op = 0;
		u64 frozen_clocks = 0, pot_writes[2][2] = {};
		unsigned pot_min[2] = {255, 255}, pot_max[2] = {};
		auto frozen_packet = [](Sim &s, size_t n) {
			uint32_t &packet = EMO(s, hps_io__DOT__h_ps2_mouse);
			packet = ((packet ^ (1u << 24)) & (1u << 24)) |
			         ((n ? 11u : 7u) << 8) | ((n ? 5u : 3u) << 16);
		};
		u64 mouse_events[2] = {}, turbo_fast[2] = {}, last_cpu = 0;
		auto mouse_input = [&](Sim &s, u64 count, int which) {
			// Packets follow emulated running time, not the host time spent saving.
			if (mouse && s.running() && count / 8192 > mouse_events[which]) {
				uint32_t &packet = EMO(s, hps_io__DOT__h_ps2_mouse);
				packet = ((packet ^ (1u << 24)) & (1u << 24)) |
				         (((count / 8192) & 31) + 1) << 8 | (3u << 16);
				mouse_events[which]++;
			}
			if (paddles && s.running()) {
				EMO(s, hps_io__DOT__h_paddle0) = 17 + 29 * (count / 8192);
				EMO(s, hps_io__DOT__h_paddle1) = 231 - 13 * (count / 8192);
				EMO(s, hps_io__DOT__h_paddle2) = 43 + 7 * (count / 8192);
				EMO(s, hps_io__DOT__h_paddle3) = 193 - 19 * (count / 8192);
			}
			if (mouse_freeze && which == 0 && frozen_delivered < frozen_events.size() &&
			    count == frozen_events[frozen_delivered]) frozen_packet(s, frozen_delivered++);
		};
		double tstart = now();
		u64 held = 0;   // clocks of B checked while the engine owned the machine
		// --opl: after B's first load the FM part plays on from its own state with
		// the registers that differ queued again (A9), not from the saved one; from
		// there the audio bits are left out and the OPL checks replace them
		const u64 AUDIO = 0xFFFFull << 40;
		u64 opl_mask = ~0ull, opl_t0 = 0, opl_drained = ~0ull, opl_sound = ~0ull;
		int opl_regs_bad = -1, opl_latch_bad = -1;   // at the drain: FM registers != B's shadow, FM index latch != index
		// --opl (D9): the sound after B's first load against A's, in 10 ms
		// windows: level (RMS around the mean) of each, energy of the difference
		struct {
			const u64 W = 315280;   // 10 ms of clk_sys samples
			double sa = 0, sa2 = 0, sb = 0, sb2 = 0, sd2 = 0, ea = 0, ed = 0, worst = 0;
			u64 n = 0, win = 0, worst_win = 0, last_off = 0, differ = 0, total = 0;
			void add(u64 a, u64 b) {
				double x = (int16_t)(a >> 40), y = (int16_t)(b >> 40);
				sa += x; sa2 += x * x; sb += y; sb2 += y * y; sd2 += (x - y) * (x - y);
				differ += x != y;
				total++;
				if (++n < W) return;
				double va = sa2 / n - sa / n * (sa / n), vb = sb2 / n - sb / n * (sb / n);
				double db = va > 0 && vb > 0 ? 10 * log10(vb / va) : va == vb ? 0 : 99;
				if (fabs(db) > fabs(worst)) { worst = db; worst_win = win; }
				if (fabs(db) > 1) last_off = win + 1;
				ea += va * n; ed += sd2;
				sa = sa2 = sb = sb2 = sd2 = 0; n = 0; win++;
			}
		} snd;
		// A depends only on its own clocks: it runs at most LAG samples ahead of
		// B's comparisons, so a save of seconds (GeoRAM) does not queue them all
		const size_t LAG = 1u << 20;
		auto lockstep = [&] {
			// Keep A behind B here so the frozen event's running timestamp is known.
			bool step_a = (rewound || qa.size() <= LAG) && (!mouse_freeze || a_count + 256 < b_count);
			if (frozen_op && EMO(b, ss_frz_ack) && ++frozen_clocks == 128) {
				frozen_events.push_back(b_count);
				frozen_packet(b, frozen_events.size() - 1);
				printf("mouse freeze: packet %zu during %s, hold clock %llu, running sample %llu\n",
					frozen_events.size(), phase, (unsigned long long)frozen_clocks, (unsigned long long)b_count);
				frozen_op = 0;
			}
			if (step_a) { mouse_input(a, a_count, 0); a.step(); }
			mouse_input(b, rewound ? s0 + rj : b_count, 1);
			b.step();
			if (turbo_check && step_a && a.running() && EMO(a, fpga64__DOT__enablecpu)) {
				if (last_cpu && a_count - last_cpu < 32) turbo_fast[!strcmp(phase, "after")]++;
				last_cpu = a_count;
			}
			if (opl_t0) {   // after the resume: B's register queue consumed, then sound
				u64 c = b.sys_cycles - opl_t0;
				if (opl_drained == ~0ull && b.opl_queue_empty()) {
					// queue empty: the firmware has every register the C64 side holds
					opl_drained = c;
					opl_latch_bad = b.oplidx != (EMO(b, opl_inst__DOT__index) & 0xFF);
					opl_regs_bad = 0;
					for (int i = 0; i < 256; i++) opl_regs_bad += b.oplreg[i] != EMO(b, opl_inst__DOT__shadow)[i];
				}
				if (opl_drained != ~0ull && opl_sound == ~0ull && EMO(b, opl_s)) opl_sound = c;
			}
			// registers left off the chain (state_classes.yaml 'rebuilt'): they
			// must hold these values whenever the engine owns the machine
			if (EMO(b, ss_frz_ack)) {
				held++;
				const char *bad =
					EMO(b, fpga64__DOT__sysenable) ? "sysEnable" : EMO(b, fpga64__DOT__rfsh_cycle) ? "rfsh_cycle" :
					EMO(b, fpga64__DOT__reset) ? "reset" : EMO(b, fpga64__DOT__phi0_cpu) ? "phi0_cpu" :
					EMO(b, fpga64__DOT__cpuhasbus) ? "cpuHasBus" : !EMO(b, fpga64__DOT__io_enable) ? "io_enable" :
					EMO(b, fpga64__DOT__cpu_cyc_s) ? "cpu_cyc_s" : EMO(b, fpga64__DOT__pulsewr_io) ? "pulseWr_io" :
					EMO(b, fpga64__DOT__enablecpu) ? "enableCpu" : EMO(b, fpga64__DOT__enablevic) ? "enableVic" :
					EMO(b, fpga64__DOT__enablecia_n) ? "enableCia_n" : EMO(b, fpga64__DOT__enablecia_p) ? "enableCia_p" :
					EMO(b, fpga64__DOT__enablesid) ? "enableSid" : EMO(b, fpga64__DOT__enablepixel) ? "enablePixel" :
					!EMO(b, fpga64__DOT__cpu__DOT__cpu__DOT__res_n_i) ? "T65 Res_n_i" :
					!EMO(b, fpga64__DOT__cpu__DOT__cpu__DOT__res_n_d) ? "T65 Res_n_d" :
					!EMO(b, reset_n) ? "reset_n" : EMO(b, reset_wait) ? "reset_wait" :
					EMO(b, ioe_we) ? "ioe_we" : EMO(b, iof_we) ? "iof_we" : EMO(b, drive_ce) ? "drive_ce" : nullptr;
				if (bad) { printf("FAIL: %s off its rebuilt value while frozen for the engine (%s)\n", bad, phase); finish(1); }
			}
			if (rec_armed && s0 == ~0ull && !b.running()) s0 = b_count;
			if (step_a && a.running()) {
				u64 s = a.sample();
				if (!rewound) qa.push_back(s);
				if (s0 != ~0ull && a_count >= s0) rec.push_back(s);
				a_count++;
			}
			if (b.running()) {
				u64 s = b.sample();
				if ((paddles || mouse_freeze) && EMO(b, ram_we) && EMO(b, ram_ce) &&
				    (EMO(b, c64_addr) == 0x0400 || EMO(b, c64_addr) == 0x0401)) {
					unsigned axis = EMO(b, c64_addr) & 1, value = EMO(b, c64_data_out);
					pot_writes[!strcmp(phase, "after")][axis]++;
					pot_min[axis] = std::min(pot_min[axis], value);
					pot_max[axis] = std::max(pot_max[axis], value);
				}
				b_count++;
				if (rewound) {
					if (rj >= rec.size()) { printf("FAIL: B ran past the recorded samples of A\n"); finish(1); }
					if ((rec[rj] ^ s) & (g_opl ? ~AUDIO : ~0ull)) {   // --opl: B plays from the replay
						printf("FAIL: rewind divergence at sample %llu after C0 (B clk +%llu, %s): A=%016llx B=%016llx\n",
							(unsigned long long)rj, (unsigned long long)(b.sys_cycles - base), phase,
							(unsigned long long)rec[rj], (unsigned long long)s);
						printf("sample bits: 15:0 addr, 23:16 data, 24 ram_we, 25 ram_ce, 26 todclk, 27 cass_read, 28 cass_motor, 29 cass_sense, 39:30 rgb hash, 55:40 audio\n");
						finish(1);
					}
					if (g_opl) snd.add(rec[rj], s);
					rj++;
				}
				else qb.push_back(s);
			}
			while (!qa.empty() && !qb.empty()) {
				if ((qa.front() ^ qb.front()) & (idx >= opl_mask ? ~AUDIO : ~0ull)) {
					printf("FAIL: divergence at running sample %llu (B clk +%llu, %s): A=%016llx B=%016llx\n",
						(unsigned long long)idx, (unsigned long long)(b.sys_cycles - base), phase,
						(unsigned long long)qa.front(), (unsigned long long)qb.front());
					printf("sample bits: 15:0 addr, 23:16 data, 24 ram_we, 25 ram_ce, 26 todclk, 27 cass_read, 28 cass_motor, 29 cass_sense, 39:30 rgb hash, 55:40 audio\n");
					finish(1);
				}
				if (g_opl && idx >= opl_mask) snd.add(qa.front(), qb.front());
				qa.pop_front(); qb.pop_front(); idx++;
			}
		};
		auto run_to_c = [&](u64 c) { while (b.sys_cycles - base < c) lockstep(); };
		auto run_gap = [&](u64 n) { for (u64 c = b_count + n; b_count < c;) lockstep(); };
		// one savestate operation of B on slot index n (OSD option "Savestate Slot" = n+1)
		auto b_op = [&](int n, int bit, const char *what, int expected = 0) {
			phase = what;
			b.set_status_bit(100, n & 1);
			b.set_status_bit(101, n >> 1);
			for (int i = 0; i < 64; i++) lockstep();
			b.osd(bit);
			u64 c0 = b.sys_cycles;
			bool seen = false;
			for (u64 i = 0; i < 400000000ull; i++) {
				lockstep();
				if (EMO(b, ss_busy)) seen = true;
				if (EMO(b, ss_done)) {
					int r = EMO(b, ss_result);
					printf("B %s slot %d: %s in %llu clk_sys, crc %08x\n", what, n + 1, ss_result_name(r),
						(unsigned long long)(b.sys_cycles - c0), (unsigned)EMO(b, ss_crc));
					if (r != expected) { printf("FAIL: %s returned %d, expected %d\n", what, r, expected); finish(1); }
					if (g_opl && bit == 103 && opl_mask == ~0ull) opl_mask = b_count;
					return;
				}
				if (!seen && i > 100000) break;
			}
			printf("FAIL: %s did not complete\n", what);
			finish(1);
		};
		auto b_pause = [&](bool on) {
			b.ps2(0x177, true);   // Pause/Break toggles the user pause
			for (u64 i = 0; EMO(b, c64_pause) != on; i++) {
				lockstep();
				if (i > 2000000) { printf("FAIL: user pause %s\n", on ? "not taken" : "not released"); finish(1); }
			}
		};
		// --opl, after the resume: B's queue consumed within one frame, then the
		// firmware's registers and index latch equal B's C64 side, and at the end
		// A's and B's register files equal (both past the end of the music)
		auto opl_checks = [&] {
			if (!g_opl) return;
			int nz = 0, diff = 0;
			for (int i = 0; i < 256; i++) {
				nz += a.oplreg[i] != 0;
				if (a.oplreg[i] != b.oplreg[i]) { diff++; printf("OPL register $%02X: A %02X, B %02X\n", i, a.oplreg[i], b.oplreg[i]); }
			}
			printf("OPL: after the resume B's register queue was consumed in %llu clk_sys, the OPL output was back after %llu (one frame: %llu; FIFO sync %d)\n",
				(unsigned long long)opl_drained, (unsigned long long)opl_sound, (unsigned long long)b.frame_cycles(), g_fifo_sync);
			printf("OPL: then the registers the FM firmware took %s B's register shadow (%d differ), its index latch %s the C64 index register\n",
				opl_regs_bad ? "differ from" : "equal", opl_regs_bad, opl_latch_bad ? "differs from" : "equals");
			printf("OPL: register files of A and B as the FM firmware took them: %s, %d registers non-zero\n", diff ? "differ" : "equal", nz);
			printf("OPL sound after the load (D9): %llu of %llu samples differ from A, difference energy %+.1f dB re A's sound; "
				"level of B within 1 dB of A's in every 10 ms window from %llu ms on, worst %+.1f dB in the window at %llu ms (%llu windows)\n",
				(unsigned long long)snd.differ, (unsigned long long)snd.total, snd.ea > 0 ? 10 * log10(snd.ed / snd.ea) : 0.0,
				(unsigned long long)snd.last_off * 10, snd.worst, (unsigned long long)snd.worst_win * 10, (unsigned long long)snd.win);
			if (opl_sound > b.frame_cycles() || opl_regs_bad || opl_latch_bad || diff || !nz) { printf("FAIL: OPL replay\n"); finish(1); }
		};
		auto pot_checks = [&] {
			if (!paddles && !mouse_freeze) return;
			for (int axis = 0; axis < 2; axis++) {
				printf("POT%c: CPU screen writes %llu before / %llu after resume, range %u..%u\n",
					axis ? 'Y' : 'X', (unsigned long long)pot_writes[0][axis],
					(unsigned long long)pot_writes[1][axis], pot_min[axis], pot_max[axis]);
				if (!pot_writes[0][axis] || !pot_writes[1][axis] || pot_min[axis] == pot_max[axis]) {
					printf("FAIL: pot input not exercised through CPU reads\n"); finish(1);
				}
			}
		};
		// B's output sync regular and its resolution unchanged across every
		// stop and load (A, never stopped, proves the expected periods)
		auto sync_checks = [&] {
			bool ok = b.sync_report();
			if (a.sm.bad || a.sm.sizes) { printf("FAIL: A's output sync is irregular\n"); ok = false; }
			if (!ok) { printf("FAIL: output sync across the savestate operations\n"); finish(1); }
		};
		if (mouse_freeze) {
			run_to_c(t0c);
			frozen_op = 1;
			b_op(1, 102, "save with packet");
			run_to_c(t1c);
			phase = "pause";
			b_pause(true);
			b_op(0, 102, "save");
			frozen_op = 1;
			frozen_clocks = 0;
			b_op(0, 103, "load with packet");
			phase = "resume";
			b_pause(false);
			phase = "after";
			u64 resumed = b_count;
			while (b_count - resumed < after + 257) lockstep();
			pot_checks();
			if (frozen_events.size() != 2 || frozen_delivered != 2) {
				printf("FAIL: frozen mouse packets were not delivered to both instances\n"); finish(1);
			}
			sync_checks();
			printf("PASS: mouse freeze, 2 packets applied after engine release; %llu running samples identical, "
				"%llu after resume; rebuilt registers checked on %llu frozen clocks\n",
				(unsigned long long)idx, (unsigned long long)(idx - resumed), (unsigned long long)held);
			finish(0);
		}

		if (const char *reject = arg(argc, argv, "--reject", nullptr)) {
			int expected = !strcmp(reject, "crc") ? 6 : (!strcmp(reject, "version") || !strcmp(reject, "chain")) ? 4 : 5;
			bool reu_off = !strcmp(reject, "reu-off"), reu_on = !strcmp(reject, "reu-on");
			bool video_standard = !strcmp(reject, "video-standard");
			if (expected == 5 && !reu_off && !reu_on && !video_standard) { printf("FAIL: unknown --reject %s\n", reject); finish(2); }
			if ((reu_off && !b.status_bit(53)) || (reu_on && b.status_bit(53))) {
				printf("FAIL: --reject %s has the wrong power-on REU configuration\n", reject); finish(2);
			}
			run_to_c(t0c);
			phase = "pause";
			b_pause(true);
			b_op(0, 102, "save");
			if (reu_off || reu_on) {
				a.set_status_bit(53, reu_on);
				b.set_status_bit(53, reu_on);
			} else if (video_standard) {
				const char *slot_in = arg(argc, argv, "--load-slot", nullptr);
				if (!slot_in) { printf("FAIL: video-standard needs --load-slot\n"); finish(2); }
				uint32_t config = b.ddr_word(b.slot_base(0) + 2) >> 32;
				b.put_slot(0, read_file(slot_in));
				if (((b.ddr_word(b.slot_base(0) + 2) >> 32) ^ config) != (1u << 7)) {
					printf("FAIL: foreign slot must differ only in PAL/NTSC configuration\n"); finish(1);
				}
			} else if (!strcmp(reject, "crc")) b.ddr_word(b.slot_base(0) + 2) ^= 1;
			else b.ddr_word(b.slot_base(0) + 1) ^= !strcmp(reject, "version") ? 1ull : 1ull << 16;
			// A second save before and after refusal catches silent chain/RAM writes.
			b_op(1, 102, "save before refusal");
			auto before = b.slot_image(1);
			auto info_count = EMO(b, hps_io__DOT__o_info_cnt);
			b_op(0, 103, "refused load", expected);
			for (int i = 0; i < 64; i++) lockstep();
			int info = EMO(b, hps_io__DOT__o_info);
			if (EMO(b, hps_io__DOT__o_info_cnt) == info_count || info != 13 + expected) {
				printf("FAIL: refusal info %d, expected %d\n", info, 13 + expected); finish(1);
			}
			b_op(2, 102, "save after refusal");
			auto unchanged = b.slot_image(2);
			if (before.size() != unchanged.size() || memcmp(before.data() + 8, unchanged.data() + 8, before.size() - 8)) {
				printf("FAIL: refused load changed the live chain or memory\n"); finish(1);
			}
			phase = "resume";
			b_pause(false);
			u64 resumed_samples = b_count;
			phase = "after";
			while (b_count - resumed_samples < after) lockstep();
			sync_checks();
			printf("PASS: %s refused, result %d (%s), info %d; chain/RAM unchanged, %llu running samples identical (%llu after refusal)\n",
				reject, expected, ss_result_name(expected), info, (unsigned long long)idx, (unsigned long long)after);
			finish(0);
		}

		if (has(argc, argv, "--slotphase")) {
			u64 gap = strtoull(arg(argc, argv, "--gap", "1000000"), nullptr, 0);
			run_to_c(t0c);
			rec_armed = true;
			b_op(1, 102, "snapshot C0");
			u64 m0 = s0;
			run_gap(gap);
			b_op(2, 102, "snapshot C1");
			u64 m1 = b_count;
			run_gap(gap);
			b_op(3, 102, "snapshot C2");
			run_gap(gap);
			auto load = [&](int slot, u64 moment) {
				b_pause(true);
				b_op(0, 102, "memory before slot load");
				b_op(slot, 103, "phase-discontinuous slot load");
				rewound = true;
				rj = moment - s0;
				b_op(0, 102, "memory after slot load");
				b_pause(false);
				run_gap(gap);
			};
			load(2, m1);
			load(1, m0);
			b_pause(true);
			b_pause(false);
			while (rj < after) lockstep();
			sync_checks();
			printf("PASS: manual-slot phase changes and re-pause, %llu replay samples equal A\n", (unsigned long long)rj);
			finish(0);
		}

		if (rewind) {
			// --running: the load comes while B runs (hotkey, or the OSD without
			// Pause When OSD is Open), no user pause around it; --repause: and the
			// user pause is pressed as the load ends, before the video-aligned resume
			bool repause = has(argc, argv, "--repause"), running = repause || has(argc, argv, "--running");
			run_to_c(t0c);
			rec_armed = true;
			b_op(1, 102, "save");      // slot 2: state at C0, A's samples recorded from here
			if (slot_out) write_file((std::string(slot_out) + "2.ss").c_str(), b.slot_image(1));
			run_to_c(t1c);
			phase = "pause";
			if (!running) b_pause(true);
			b_op(1, 103, "load");      // back to C0
			rewound = true;
			phase = "resume";
			if (repause) {
				b.ps2(0x177, true);
				for (u64 c = b.sys_cycles + 2 * b.frame_cycles(); b.sys_cycles < c;) lockstep();
				if (!EMO(b, user_pause) || !EMO(b, c64_pause)) { printf("FAIL: user pause right after the load not taken\n"); finish(1); }
				b_pause(false);
			}
			else if (!running) b_pause(false);
			phase = "after";
			if (g_opl) opl_t0 = b.sys_cycles;
			while (rj < after) lockstep();
			opl_checks();
			sync_checks();
			printf("PASS: rewind%s, %llu samples after the load equal A's from C0 (%llu recorded)\n",
				repause ? " (load while running, user pause right after it)" : running ? " (load while running)" : "",
				(unsigned long long)rj, (unsigned long long)rec.size());
			finish(0);
		}

		run_to_c(t0c);
		b_op(1, 102, "save");          // slot 2: the scrambler, state at C0
		run_to_c(t1c);
		phase = "pause";
		b_pause(true);                 // stays stopped across the next three operations
		b_op(0, 102, "save");          // slot 1: the state to come back to
		std::vector<uint8_t> s1 = b.slot_image(0), s2 = b.slot_image(1);
		size_t dbits = 0;
		for (size_t i = 32; i < 32 + 256 * 8 && i < s1.size() && i < s2.size(); i++) dbits += __builtin_popcount(s1[i] ^ s2[i]);
		printf("slot 1 vs slot 2: %zu chain bits differ\n", dbits);
		if (!dbits) { printf("FAIL: the two slots hold the same chain, the load would prove nothing\n"); finish(1); }
		if (slot_out) {
			write_file((std::string(slot_out) + "1.ss").c_str(), s1);
			write_file((std::string(slot_out) + "2.ss").c_str(), s2);
		}
		if (has(argc, argv, "--build-hash")) {
			// The hash is metadata, outside the CRC; same-format board slots remain compatible.
			b.ddr_word(b.slot_base(0) + 1) ^= 1ull << 32;
			b.ddr_word(b.slot_base(1) + 1) ^= 1ull << 32;
		}
		b_op(1, 103, "load");          // older live state and RAM
		b_op(0, 103, "load");          // back to the save point
		b_op(2, 102, "save");          // slot 3 = slot 1 bit for bit (all but the change counter)
		std::vector<uint8_t> s3 = b.slot_image(2);
		if (s3.size() != s1.size() || memcmp(&s3[8], &s1[8], s1.size() - 8)) {
			if (slot_out) write_file((std::string(slot_out) + "3.ss").c_str(), s3);
			printf("FAIL: slot 3 saved after the load differs from slot 1\n");
			finish(1);
		}
		printf("slot 3 saved after the load = slot 1 (%zu bytes)\n", s1.size());
		phase = "resume";
		b_pause(false);
		phase = "after";
		u64 c_res = b.sys_cycles - base;
		if (g_opl) opl_t0 = b.sys_cycles;
		run_to_c(c_res + after);
		opl_checks();
		pot_checks();
		if (mouse) {
			printf("mouse: %llu/%llu moving packets delivered to A/B; POTX/POTY read by the PRG\n",
				(unsigned long long)mouse_events[0], (unsigned long long)mouse_events[1]);
			if (!mouse_events[0] || !mouse_events[1]) { printf("FAIL: no mouse movement\n"); finish(1); }
		}
		if (turbo_check) {
			printf("turbo: %llu accelerated CPU cycles before loads, %llu after resume\n",
				(unsigned long long)turbo_fast[0], (unsigned long long)turbo_fast[1]);
			if (!turbo_fast[0] || !turbo_fast[1]) { printf("FAIL: turbo never accelerated\n"); finish(1); }
		}
		if (has(argc, argv, "--build-hash")) printf("build hash: changed hash accepted, exact replay and saved state preserved\n");
		double dt = now() - tstart;
		sync_checks();
		printf("PASS: %llu running samples identical (%llu after the resume%s), rebuilt registers checked on %llu frozen clocks; %.0f clk_sys/s per instance\n",
			(unsigned long long)idx, (unsigned long long)after, g_opl ? ", audio up to the first load" : "", (unsigned long long)held,
			(b.sys_cycles - base) / dt);
		printf("B screen:\n");
		b.screen_text(stdout);
		finish(0);
	}

	if (!strcmp(mode, "pausetest")) {
		u64 t0c = strtoull(arg(argc, argv, "--t0", "200000"), nullptr, 0);
		int hold = atoi(arg(argc, argv, "--hold", "3"));
		u64 after = strtoull(arg(argc, argv, "--after", "2000000"), nullptr, 0);
		bool joy = !strcmp(arg(argc, argv, "--trigger", "key"), "joy");
		Sim a("a", g_opl, g_clk50), b("b", g_opl, g_clk50);
		apply_status(a);
		reach_ready(a, max_frames, true);
		std::string bstate = "pausetest_b_" + std::to_string(getpid()) + ".state";   // parallel runs share the directory
		a.save(bstate.c_str());   // B starts as an exact copy of A
		b.restore(bstate.c_str());
		b.copy_host(a);
		unlink(bstate.c_str());
		load(a, prg, tap, text, true);
		load(b, prg, tap, text, false);
		a.sm.on = b.sm.on = true;   // output sync and resolution across the pause (and the --load-slot loads)
		// --load-slot: both start from a slot image (e.g. saved on the board)
		if (const char *slot_in = arg(argc, argv, "--load-slot", nullptr)) {
			std::vector<uint8_t> img = read_file(slot_in);
			for (Sim *s : {&a, &b}) {
				s->put_slot(0, img);
				int r = s->ss_op(103, [] {});
				if (s == &a) printf("load %s: %s\n", slot_in, ss_result_name(r));
				if (r) finish(1);
			}
		}
		if (a.sys_cycles != b.sys_cycles) { printf("FAIL: runs differ before the pause\n"); finish(1); }
		a.vrec = b.vrec = true;
		std::deque<u64> qa, qb;
		u64 idx = 0, paused_cycles = 0, resumed_at = 0, pause_req_at = 0, release_at = 0;
		int phase = 0;  // 0 before, 1 requested, 2 paused, 3 released, 4 resumed
		u64 base = a.sys_cycles, fstart = 0;
		double tstart = now();
		auto press = [&](Sim &s, bool on) {
			if (joy) EMO(s, hps_io__DOT__h_joy0) = on ? (1u << 10) : 0;
			else if (on) s.ps2(0x177, true);  // Pause/Break: hps_io reports 0x377 (pressed, ext, 0x77)
		};
		u64 joy_release = 0;
		u64 a_read_edges = 0, a_motor_cycles = 0, a_opl_changes = 0;
		bool a_old_read = false;
		uint16_t a_old_opl = 0;
		for (;;) {
			a.step();
			b.step();
			u64 c = b.sys_cycles - base;
			if (phase == 0 && c == t0c) { press(b, true); joy_release = c + 2000; phase = 1; pause_req_at = c; }
			if (joy && joy_release && c == joy_release) { press(b, false); joy_release = 0; }
			if (phase == 1 && EMO(b, c64_pause)) { phase = 2; fstart = c; printf("B paused at +%llu (request at +%llu)\n", (unsigned long long)c, (unsigned long long)pause_req_at); }
			if (phase == 2) {
				// check that nothing visible moves while paused
				// Core video stops; use the selected VIC's line/frame dimensions.
				if (c >= fstart + (u64)hold * b.frame_cycles()) { press(b, true); joy_release = c + 2000; phase = 3; release_at = c; }
			}
			// from the request on: a --load-slot freeze before t0 is not the pause
			if (phase >= 1 && EMO(b, c64_pause) && EMO(b, reset_n)) paused_cycles++;
			if (phase == 3 && !EMO(b, c64_pause)) { phase = 4; resumed_at = c; printf("B resumed at +%llu (release at +%llu), paused for %llu clk_sys = %llu C64 cycles\n",
				(unsigned long long)c, (unsigned long long)release_at, (unsigned long long)paused_cycles, (unsigned long long)paused_cycles / 32); }
			if (phase == 2) {   // what B's frozen machine would have seen: A keeps running
				bool rd = EMO(a, cass_read);
				if (rd != a_old_read) a_read_edges++;
				a_old_read = rd;
				if (!EMO(a, cass_motor)) a_motor_cycles++;
				if (EMO(a, opl_s) != a_old_opl) { a_old_opl = EMO(a, opl_s); a_opl_changes++; }
			}
			if (a.running()) qa.push_back(a.sample());
			if (b.running()) qb.push_back(b.sample());
			while (!qa.empty() && !qb.empty()) {
				if (qa.front() != qb.front()) {
					printf("FAIL: divergence at running sample %llu (B clk +%llu, phase %d): A=%016llx B=%016llx\n",
						(unsigned long long)idx, (unsigned long long)c, phase,
						(unsigned long long)qa.front(), (unsigned long long)qb.front());
					printf("sample bits: 15:0 addr, 23:16 data, 24 ram_we, 25 ram_ce, 26 todclk, 27 cass_read, 28 cass_motor, 29 cass_sense, 39:30 rgb hash, 55:40 audio\n");
					printf("A screen:\n");
					a.screen_text(stdout);
					finish(1);
				}
				qa.pop_front(); qb.pop_front(); idx++;
			}
			if (phase == 4 && c >= resumed_at + after) break;
			if (c > t0c + 50000000ull) { printf("FAIL: pause/resume did not complete (phase %d)\n", phase); finish(1); }
		}
		double dt = now() - tstart;
		printf("PASS: %llu running samples identical, B shifted by %llu clk_sys (%llu C64 cycles, %d frames held); %.0f clk_sys/s per instance\n",
			(unsigned long long)idx, (unsigned long long)paused_cycles, (unsigned long long)paused_cycles / 32, hold,
			(b.sys_cycles - base) / dt);
		printf("while B was paused, A saw %llu cassette read edges, motor on for %llu clk_sys, %llu OPL sample changes\n",
			(unsigned long long)a_read_edges, (unsigned long long)a_motor_cycles, (unsigned long long)a_opl_changes);
		if (g_opl && !a_opl_changes) { printf("FAIL: --opl but the OPL did not play while B was paused\n"); finish(1); }
		printf("B screen:\n");
		b.screen_text(stdout);
		if (!paused_cycles || paused_cycles % 32) { printf("FAIL: paused time is not a whole number of C64 cycles\n"); finish(1); }
		if (!check_pause_video(a, b, paused_cycles)) finish(1);
		bool sync_a = a.sync_report(), sync_b = b.sync_report();
		finish(sync_a && sync_b ? 0 : 1);
	}

	fprintf(stderr, "unknown mode %s\n", mode);
	finish(2);
}

int main(int argc, char **argv) {
	finish(run_main(argc, argv));
}
