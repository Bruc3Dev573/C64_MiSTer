`timescale 1ns/1ps
module tb_sdram_chip;
reg clk=0;
always #7.9295 clk=~clk;
reg [2:0] cmd=7;
reg [12:0] addr=0;
reg [1:0] ba=0, dqm=0;
reg [15:0] data=0;
reg ss_own=0;
wire [15:0] dq;
assign dq = cmd == 4 ? data : 16'bz;
sim_mt48lc16m16 chip (
	.clk(clk), .cke(1'b1), .cs_n(1'b0), .ras_n(cmd[2]), .cas_n(cmd[1]), .we_n(cmd[0]),
	.addr(addr), .ba(ba), .dqm(dqm), .dq(dq), .ss_own(ss_own)
);

task automatic command(input [2:0] c, input [1:0] bank=0, input [12:0] a=0,
	input [1:0] mask=0, input [15:0] value=0);
	begin
		@(negedge clk);
		cmd=c; ba=bank; addr=a; dqm=mask; data=value;
		@(posedge clk); #1;
	end
endtask
task automatic idle(input integer n);
	integer j;
	begin for(j=0; j<n; j=j+1) command(7); end
endtask
task automatic check(input logic ok, input string what);
	if(ok !== 1'b1) $fatal(1, "FAIL: SDRAM chip %s", what);
endtask

integer bank;
reg [12:0] r;
reg [8:0] col;
reg [24:0] base;
initial begin
	idle(2);
	command(2, 0, 13'h400);
	idle(1);
	command(0, 0, 13'h220);
	idle(1);
	command(1);
	idle(4);
	command(1);
	idle(5);
	check(chip.initialized, "initialization sequence");
	for(bank=0; bank<4; bank=bank+1) begin
		r=13'h123+bank;
		col=9'h1a5-bank;
		base={1'b0, col[8], bank[1:0], r, col[7:0]};
		command(3, bank[1:0], r);
		idle(1);
		command(4, bank[1:0], 13'h400|col, 2, 16'h00a0+bank);
		idle(5);
		command(3, bank[1:0], r);
		idle(1);
		command(4, bank[1:0], 13'h400|col, 1, (16'h50+bank)<<8);
		idle(5);
		check(chip.mem[base] == 8'ha0+bank, "lower byte mapping and masked preservation");
		check(chip.mem[base|25'h1000000] == 8'h50+bank, "upper byte mapping");
		command(3, bank[1:0], r);
		idle(1);
		command(5, bank[1:0], 13'h400|col);
		idle(1);
		check(!chip.dq_valid, "CAS latency before second clock");
		idle(1);
		check(dq == ((16'h50+bank)<<8 | (16'ha0+bank)), "CAS=2 read data and bank isolation");
		idle(4);
		command(3, bank[1:0], r);
		idle(1);
		command(5, bank[1:0], 13'h400|col, 2);
		idle(2);
		check(dq == 16'ha0+bank && chip.dq_mask == 2, "DQM read mask has two-cycle latency");
		idle(4);
	end
	check(chip.ss_conflicts == 0, "legal commands have zero violations");
	$display("PASS: SDRAM chip all banks, byte lanes, masks, CAS=2 and auto-precharge");
	ss_own=1;
	command(3, 0, 13'h123);
	command(5, 0, 13'h400);
	check(chip.ss_conflicts == 1 && chip.violations[1][1] == 1 && chip.violations[0][1] == 0,
		"negative tRCD control and engine attribution");
	$display("PASS: SDRAM chip negative tRCD control (engine=1 normal=0)");
	idle(1);
	repeat(chip.TREF+1) @(posedge clk);
	#1;
	check(chip.ss_conflicts == 2 && chip.violations[1][7] == 1 &&
		chip.max_gap[1] > chip.TREF, "missing-refresh deadline and unfinished gap");
	$display("PASS: SDRAM chip negative refresh control (engine=1 normal=0)");
	$finish;
end
endmodule
