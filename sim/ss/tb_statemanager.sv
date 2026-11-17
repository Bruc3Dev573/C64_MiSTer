// tb_statemanager: request queue, slot capture and the OSD self-test of
// rtl/savestate/statemanager.sv against a model engine.
//
//   iverilog -g2012 -o tb sim/ss/tb_statemanager.sv rtl/savestate/statemanager.sv && vvp tb

`timescale 1ns/1ps

module tb_statemanager;

reg clk = 0;
always #5 clk = ~clk;

integer errors = 0;
task check(input cond, input [8*64-1:0] what);
	if (cond !== 1'b1) begin
		errors = errors + 1;
		$display("FAIL: %0s", what);
	end
endtask

reg  [1:0] slot = 0;
reg        save = 0, load = 0, selftest = 0, reset = 0;
wire       eng_save, eng_load, eng_hold;
wire [28:0] eng_addr;
reg        eng_busy = 0, eng_done = 0;
reg  [3:0] eng_result = 0;
reg [31:0] eng_crc = 0;
wire [1:0] active_slot;
wire       active_load, active_test, test_done, test_pass;

statemanager dut
(
	.clk(clk), .reset(reset), .slot(slot), .save(save), .load(load), .selftest(selftest),
	.eng_save(eng_save), .eng_load(eng_load), .eng_addr(eng_addr), .eng_hold(eng_hold),
	.eng_busy(eng_busy), .eng_done(eng_done), .eng_result(eng_result), .eng_crc(eng_crc),
	.active_slot(active_slot), .active_load(active_load), .active_test(active_test),
	.test_done(test_done), .test_pass(test_pass)
);

// model engine: busy for 'len' clocks, done with result/crc, refuses on 'refuse'
integer len = 50;
reg     refuse = 0;
reg     crc_bad_after_load = 0;
reg     loaded = 0;
reg [31:0] state_crc = 32'h12345678;
integer cnt = 0;
// log of dispatched operations
reg [31:0] log_op [0:63];
integer nlog = 0;
always @(posedge clk) begin
	eng_done <= 0;
	if ((eng_save | eng_load) && eng_busy) check(0, "request while the engine is busy");
	if ((eng_save | eng_load) && !eng_busy) begin
		log_op[nlog] = {eng_load, eng_hold, eng_addr};
		nlog = nlog + 1;
		if (refuse) begin
			eng_done   <= 1;
			eng_result <= 7;
		end
		else begin
			eng_busy <= 1;
			cnt <= len;
			eng_result <= 0;
			loaded <= eng_load;
		end
	end
	else if (eng_busy) begin
		if (cnt == 0) begin
			eng_busy <= 0;
			eng_done <= 1;
			eng_crc  <= (crc_bad_after_load && loaded) ? state_crc ^ 1 : state_crc;
			if (loaded && crc_bad_after_load) state_crc <= state_crc ^ 1;
		end
		else cnt <= cnt - 1;
	end
end

task pulse_save(input [1:0] s); begin @(posedge clk) begin slot <= s; save <= 1; end @(posedge clk) save <= 0; end endtask
task pulse_load(input [1:0] s); begin @(posedge clk) begin slot <= s; load <= 1; end @(posedge clk) load <= 0; end endtask
task idle_wait; begin repeat (3) @(posedge clk); while (eng_busy || dut.awaiting || dut.save_buf || dut.load_buf || dut.test_buf || dut.tstep) @(posedge clk); repeat (3) @(posedge clk); end endtask

localparam [28:0] BASE = 29'h07C00000, SW = 29'h100000;
localparam [28:0] A1 = BASE + SW, A2 = BASE + 2*SW, A3 = BASE + 3*SW, A4 = BASE - SW;   // scratch slot of the self-test
reg seen_done; reg seen_pass;
always @(posedge clk) if (test_done) begin seen_done = 1; seen_pass = test_pass; end

initial begin
	repeat (5) @(posedge clk);

	// 1. save slot 3: address and capture
	pulse_save(3);
	idle_wait;
	check(nlog == 1 && log_op[0] == {1'b0, 1'b0, A3}, "1 save slot 4 address");
	check(active_slot == 3 && !active_load, "1 active slot");

	// 2. save and load queued together: save first, each with its own slot
	@(posedge clk) begin slot <= 1; save <= 1; end
	@(posedge clk) begin save <= 0; slot <= 2; load <= 1; end
	@(posedge clk) load <= 0;
	idle_wait;
	check(nlog == 3 && log_op[1] == {1'b0, 1'b0, A1} && log_op[2] == {1'b1, 1'b0, A2}, "2 save then load, slots kept");

	// 3. a second save while one is pending/running keeps one entry
	pulse_save(0);
	pulse_save(1);
	pulse_save(2);
	idle_wait;
	check(nlog == 5, "3 one pending save per kind");
	check(log_op[3][28:0] == BASE && log_op[4][28:0] == A1, "3 first pending slot kept until dispatch");

	// 4. a refused request does not stall the queue
	refuse = 1;
	pulse_load(0);
	repeat (10) @(posedge clk);
	refuse = 0;
	pulse_load(1);
	idle_wait;
	check(nlog == 7 && log_op[6] == {1'b1, 1'b0, A1}, "4 queue continues after a refusal");

	// 5. self-test: save, save, load, save on the scratch slot with hold, PASS
	seen_done = 0;
	@(posedge clk) selftest <= 1;
	@(posedge clk) selftest <= 0;
	idle_wait;
	check(nlog == 11, "5 four operations");
	check(log_op[7] == {1'b0, 1'b1, A4} && log_op[8] == {1'b0, 1'b1, A4} &&
	      log_op[9] == {1'b1, 1'b1, A4} && log_op[10] == {1'b0, 1'b1, A4}, "5 sequence on scratch slot, held");
	check(seen_done && seen_pass, "5 self-test PASS");
	check(!eng_hold, "5 hold released");

	// 6. self-test FAIL when the save after the load differs
	seen_done = 0;
	crc_bad_after_load = 1;
	@(posedge clk) selftest <= 1;
	@(posedge clk) selftest <= 0;
	idle_wait;
	check(seen_done && !seen_pass, "6 self-test FAIL on CRC mismatch");

	// 7. self-test FAIL when a step is refused
	crc_bad_after_load = 0;
	seen_done = 0;
	refuse = 1;
	@(posedge clk) selftest <= 1;
	@(posedge clk) selftest <= 0;
	repeat (50) @(posedge clk);
	refuse = 0;
	idle_wait;
	check(seen_done && !seen_pass && !eng_hold, "7 refused step ends the test with FAIL");

	// 8. reset clears the queue
	@(posedge clk) begin slot <= 1; save <= 1; reset <= 1; end
	@(posedge clk) begin save <= 0; reset <= 0; end
	idle_wait;
	check(nlog == 16, "8 request during reset dropped");

	if (errors == 0) $display("tb_statemanager: PASS");
	else $display("tb_statemanager: FAIL (%0d errors)", errors);
	$finish;
end

initial begin
	#10000000;
	$display("tb_statemanager: FAIL (timeout)");
	$finish;
end

endmodule
