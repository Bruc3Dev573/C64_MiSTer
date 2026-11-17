// tb_ssui: keyboard hotkeys (Ctrl+Alt+F1..F4, key eaten), pad combination,
// OSD actions and info messages of rtl/savestate/savestate_ui.sv.
//
//   iverilog -g2012 -o tb sim/ss/tb_ssui.sv rtl/savestate/savestate_ui.sv && vvp tb

`timescale 1ns/1ps

module tb_ssui;

reg clk = 0;
always #5 clk = ~clk;

integer errors = 0;
task check(input cond, input [8*64-1:0] what);
	if (cond !== 1'b1) begin
		errors = errors + 1;
		$display("FAIL: %0s", what);
	end
endtask

reg  [10:0] ps2_key = 0;
reg         allow = 1, joySS = 0, jR = 0, jL = 0, jD = 0, jU = 0;
reg   [1:0] status_slot = 0;
reg   [2:0] osd = 0;
reg         done = 0, test_active = 0, test_done = 0, test_pass = 0, act_load = 0;
reg   [3:0] result = 0;
reg   [1:0] act_slot = 0;
wire        ss_save, ss_load, ss_test, info_req, kbd_eat, status_upd;
wire  [7:0] info;
wire  [1:0] sel;

savestate_ui #(.INFO_TIMEOUT_BITS(8)) dut
(
	.clk(clk), .ps2_key(ps2_key), .allow_ss(allow),
	.joySS(joySS), .joyRight(jR), .joyLeft(jL), .joyDown(jD), .joyUp(jU),
	.status_slot(status_slot), .OSD_saveload(osd),
	.ss_save(ss_save), .ss_load(ss_load), .ss_test(ss_test), .ss_info_req(info_req), .ss_info(info),
	.kbd_eat(kbd_eat), .ss_done(done), .ss_result(result), .ss_test_active(test_active),
	.ss_test_done(test_done), .ss_test_pass(test_pass), .ss_active_slot(act_slot), .ss_active_load(act_load),
	.statusUpdate(status_upd), .selected_slot(sel)
);

// counters of pulses
integer n_save = 0, n_load = 0, n_test = 0, n_eat = 0, n_upd = 0;
reg [7:0] last_info = 0;
always @(posedge clk) begin
	if (ss_save) n_save = n_save + 1;
	if (ss_load) n_load = n_load + 1;
	if (ss_test) n_test = n_test + 1;
	if (kbd_eat) n_eat = n_eat + 1;
	if (status_upd) n_upd = n_upd + 1;
	if (info_req) last_info = info;
end

// one PS/2 event as hps_io delivers it: new code + toggled strobe
task key(input [8:0] code, input pressed);
	begin
		@(posedge clk) ps2_key <= {~ps2_key[10], pressed, code};
		repeat (4) @(posedge clk);
	end
endtask

initial begin
	repeat (5) @(posedge clk);

	// 1. F2 alone reaches the C64 (not eaten), no slot change
	key(9'h006, 1); key(9'h006, 0);
	check(n_eat == 0 && sel == 0, "1 F2 alone not eaten");

	// 2. Ctrl+Alt+F3 selects slot 3 and is eaten (make and break)
	key(9'h014, 1); key(9'h011, 1);
	key(9'h004, 1);
	check(sel == 2 && last_info == 8'd4 && n_upd == 1, "2 Ctrl+Alt+F3 -> slot 3, info 'Active Slot 3'");
	key(9'h004, 0);
	check(n_eat == 2, "2 make and break of F3 eaten");
	check(n_save == 0 && n_load == 0, "2 hotkey does not save or load");

	// 3. right Ctrl (E0 14) + AltGr (E0 11) + F4 -> slot 4
	key(9'h014, 0); key(9'h011, 0);
	key(9'h114, 1); key(9'h111, 1);
	key(9'h00C, 1);
	check(sel == 3, "3 right Ctrl + AltGr + F4 -> slot 4");
	key(9'h00C, 0); key(9'h114, 0); key(9'h111, 0);

	// 4. Ctrl only + F1: not a hotkey
	key(9'h014, 1);
	n_eat = 0;
	key(9'h005, 1); key(9'h005, 0);
	check(n_eat == 0 && sel == 3, "4 Ctrl+F1 is a C64 key");
	key(9'h014, 0);

	// 5. pad: SS + Left (slot 3), SS + Down (save), SS + Up (load)
	joySS = 1;
	@(posedge clk) jL <= 1; @(posedge clk) jL <= 0;
	repeat (3) @(posedge clk);
	check(sel == 2, "5 SS+Left -> slot 3");
	@(posedge clk) jD <= 1; @(posedge clk) jD <= 0;
	repeat (3) @(posedge clk);
	check(n_save == 1, "5 SS+Down saves");
	@(posedge clk) jU <= 1; @(posedge clk) jU <= 0;
	repeat (3) @(posedge clk);
	check(n_load == 1, "5 SS+Up loads");
	// held SS shows the help after the timeout
	repeat (300) @(posedge clk);
	check(last_info == 8'd1, "5 help text after holding SS");
	joySS = 0;
	// directions without SS do nothing
	@(posedge clk) jD <= 1; @(posedge clk) jD <= 0;
	repeat (3) @(posedge clk);
	check(n_save == 1, "5 Down alone does not save");

	// 6. OSD: R options give one pulse on the rising edge
	@(posedge clk) osd <= 3'b001;
	repeat (10) @(posedge clk);
	osd <= 0;
	@(posedge clk) osd <= 3'b010;
	repeat (10) @(posedge clk);
	osd <= 0;
	@(posedge clk) osd <= 3'b100;
	repeat (10) @(posedge clk);
	osd <= 0;
	repeat (3) @(posedge clk);
	check(n_save == 2 && n_load == 2 && n_test == 1, "6 OSD save, restore, self-test");

	// 7. OSD slot option
	status_slot = 1;
	repeat (3) @(posedge clk);
	check(sel == 1, "7 OSD slot option");

	// 8. completion messages
	@(posedge clk) begin done <= 1; result <= 0; act_slot <= 2; act_load <= 1; end
	@(posedge clk) done <= 0;
	repeat (2) @(posedge clk);
	check(last_info == 8'd11, "8 'Restore state 3' = 6 + 2*2 + 1");
	@(posedge clk) begin done <= 1; result <= 5; end
	@(posedge clk) done <= 0;
	repeat (2) @(posedge clk);
	check(last_info == 8'd18, "8 config refusal message 13 + 5");
	@(posedge clk) begin test_done <= 1; test_pass <= 1; test_active <= 1; done <= 1; end
	@(posedge clk) begin test_done <= 0; done <= 0; end
	repeat (2) @(posedge clk);
	check(last_info == 8'd22, "8 self-test PASS message (step done hidden)");

	// 9. not allowed: no hotkeys or requests
	allow = 0;
	key(9'h014, 1); key(9'h011, 1);
	n_upd = 0;
	key(9'h005, 1);
	check(n_upd == 0, "9 no slot change while not allowed");
	@(posedge clk) osd <= 3'b001; repeat (3) @(posedge clk); osd <= 0;
	repeat (3) @(posedge clk);
	check(n_save == 2, "9 no save while not allowed");

	if (errors == 0) $display("tb_ssui: PASS");
	else $display("tb_ssui: FAIL (%0d errors)", errors);
	$finish;
end

endmodule
