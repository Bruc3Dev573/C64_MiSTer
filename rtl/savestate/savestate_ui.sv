// Savestate user interface (WP A2).
//
// Ported from rtl/savestate_ui.sv of the TurboGrafx16 core (based on the
// savestate_ui of the MiSTer Gameboy core by Robert Peip). The C64 uses
// F1-F8 itself, so the keyboard only selects the slot, with a combination a
// C64 program cannot need: Ctrl+Alt+F1..F4. kbd_eat marks that key event so
// c64.sv keeps it away from the C64 matrix (Ctrl and Alt alone are CTRL and
// C= and still reach it, as on the real keyboard).
//
//   Ctrl+Alt+F1..F4         select slot 1-4
//   pad Savestates + Left/Right   previous / next slot
//   pad Savestates + Down   save to the selected slot
//   pad Savestates + Up     load the selected slot
//   OSD Save state / Restore state / Savestate self-test
//
// Info messages (CONF_STR "I," list, 1-based):
//   1 help, 2-5 active slot 1-4, 6 + 2*slot + load: saved / restored,
//   14 + result - 1 for engine failures (RES_* of savestates.sv),
//   22 self-test PASS, 23 self-test FAIL.

module savestate_ui #(parameter INFO_TIMEOUT_BITS = 25)
(
	input            clk,
	input     [10:0] ps2_key,
	input            allow_ss,
	input            joySS,
	input            joyRight,
	input            joyLeft,
	input            joyDown,
	input            joyUp,
	input      [1:0] status_slot,
	input      [2:0] OSD_saveload,   // {selftest, load, save}
	output reg       ss_save = 0,
	output reg       ss_load = 0,
	output reg       ss_test = 0,
	output reg       ss_info_req = 0,
	output reg [7:0] ss_info = 0,
	output           kbd_eat,        // this ps2_key event is a savestate hotkey
	input            ss_done,        // engine finished an operation (manual or test step)
	input      [3:0] ss_result,
	input            ss_test_active,
	input            ss_test_done,
	input            ss_test_pass,
	input      [1:0] ss_active_slot,
	input            ss_active_load,
	output reg       statusUpdate = 0,
	output     [1:0] selected_slot
);

reg [1:0] ss_base = 0;
reg       lastRight = 0, lastLeft = 0, lastDown = 0, lastUp = 0;
reg [INFO_TIMEOUT_BITS-1:0] InfoWaitcnt = 0;
reg       slotswitched = 0;
reg [1:0] lastOSDsetting = 0;
reg       ctrl = 0, alt = 0;
reg       old_stb = 0;
reg [2:0] old_st = 0;

assign selected_slot = ss_base;

wire pressed = ps2_key[9];
wire key_ev  = (old_stb != ps2_key[10]);
wire fkey    = ~ps2_key[8] & (ps2_key[7:0] == 8'h05 || ps2_key[7:0] == 8'h06 ||
                              ps2_key[7:0] == 8'h04 || ps2_key[7:0] == 8'h0C);

assign kbd_eat = key_ev & ctrl & alt & fkey;

always @(posedge clk) begin
	old_stb <= ps2_key[10];
	if (key_ev && ps2_key[7:0] == 8'h14) ctrl <= pressed;   // left or right Ctrl
	if (key_ev && ps2_key[7:0] == 8'h11) alt  <= pressed;   // left Alt or AltGr

	lastRight <= joyRight;
	lastLeft  <= joyLeft;
	lastDown  <= joyDown;
	lastUp    <= joyUp;

	slotswitched <= 0;
	ss_save      <= 0;
	ss_load      <= 0;
	ss_test      <= 0;
	ss_info_req  <= 0;
	statusUpdate <= 0;

	// the OSD option (restored by Main) wins over the last hotkey
	lastOSDsetting <= status_slot;
	if (lastOSDsetting != status_slot) ss_base <= status_slot;

	old_st <= OSD_saveload;

	if (allow_ss) begin
		// keyboard: Ctrl+Alt+F1..F4 select the slot (make only)
		if (kbd_eat & pressed) begin
			case (ps2_key[7:0])
				8'h05: ss_base <= 2'd0;
				8'h06: ss_base <= 2'd1;
				8'h04: ss_base <= 2'd2;
				8'h0C: ss_base <= 2'd3;
				default: ;
			endcase
			statusUpdate <= 1;
			slotswitched <= 1;
		end

		// gamepad, Savestates button as modifier
		if (joySS) begin
			InfoWaitcnt <= InfoWaitcnt + 1'b1;
			if (InfoWaitcnt[INFO_TIMEOUT_BITS-1]) begin
				ss_info     <= 8'd1;
				ss_info_req <= 1;
				InfoWaitcnt <= 0;
			end
			if (joyRight & ~lastRight & (ss_base < 3)) begin
				ss_base      <= ss_base + 1'd1;
				statusUpdate <= 1;
				slotswitched <= 1;
				InfoWaitcnt  <= 0;
			end
			if (joyLeft & ~lastLeft & (ss_base > 0)) begin
				ss_base      <= ss_base - 1'd1;
				statusUpdate <= 1;
				slotswitched <= 1;
				InfoWaitcnt  <= 0;
			end
			if (joyDown & ~lastDown) begin
				ss_save     <= 1;
				InfoWaitcnt <= 0;
			end
			if (joyUp & ~lastUp) begin
				ss_load     <= 1;
				InfoWaitcnt <= 0;
			end
		end
		else InfoWaitcnt <= 0;

		// OSD (R options: rising edges)
		if (~old_st[0] & OSD_saveload[0]) ss_save <= 1;
		if (~old_st[1] & OSD_saveload[1]) ss_load <= 1;
		if (~old_st[2] & OSD_saveload[2]) ss_test <= 1;

		if (slotswitched) begin
			ss_info     <= 8'd2 + ss_base;
			ss_info_req <= 1;
		end
	end

	// completion notices (also when commands have been disallowed since)
	if (ss_done & ~ss_test_active) begin
		ss_info     <= (ss_result == 0) ? 8'd6 + {ss_active_slot, ss_active_load} : 8'd13 + ss_result;
		ss_info_req <= 1;
	end
	if (ss_test_done) begin
		ss_info     <= ss_test_pass ? 8'd22 : 8'd23;
		ss_info_req <= 1;
	end
end

endmodule
