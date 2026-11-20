// Savestate request manager (WP A2).
//
// Ported from rtl/statemanager.vhd of the TurboGrafx16 core: one pending
// request per kind together with its slot, saves dispatched before loads, the
// slot address held stable until the engine is busy. Added: the OSD
// self-test, which runs on a scratch slot just below the four slots declared
// to Main (never copied to SD) and keeps the machine frozen between steps:
//   save -> crc1, save -> crc2, load, save -> crc3
// PASS when every step succeeded and crc1 = crc2 (a save leaves the machine
// as it was) = crc3 (a load restores exactly what was saved) = the CRC the
// load verified.

module statemanager #(
	parameter [28:0] BASE       = 29'h05580000,   // 0x2AC00000 / 8 (D13)
	parameter [28:0] SLOT_WORDS = 29'h002A0000    // 21 MiB / 8
)
(
	input             clk,
	input             reset,

	input       [1:0] slot,          // selected slot (UI)
	input             save,          // pulses from the UI
	input             load,
	input             selftest,

	// engine
	output reg        eng_save = 0,
	output reg        eng_load = 0,
	output reg [28:0] eng_addr = BASE,
	output reg        eng_hold = 0,
	input             eng_busy,
	input             eng_done,
	input       [3:0] eng_result,
	input      [31:0] eng_crc,

	// operation in progress / last finished
	output reg  [1:0] active_slot = 0,
	output reg        active_load = 0,
	output reg        active_test = 0,
	output reg        test_done = 0,   // 1 clock
	output reg        test_pass = 0
);

reg       save_buf = 0, load_buf = 0, test_buf = 0;
reg [1:0] save_slot = 0, load_slot = 0;
reg       awaiting = 0;

// self-test sequencer
reg  [2:0] tstep = 0;               // 0 idle, 1..4 steps
reg [31:0] crc1 = 0, crc2 = 0;
reg        tok = 0;

wire [28:0] scratch = BASE - SLOT_WORDS;          // 0x29700000 with 21 MiB slots

always @(posedge clk) begin
	reg save_dispatched, load_dispatched;
	save_dispatched = 0;
	load_dispatched = 0;

	eng_save  <= 0;
	eng_load  <= 0;
	test_done <= 0;

	// a refused request ends with done and no busy
	if (eng_busy | eng_done) awaiting <= 0;

	if (tstep != 0) begin
		// self-test: one engine operation per step, machine held frozen
		if (~eng_busy & ~awaiting & ~eng_done) begin
			awaiting <= 1;
			eng_addr <= scratch;
			case (tstep)
				1, 2, 4: eng_save <= 1;
				3:       eng_load <= 1;
			endcase
		end
		if (eng_done) begin
			if (eng_result != 0) tok <= 0;
			case (tstep)
				1: crc1 <= eng_crc;
				2: crc2 <= eng_crc;
				3: if (eng_crc != crc1) tok <= 0;
				4: ;
			endcase
			if (tstep == 4 || eng_result != 0) begin
				tstep     <= 0;
				eng_hold  <= 0;
				test_done <= 1;
				test_pass <= tok & (eng_result == 0) & (crc1 == crc2) & (eng_crc == crc1);
			end
			else tstep <= tstep + 1'd1;
		end
	end
	else if (~reset & ~eng_busy & ~awaiting) begin
		if (save_buf) begin
			eng_addr    <= BASE + SLOT_WORDS * save_slot;
			active_slot <= save_slot;
			active_load <= 0;
			active_test <= 0;
			eng_save    <= 1;
			awaiting    <= 1;
			save_buf    <= 0;
			save_dispatched = 1;
		end
		else if (load_buf) begin
			eng_addr    <= BASE + SLOT_WORDS * load_slot;
			active_slot <= load_slot;
			active_load <= 1;
			active_test <= 0;
			eng_load    <= 1;
			awaiting    <= 1;
			load_buf    <= 0;
			load_dispatched = 1;
		end
		else if (test_buf) begin
			test_buf    <= 0;
			active_test <= 1;
			tstep       <= 1;
			tok         <= 1;
			eng_hold    <= 1;
		end
	end

	// one pending request per kind; keep its first slot until dispatch
	if (reset) begin
		save_buf <= 0;
		load_buf <= 0;
		test_buf <= 0;
		awaiting <= 0;
	end
	else begin
		if (save & (~save_buf | save_dispatched)) begin
			save_buf  <= 1;
			save_slot <= slot;
		end
		if (load & (~load_buf | load_dispatched)) begin
			load_buf  <= 1;
			load_slot <= slot;
		end
		if (selftest) test_buf <= 1;
	end
end

endmodule
