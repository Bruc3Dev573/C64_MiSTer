// Only the SDRAM clock-output configuration of altddio_out is used here.
// Register both edges so the chip samples half a clk64 after controller outputs.
module altddio_out #(
	parameter extend_oe_disable="OFF", intended_device_family="Cyclone V",
	parameter invert_output="OFF", lpm_hint="UNUSED", lpm_type="altddio_out",
	parameter oe_reg="UNREGISTERED", power_up_high="OFF", width=1
)(
	input [width-1:0] datain_h, datain_l,
	input outclock, aclr, aset, oe, outclocken, sclr, sset,
	output reg [width-1:0] dataout = 0
);
always @(posedge outclock or negedge outclock)
	if(aclr || sclr) dataout <= 0;
	else if(aset || sset) dataout <= {width{1'b1}};
	else if(outclocken && oe) dataout <= outclock ? datain_h : datain_l;
endmodule
