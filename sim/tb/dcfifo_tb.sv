`timescale 1ns/1ps
module dcfifo_tb;
reg aclr = 0, rdclk = 0, wrclk = 0, rdreq = 0, wrreq = 0;
reg [9:0] data = 0;
wire [9:0] q;
wire rdempty, wrempty, wrfull, rdfull;
wire [1:0] rdusedw, wrusedw;
integer stages, i;
dcfifo #(.lpm_numwords(4), .lpm_widthu(2)) fifo (
    .aclr(aclr), .data(data), .rdclk(rdclk), .rdreq(rdreq),
    .wrclk(wrclk), .wrreq(wrreq), .q(q), .rdempty(rdempty),
    .wrempty(wrempty), .wrfull(wrfull), .rdfull(rdfull),
    .rdusedw(rdusedw), .wrusedw(wrusedw), .eccstatus()
);
task check(input cond, input [511:0] why);
    if (cond !== 1'b1) $fatal(1, "dcfifo: FAIL stages=%0d: %0s", stages, why);
endtask
task wt;
    begin #5; wrclk = 1; #1; wrclk = 0; #4; end
endtask
task rt;
    begin #5; rdclk = 1; #1; rdclk = 0; #4; end
endtask
initial begin
    for (stages = 0; stages <= 3; stages = stages == 0 ? 2 : stages + 1) begin
        fifo.sim_sync_stages = stages;
        aclr = 1; #1; aclr = 0; #1;
        check(rdempty && wrempty && !wrfull, "reset");
        data = 10'h155; wrreq = 1; wt(); wrreq = 0;
        check(!wrempty && rdempty == (stages != 0), "write visibility");
        for (i = 1; i <= stages; i = i + 1) begin
            rt(); check(rdempty == (i < stages), "read-domain delay");
        end
        check(q == 10'h155 && rdusedw == 1, "showahead data/count");
        rdreq = 1; rt(); rdreq = 0;
        check(rdempty && wrempty == (stages == 0), "read visibility");
        for (i = 1; i <= stages; i = i + 1) begin
            wt(); check(wrempty == (i == stages), "write-domain delay");
        end
        wrreq = 1;
        for (i = 1; i <= 4; i = i + 1) begin data = i; wt(); end
        wt(); wrreq = 0;
        check(wrfull, "full and overflow held");
        repeat (3) rt();
        check(rdfull && q == 1, "full across pointer wrap");
        rdreq = 1; rt(); rdreq = 0;
        check(!rdfull && q == 2 && wrfull == (stages != 0), "read full FIFO");
        for (i = 1; i <= stages; i = i + 1) begin
            wt(); check(wrfull == (i < stages), "full release delay");
        end
        check(wrusedw == 3, "write-domain count after read");
        aclr = 1; #1;
        check(rdempty && wrempty && !wrfull && !rdfull, "asynchronous clear of both pipelines");
        aclr = 0; #1;
        $display("dcfifo: stages %0d PASS (visibility, full, wrap, clear)", stages);
    end
    $display("dcfifo: PASS");
    $finish;
end
endmodule
