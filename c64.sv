//============================================================================
//  C64 Top level for MiSTer
//  Copyright (C) 2017-2021 Sorgelig
//
//  Used DE2-35 Top level by Dar (darfpga@aol.fr)
//
//  FPGA64 is Copyrighted 2005-2008 by Peter Wendrich (pwsoft@syntiac.com)
//  http://www.syntiac.com/fpga64.html
//
//
//  This program is free software; you can redistribute it and/or modify it
//  under the terms of the GNU General Public License as published by the Free
//  Software Foundation; either version 2 of the License, or (at your option)
//  any later version.
//
//  This program is distributed in the hope that it will be useful, but WITHOUT
//  ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
//  FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License for
//  more details.
//
//  You should have received a copy of the GNU General Public License along
//  with this program; if not, write to the Free Software Foundation, Inc.,
//  51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
//============================================================================ 

module emu
(
	`include "sys/emu_ports.vh"
);

wire [7:0]  drv_ddram_burstcnt;
wire [28:0] drv_ddram_addr;
wire        drv_ddram_rd;
wire        drv_ddram_we;
wire [63:0] drv_ddram_din;
wire [7:0]  drv_ddram_be;

wire        drv_ddram_busy;
wire        drv_ddram_ready;

// DDRAM_* are driven by the savestate arbiter (ss_ddram_arb, see savestates
// section): the drive track cache owns the port except during a savestate.
assign DDRAM_CLK      = clk_sys;
assign {SD_SCK, SD_MOSI, SD_CS} = 'Z;

assign LED_DISK   = 0;
assign LED_POWER  = 0;
assign LED_USER   = |drive_led | ioctl_download | ioctl_upload | ezfl_mod | tape_led | ~disk_ready;
reg    close_osd  = 0;
assign BUTTONS    = {1'b0, close_osd};
assign VGA_DISABLE = 0;
assign VGA_SCALER = 0;
assign HDMI_BLACKOUT = 0;
assign HDMI_BOB_DEINT = 0;

// Status Bit Map:
//              Upper                          Lower
// 0         1         2         3          4         5         6
// 01234567890123456789012345678901 23456789012345678901234567890123
// 0123456789ABCDEFGHIJKLMNOPQRSTUV 0123456789ABCDEFGHIJKLMNOPQRSTUV
// XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX
//
// 6     7         8         9         10        11        12
// 45678901234567890123456789012345 67890123456789012345678901234567
// XXXXXXXXXXXXXXXXXXXXXXXXX  XXXXX
//                            ^^^^^ 91=Counter Reset, 92=Counter,
//                                  93=Rewind, 94=Fast Forward, 95=Stop
//                                     ^^^^^^ 99=Savestates to SD, 101:100=Slot,
//                                            102=Save, 103=Restore, 104=Self-test

`include "build_id.v"
localparam CONF_STR = {
	// Main reads the SS (savestate area) and UART tokens only from this second field, comma separated
	"C64;SS2AC00000:1500000,UART9600:2400;",
	"H7S0,D64G64T64D81,Mount #8;",
	"H0S1,D64G64T64D81,Mount #9;",
	"O[77:76],Mount Write Protected,Off,#8,#9,#8 & #9;",
	"-;",
	"FS1,PRGCRTREUTAP;",
	"hAdBR[61],Save cartridge;",
	"hAO[62],Autosave,Off,On;",
	"h3-;",
	"h3T[7],Tape Play/Pause;",
	"h3T[95],Tape Stop;",
	"h3T[93],Tape Rewind;",
	"h3T[94],Tape Fast Forward;",
	"h3T[91],Tape Counter Reset;",
	"h3-;",
	"h3O[92],Tape Counter,Off,On;",
	"h3O[11],Tape Sound,Off,On;",
	"h3R[23],Tape Unload;",
	"-;",

	"P1,Audio & Video;", 
 	"P1O[2],Video Standard,PAL,NTSC;",
	"P1O[35:34],VIC-II,656x,856x,Early 856x;",
	"P1O[84:82],Palette,Colodore,Ultimate,Pepto-PAL,Vice,Vice6569R1,Vice6569R5,Vice8565R2,Lemon64;",
	"P1O[5:4],Aspect Ratio,Original,Full Screen,[ARC1],[ARC2];",
	"P1O[10:8],Scandoubler Fx,None,HQ2x-320,HQ2x-160,CRT 25%,CRT 50%,CRT 75%;",
	"d1P1O[32],Vertical Crop,No,Yes;",
	"P1O[31:30],Scale,Normal,V-Integer,Narrower HV-Integer,Wider HV-Integer;",
	"P1-;",
	"P1O[13],Left SID,6581,8580;",
	"P1O[16],Right SID,6581,8580;",
	"D4P1O[66:64],Left Filter,Default,Custom 1,Custom 2,Custom 3,Adjustable;",
	"D5P1O[69:67],Right Filter,Default,Custom 1,Custom 2,Custom 3,Adjustable;",
	"D4D8P1O[72:70],Left Fc Offset,0,1,2,3,4,5;",
	"D5D9P1O[75:73],Right Fc Offset,0,1,2,3,4,5;",
	"P1O[22:20],Right SID Port,Same,DE00,D420,D500,DF00;",
	"P1O[37],8580 Digifix,On,Off;",
	"P1FC7,FLT,Load Custom Filters;",
	"P1-;",
	"P1O[12],Sound Expander,Disabled,OPL2;",
	"P1O[41:40],DigiMax,Disabled,DE00,DF00;",
	"P1O[19:18],Stereo Mix,None,25%,50%,100%;",

	"P2,Hardware;", 
	"P2O[52],GeoRAM,Disabled,4MB;",
	"P2O[54:53],REU,Disabled,512KB,2MB,16MB;",
	"hCP2O[63],REU wrap,512KB,None;",
	"P2-;",
	"P2O[25],External IEC,Disabled,Enabled;",
	"P2O[43],Expansion,Joysticks,RS232;",
	"P2O[51],RS232 mode,UP9600,VIC-1011;",
	"P2O[33],RS232 connection,Internal,External;",
	"P2O[36],Real-Time Clock,Auto,Disabled;",
	"P2O[45],CIA,6526,8521;",
	"P2-;",
	"P2O[27:26],Pot 1/2,Joy 1 Fire 2/3,Mouse,Paddles 1/2;",
	"P2O[29:28],Pot 3/4,Joy 2 Fire 2/3,Mouse,Paddles 3/4;",
	"P2-;",
	"P2O[60:59],Key modifier,L+R Shift,L Shift,R Shift;",
	"P2-;",
	"P2O[1],Release Keys on Reset,Yes,No;",
	"P2O[24],Clear RAM on Reset,Yes,No;",
	"P2O[50],Reset & Run PRG,Yes,No;",
	"P2O[42],Pause When OSD is Open,No,Yes;",
	"P2O[39],Tape Auto Play,Yes,No;",
	"P2O[96],Tape Auto Unload,Yes,No;",
	"P2O[38],Boot EasyFlash,Yes,No;",
	"P2-;",
	"P2FC8,ROM,System ROM C64+C1541 ;",
	"P2FC9,ROM,System ROM C1581     ;",
	"P2FC5,CRT,Boot Cartridge       ;",
	"P2-;",
	"P2O[15:14],System ROM,Loadable C64,Standard C64,C64GS,Japanese;",

	"P3,Drives;",
	"P3O[58:57],Enable Drive #8,If Mounted,Always,Never;",
	"P3O[56:55],Enable Drive #9,If Mounted,Always,Never;",
	"P3O[98:97],Parallel Cable,Auto,On,Off;",
	"P3O[86:85],Drives OSD,Activity Only,If Mounted,Debug,Off;",
	"P3-;",
	"P3O[80:78],Drive RPM    (G64),300.0,300.1,300.5,301.0,302.0,299.0,299.5,299.9;",
	"P3O[81],Drive Wobble (G64),Off,On;",
	"P3-;",
	"P3R[6],Reset Disk Drives;",

	"-;",
	"O[99],Savestates to SDCard,On,Off;",
	"O[101:100],Savestate Slot,1,2,3,4;",
	"R[102],Save state (Pad SS+Down);",
	"R[103],Restore state (Pad SS+Up);",
	"R[104],Savestate self-test;",
	"-;",
	"O[3],Swap Joysticks,No,Yes;",
	"O[88:87],SNAC Joystick,Disabled,Joy 1,Joy 2;",
	"-;",
	"O[47:46],Turbo mode,Off,C128,Smart;",
	"d6O[49:48],Turbo speed,2x,3x,4x;",
	"-;",
	"R[0],Reset;",
	"R[17],Reset & Detach Cartridge;",
	// Savestate info messages (savestate_ui.sv): help, slots, saved/restored,
	// engine refusals (13 + result code), self-test.
	"I,",
	"Slot=Ctrl+Alt+F1-F4/SS+L/R|Save=SS+Down|Load=SS+Up,",
	"Active Slot 1,",
	"Active Slot 2,",
	"Active Slot 3,",
	"Active Slot 4,",
	"Save to state 1,",
	"Restore state 1,",
	"Save to state 2,",
	"Restore state 2,",
	"Save to state 3,",
	"Restore state 3,",
	"Save to state 4,",
	"Restore state 4,",
	"Savestate: no safe point - not saved,",
	"Savestate: REU too large for the slot,",
	"Savestate: slot empty or invalid,",
	"Savestate: other core version,",
	"Savestate: other hardware settings,",
	"Savestate: slot damaged (CRC),",
	"Savestate: busy - try again,",
	"Savestate: DDR3/RAM timeout,",
	"Savestate self-test: PASS,",
	"Savestate self-test: FAIL;",
	"J,Fire 1,Fire 2,Fire 3,Paddle Btn,Mod1,Mod2,Savestates;",
	"jn,A,B,Y,X|P,R,L,Select;",
	"jp,A,B,Y,X|P,R,L,Select;",
	"V,v",`BUILD_DATE
};

wire pll_locked;
wire clk_sys;
wire clk64;
wire clk48;

pll pll
(
	.refclk(CLK_50M),
	.outclk_0(clk48),
	.outclk_1(clk64),
	.outclk_2(clk_sys),
	.reconfig_to_pll(reconfig_to_pll),
	.reconfig_from_pll(reconfig_from_pll),
	.locked(pll_locked)
);

wire [63:0] reconfig_to_pll;
wire [63:0] reconfig_from_pll;
wire        cfg_waitrequest;
reg         cfg_write;
reg   [5:0] cfg_address;
reg  [31:0] cfg_data;

pll_cfg pll_cfg
(
	.mgmt_clk(CLK_50M),
	.mgmt_reset(0),
	.mgmt_waitrequest(cfg_waitrequest),
	.mgmt_read(0),
	.mgmt_readdata(),
	.mgmt_write(cfg_write),
	.mgmt_address(cfg_address),
	.mgmt_writedata(cfg_data),
	.reconfig_to_pll(reconfig_to_pll),
	.reconfig_from_pll(reconfig_from_pll)
);

reg ntsc_r = 0;
always @(posedge CLK_50M) begin
	reg ntscd = 0, ntscd2 = 0;
	reg [2:0] state = 0;
	reg [23:0] delay = 0;
	reg osd_s1 = 0, osd_s2 = 0;

	osd_s1 <= OSD_STATUS;
	osd_s2 <= osd_s1;

	// bringing ntsc_req into the CLK_50M domain
	ntscd  <= ntsc_req;
	ntscd2 <= ntscd;

	cfg_write <= 0;
	close_osd <= 0;

	if(ntscd2 != ntsc_r) begin
	if(osd_s2 && delay < 24'd2500000) begin // 50ms pulse to close OSD
	// Close OSD so that PAL/NTSC switch induced reset does not
	// blank screen, if PAUSE when in OSD is enabled
			close_osd <= 1;
			delay <= delay + 1'd1;
			end else if (delay < 24'd7500000) begin // 150ms total delay
			delay <= delay + 1'd1;
			end else begin
			state <= 1;
			ntsc_r <= ntscd2;
			delay <= 0;
			end
	end else begin
	delay <= 0;
	end

	if(!cfg_waitrequest) begin
		if(state) state<=state+1'd1;
		case(state)
			1: begin
					cfg_address <= 0;
					cfg_data <= 0;
					cfg_write <= 1;
				end
				/*
			3: begin
					cfg_address <= 4;
					cfg_data <= ntsc_r ? 'h20504 : 'h404;
					cfg_write <= 1;
				end
				*/
			5: begin
					cfg_address <= 7;
					cfg_data <= ntsc_r ? 3357876127 : 1503512573;
					cfg_write <= 1;
				end
			7: begin
					cfg_address <= 2;
					cfg_data <= 0;
					cfg_write <= 1;
				end
		endcase
	end
end

reg ntsc_sys1 = 0, ntsc = 0;
reg reset_n;
reg reset_wait = 0;
reg ntsc_prev = 0;
reg ss_reu_clr = 1;      // power-on zero fill of the REU lane (savestates, D13): the machine waits in reset

always @(posedge clk_sys) begin
	integer reset_counter;
	reg old_download;
	reg do_erase = 1;

	// Bringing ntsc_r back into clk_sys domain
	ntsc_sys1 <= ntsc_r;
	ntsc <= ntsc_sys1;
	// Detect pal/ntsc switch
	ntsc_prev <= ntsc;

	reset_n <= !reset_counter;
	old_download <= ioctl_download;

	if (RESET | status[0] | status[17] | buttons[1] | !pll_locked | ss_reu_clr | (ntsc_prev != ntsc)) begin
		if(RESET) do_erase <= 1;
		reset_counter <= 100000;
	end
	else if(~old_download & ioctl_download & load_prg & ~status[50]) begin
		do_erase <= 1;
		reset_wait <= 1;
		reset_counter <= 255;
	end
	else if (ioctl_download & (load_crt | load_rom)) begin
		do_erase <= 1;
		reset_counter <= 255;
	end
	else if ((ioctl_download || inj_meminit) & ~reset_wait);
	else if (erasing) force_erase <= 0;
	else if (!reset_counter) begin
		do_erase <= 0;
		if(reset_wait && c64_addr == 'hFFCF) reset_wait <= 0;
	end
	else begin
		reset_counter <= reset_counter - 1;
		if (reset_counter == 100 && (~status[24] | do_erase)) force_erase <= 1;
	end
end

wire [15:0] joyA,joyB,joyC,joyD;
wire [15:0] joy = joyA | joyB | joyC | joyD;

// pad "Savestates" button (joy[10]) is a modifier: the C64 does not see the
// joysticks while it is held and for ~10 ms after (savestate_ui)
reg  [19:0] ss_combo_tail = 0;
wire        ss_combo_hold = joy[10] | (ss_combo_tail != 0);
always @(posedge clk_sys) begin
	if (joy[10]) ss_combo_tail <= 20'd320000;
	else if (ss_combo_tail != 0) ss_combo_tail <= ss_combo_tail - 1'd1;
end

wire        c64_pause;      // machine actually stopped (pause_out of fpga64, cycle aligned)
wire        c64_pause_in;   // pause input of fpga64 (freeze, held until the sync realigns)
wire        ss_freeze_req;  // savestate engine holds the machine (ss_freeze)

// savestates (WP A2): signals used before the savestate section
wire        ss_pause;       // pause input of fpga64 (OSD pause or savestate freeze)
wire        ss_frz_ack;     // machine frozen for the savestate engine
wire        c64_cpu_sync;   // C64 CPU between instructions
wire        ss_kbd_eat;     // ps2_key event is a savestate hotkey
wire        ss_load_done;   // 1 clock after a savestate load
wire        ss_chain_en, ss_chain_so, ss_chain_si;   // scan chain (engine <-> segments)
wire        ss_ext_so, ss_ext_si;                    // chain leg outside fpga64: SYS -> OPL3 -> 1541 x2 -> INPUT -> CART -> REU -> SID2
wire        ss_opl_so;                               // OPL3: ss_ext_so (SYS) -> OPL3 -> DRV9_1541
wire        ss_opl_replay;                           // OPL3 reset and replay after a load: machine held
wire  [7:0] ss_opl_rgn_rdata;                        // OPL3_REGS region port
wire        ss_opl_rgn_ack;
wire        ss_cart_so, ss_dmax_so;                  // CART: cartridge.v, then the DigiMax registers
wire        ss_rtc_so;                               // engine chain_so -> TAPE -> RTC -> TOP -> fpga64 ss_chain_si
wire        ss_tape_so, ss_tapess_so;                // TAPE: tape_subsystem, then the use_tape glue
wire        ss_input_so;                             // INPUT (1351 mouse): DRV8_1541 -> mouse -> CART
wire        ss_top_so;                               // TOP (drive_ce, disk activity): RTC -> TOP -> fpga64
wire        ss_drv_so;                               // drives: OPL3 -> DRV9_1581 -> DRV8_1581 -> DRV9_1541 -> DRV8_1541 -> INPUT
wire        ss_drv_idle;                             // drive CPUs between instructions, no track/sector transfer starting
wire  [1:0] ss_drv_1581;                             // drive type per unit (config mask)
wire  [5:0] ss_drv_rgn_sel;                          // 1541: {TRACK, EXTRAM, RAM} of unit 9, then of unit 8
wire  [3:0] ss_drv_rgn_sel81;                        // 1581: {FDC_BUF, RAM} of unit 9, then of unit 8
wire  [7:0] ss_drv_rgn_rdata;
wire        ss_drv_rgn_ack;
wire  [7:0] ss_rgn_tag, ss_rgn_wdata;               // engine region bus (savestates section)
wire [23:0] ss_rgn_addr;
wire        ss_rgn_req, ss_rgn_we;
wire  [7:0] ss_rgn_rdata;
wire        ss_rgn_ack;
wire  [1:0] ss_slot;
wire        ss_status_upd;
wire        ss_info_req;
wire  [7:0] ss_info;
wire        tape_ss_idle;
wire        ss_sd_own;                               // the savestate engine owns the SDRAM (normal ce masked)
wire        ss_sd_req, ss_sd_we;                     // sdram.v engine transfers (ss_sdram_port)
wire [24:0] ss_sd_addr;
wire [63:0] ss_sd_din, ss_sd_dout;
wire        ss_sd_wtgl, ss_sd_rtgl, ss_sd_dtgl;
reg         ss_cram_act = 0;
reg         ss_cram_we = 0;
reg   [9:0] ss_cram_addr = 0;
reg   [3:0] ss_cram_din = 0;
wire  [3:0] ss_cram_q;

wire [127:0] status;
wire        forced_scandoubler;

wire        ioctl_wr;
wire        ioctl_rd;
wire [24:0] ioctl_addr;
wire  [7:0] ioctl_data;
wire  [7:0] ioctl_din;
wire  [7:0] ioctl_index;
wire        ioctl_download;
wire        ioctl_upload;
wire        tape_ioctl_wait;
wire [31:0] ioctl_file_ext;

wire [31:0] sd_lba[2];
wire  [5:0] sd_blk_cnt[2];
wire  [1:0] sd_rd;
wire  [1:0] sd_wr;
wire  [1:0] sd_ack;
wire [13:0] sd_buff_addr;
wire  [7:0] sd_buff_dout;
wire  [7:0] sd_buff_din[2];
wire        sd_buff_wr;
wire  [1:0] img_mounted;
wire [31:0] img_size;
wire        img_readonly;

wire [24:0] ps2_mouse;
wire [10:0] ps2_key;
wire  [1:0] buttons;
wire [21:0] gamma_bus;

wire        tape_play;
wire        tape_key_rew;
wire        tape_key_stop;
wire        tape_key_ff;
wire        tape_key_counter_reset;

wire  [7:0] pd1,pd2,pd3,pd4;

wire [64:0] RTC;

hps_io #(.CONF_STR(CONF_STR), .VDNUM(2), .BLKSZ(1)) hps_io
(
	.clk_sys(clk_sys),
	.HPS_BUS(HPS_BUS),

	.joystick_0(joyA),
	.joystick_1(joyB),
	.joystick_2(joyC),
	.joystick_3(joyD),

	.paddle_0(pd1),
	.paddle_1(pd2),
	.paddle_2(pd3),
	.paddle_3(pd4),

	.status(status),
	.status_in({status[127:102], ss_slot, status[99:0]}),
	.status_set(ss_status_upd),
	.info_req(ss_info_req),
	.info(ss_info),
	.status_menumask({status[54], ezfl_mod || ezfl_save_en, cart_ezfl, ~status[69], ~status[66], status[58], |status[47:46], status[16], status[13], tap_loaded, 1'b0, |vcrop, status[56]}), .buttons(buttons),
	.forced_scandoubler(forced_scandoubler),
	.gamma_bus(gamma_bus),

	.sd_lba(sd_lba),
	.sd_blk_cnt(sd_blk_cnt),
	.sd_rd(sd_rd),
	.sd_wr(sd_wr),
	.sd_ack(sd_ack),

	.sd_buff_addr(sd_buff_addr),
	.sd_buff_dout(sd_buff_dout),
	.sd_buff_din(sd_buff_din),
	.sd_buff_wr(sd_buff_wr),
	.img_mounted(img_mounted),
	.img_size(img_size),
	.img_readonly(img_readonly),

	.ps2_key(ps2_key),
	.ps2_mouse(ps2_mouse),

	.RTC(RTC),

	.ioctl_download(ioctl_download),
	.ioctl_index(ioctl_index),
	.ioctl_file_ext(ioctl_file_ext),
	.ioctl_wr(ioctl_wr),
	.ioctl_addr(ioctl_addr),
	.ioctl_dout(ioctl_data),
	.ioctl_upload_req(ezfl_save),
	.ioctl_upload_index(ezfl_idx),
	.ioctl_upload(ioctl_upload),
	.ioctl_din(ioctl_din),
	.ioctl_rd(ioctl_rd),
	.ioctl_wait(ioctl_req_wr|ioctl_req_rd|reset_wait|tape_ioctl_wait|ss_reu_clr)
);

wire load_prg   = ioctl_index == 'h01;
wire load_crt   = ioctl_index == 'h41 || ioctl_index == 5;
wire load_reu   = ioctl_index == 'h81;
wire load_tap   = ioctl_index == 'hC1;
wire load_flt   = ioctl_index == 7;
wire load_rom   = ioctl_index == 8;
wire load_c1581 = ioctl_index == 9;

wire game;
wire exrom;
wire io_rom;
wire cart_ce;
wire cart_we;
wire nmi;
wire cart_oe;
wire IOF_rd;
wire  [7:0] cart_data;
wire  [7:0] cart_wrdata;
wire [24:0] cart_addr;
wire cart_mem_req;

cartridge cartridge
(
	.clk32(clk_sys),
	.reset_n(reset_n),
	.pause(c64_pause),

	.cart_loading(ioctl_download && load_crt),
	.cart_id(cart_attached ? cart_id : status[52] ? 8'd99 : 8'd255),
	.cart_exrom(cart_exrom),
	.cart_game(cart_game),
	.cart_bank_hi(cart_bank_hi),
	.cart_bank_16k(cart_bank_16k),
	.cart_bank_num(cart_bank_num),
	.cart_bank_addr(ioctl_load_addr[20:13]),
	.cart_bank_wr(cart_hdr_wr),
	.cart_boot(~status[38]),

	.exrom(exrom),
	.game(game),

	.romL(romL),
	.romH(romH),
	.UMAXromH(UMAXromH),
	.IOE(IOE),
	.IOF(IOF),
	.mem_write(ram_we),
	.mem_ce(ram_ce),
	.mem_ce_out(cart_ce),
	.mem_write_out(cart_we),
	.mem_in(sdram_data),
	.mem_out(cart_wrdata),
	.mem_addr(cart_addr),
	.mem_req(cart_mem_req),
	.mem_cycle(io_cycle),
	.IO_rom(io_rom),
	.IO_rd(cart_oe),
	.IO_data(cart_data),
	.addr_in(c64_addr),
	.data_in(c64_data_out),
	.data_out(c64_data_in),

	.freeze_key(freeze_key),
	.mod_key(mod_key),
	.nmi(nmi),
	.nmi_ack(nmi_ack),

	.ss_en(ss_chain_en),
	.ss_hold(ss_frz_ack),
	.ss_load_done(ss_load_done),
	.ss_si(ss_input_so),
	.ss_so(ss_cart_so)
);

wire ezfl_save = status[61] | (status[62] & OSD_STATUS & ezfl_mod);
reg  ezfl_mod = 0;
reg  ezfl_idx = 0;
reg  ezfl_save_en = 0;
always @(posedge clk_sys) begin
	reg save_old = 0;
	reg ext_old = 0;

	if(cart_mem_req) ezfl_mod <= 1;
	if(ioctl_download && load_crt) ezfl_mod <= 0;
	if(ioctl_upload) {ezfl_mod, ezfl_save_en} <= 0;
	
	save_old <= ezfl_save;
	if(~save_old & ezfl_save) ezfl_idx <= ~status[61];
	
	ext_old <= ext_crt;
	if(~ext_old & ext_crt) ezfl_save_en <= 1;
end

wire        dma_req;
wire        dma_cycle;
wire [15:0] dma_addr;
wire  [7:0] dma_dout;
wire  [7:0] dma_din;
wire        dma_we;
wire        ext_cycle;

wire [24:0] reu_ram_addr;
wire  [7:0] reu_ram_dout;
wire        reu_ram_we;

wire  [7:0] reu_dout;
wire        reu_irq;

wire        reu_oe  = IOF && reu_cfg;
wire  [1:0] reu_cfg = status[54:53];
wire        reu_wrap = ~status[63] & status[54];

reu reu
(
	.clk(clk_sys),
	.reset(~reset_n),
	.cfg(reu_cfg),
	.wrap(reu_wrap),

	.dma_req(dma_req),

	.dma_cycle(dma_cycle),
	.dma_addr(dma_addr),
	.dma_dout(dma_dout),
	.dma_din(dma_din),
	.dma_we(dma_we),

	.ram_cycle(ext_cycle),
	.ram_addr(reu_ram_addr),
	.ram_dout(reu_ram_dout),
	.ram_din(sdram_data),
	.ram_we(reu_ram_we),
	
	.cpu_addr(c64_addr),
	.cpu_dout(c64_data_out),
	.cpu_din(reu_dout),
	.cpu_we(ram_we),
	.cpu_cs(IOF),

	.irq(reu_irq),

	.ss_en(ss_chain_en),
	.stop(c64_pause),             // machine stopped: OSD pause or savestate freeze
	.ss_hold(ss_frz_ack),
	.ss_load_done(ss_load_done),
	.ss_si(ss_dmax_so),
	.ss_so(ss_ext_si)
);

reg ext_cycle_d;
always @(posedge clk_sys) ext_cycle_d <= ext_cycle;
wire reu_ram_ce = ~ext_cycle_d & ext_cycle & dma_req;

// rearrange joystick contacts for c64
// (the pad Savestates button masks the C64 joysticks while held, plus ~10 ms)
wire [6:0] joyA_int = (joy[8] | ss_combo_hold) ? 7'd0 : {joyA[6:4], joyA[0], joyA[1], joyA[2], joyA[3]};
wire [6:0] joyB_int = (joy[8] | ss_combo_hold) ? 7'd0 : {joyB[6:4], joyB[0], joyB[1], joyB[2], joyB[3]};
wire [6:0] joyC_c64 = (joy[8] | ss_combo_hold) ? 7'd0 : {joyC[6:4], joyC[0], joyC[1], joyC[2], joyC[3]};
wire [6:0] joyD_c64 = (joy[8] | ss_combo_hold) ? 7'd0 : {joyD[6:4], joyD[0], joyD[1], joyD[2], joyD[3]};

// swap joysticks if requested
// SNAC DB9 joystick support - C64/Amiga/SMS standard pinout:
//   Pin 1 Up     -> USER_IN[1]  (active low)
//   Pin 2 Down   -> USER_IN[0]  (active low)
//   Pin 3 Left   -> USER_IN[5]  (active low)
//   Pin 4 Right  -> USER_IN[3]  (active low)
//   Pin 5 NC     -> not used
//   Pin 6 Fire A -> USER_IN[2]  (active low, Button 1)
//   Pin 9 Fire B -> USER_IN[6]  (active low, Button 2)
wire [1:0] snac_mode = status[88:87]; // 0=disabled, 1=Joy1, 2=Joy2
wire [6:0] snac_joy  = {1'b0, ~USER_IN[6], ~USER_IN[2],
                        ~USER_IN[3], ~USER_IN[5], ~USER_IN[0], ~USER_IN[1]};
// format: {fire3=0, fireB(Pin9), fireA(Pin6), right(Pin4), left(Pin3), down(Pin2), up(Pin1)}

wire [6:0] joyA_c64 = (snac_mode == 2'd1) ? snac_joy : (status[3] ? joyB_int : joyA_int);
wire [6:0] joyB_c64 = (snac_mode == 2'd2) ? snac_joy : (status[3] ? joyA_int : joyB_int);

wire [7:0] paddle_1 = status[3] ? pd3 : pd1;
wire [7:0] paddle_2 = status[3] ? pd4 : pd2;
wire [7:0] paddle_3 = status[3] ? pd1 : pd3;
wire [7:0] paddle_4 = status[3] ? pd2 : pd4;

wire       paddle_1_btn = ~joy[8] & (status[3] ? joyC[7] : joyA[7]);
wire       paddle_2_btn = ~joy[8] & (status[3] ? joyD[7] : joyB[7]);
wire       paddle_3_btn = ~joy[8] & (status[3] ? joyA[7] : joyC[7]);
wire       paddle_4_btn = ~joy[8] & (status[3] ? joyB[7] : joyD[7]);

wire [1:0] pd12_mode = status[27:26];
wire [1:0] pd34_mode = status[29:28];

reg [24:0] ioctl_load_addr;
reg        ioctl_req_wr;
reg        ioctl_req_rd;

reg  [7:0] cart_id;
reg        cart_bank_hi;
reg        cart_bank_16k;
reg  [7:0] cart_bank_num;
reg        cart_exrom;
reg        cart_game;
reg        cart_attached = 0;
reg        cart_hdr_wr;

reg        force_erase;
reg        erasing;

reg        inj_meminit = 0;

wire       io_cycle;
reg        io_cycle_ce;
reg        io_cycle_we;
reg [24:0] io_cycle_addr;
reg  [7:0] io_cycle_data;

localparam TAP_ADDR = 25'h0400000;
localparam REU_ADDR = 25'h1000000;
localparam CRT_ADDR = 25'h0200000;

wire cart_ezfl = cart_attached && (cart_id == 32 || cart_id ==33);
reg ext_crt = 0;

always @(posedge clk_sys) begin
	reg  [4:0] erase_to;
	reg        old_download;
	reg        erase_cram;
	reg        io_cycleD;
	reg        old_st0 = 0;
	reg        old_meminit;
	reg [15:0] inj_end;
	reg  [7:0] inj_meminit_data;
	reg  [2:0] rd_cyc;
	reg        ioctl_rd_en;
	reg [15:0] cart_blk_len;
	reg  [3:0] cart_hdr_cnt;
	reg  [7:0] cart_id_hi;

	old_download <= ioctl_download;
	io_cycleD <= io_cycle;
	cart_hdr_wr <= 0;
	
	if (~io_cycle & io_cycleD) begin
		io_cycle_ce <= 1;
		io_cycle_we <= 0;
		io_cycle_addr <= tap_play_addr + TAP_ADDR;
		if (ioctl_req_wr) begin
			ioctl_req_wr <= 0;
			io_cycle_we <= 1;
			io_cycle_addr <= ioctl_load_addr;
			ioctl_load_addr <= ioctl_load_addr + 1'b1;
			if (erasing) io_cycle_data <= {8{ioctl_load_addr[6]}};
			else if (inj_meminit) io_cycle_data <= inj_meminit_data;
			else io_cycle_data <= ioctl_data;
		end

		if(ioctl_req_rd) begin
			io_cycle_addr <= ioctl_load_addr;
			ioctl_rd_en <= 1;
		end
	end
	
	if (io_cycle) {io_cycle_ce, io_cycle_we, ioctl_rd_en} <= 0;

	if (ioctl_rd) begin
		if(ioctl_addr == 0) ioctl_load_addr <= CRT_ADDR;
		ioctl_req_rd <= 1;
	end

	rd_cyc <= {rd_cyc[1:0], io_cycle & io_cycle_ce & ioctl_rd_en};
	if(rd_cyc[2]) begin
		ioctl_din <= sdram_data;
		ioctl_req_rd <= 0;
		ioctl_load_addr <= ioctl_load_addr + 1'b1;
	end


	if (ioctl_wr) begin
		if (load_prg) begin
			// PRG header
			// Load address low-byte
			if      (ioctl_addr == 0) begin ioctl_load_addr[7:0]  <= ioctl_data; inj_end[7:0]  <= ioctl_data; end
			// Load address high-byte
			else if (ioctl_addr == 1) begin ioctl_load_addr[15:8] <= ioctl_data; inj_end[15:8] <= ioctl_data; end
			else begin ioctl_req_wr <= 1; inj_end <= inj_end + 1'b1; end
		end

		if (load_crt) begin
			if (ioctl_addr == 0) begin
				ioctl_load_addr <= CRT_ADDR;
				cart_blk_len <= 0;
				cart_hdr_cnt <= 0;
			end

			if (ioctl_addr == 8'h16) cart_id_hi <= ioctl_data;
			if (ioctl_addr == 8'h17) cart_id    <= cart_id_hi ? 8'd255 : ioctl_data;
			if (ioctl_addr == 8'h18) cart_exrom <= ioctl_data[0];
			if (ioctl_addr == 8'h19) cart_game  <= ioctl_data[0];

			if (ioctl_addr >= 8'h40) begin
				if (!cart_blk_len || cart_hdr_cnt) begin
					cart_hdr_cnt <= cart_hdr_cnt + 1'b1;
					if (cart_hdr_cnt == 6)  cart_blk_len  <= {ioctl_data, 8'h00};
					if (cart_hdr_cnt == 11) cart_bank_num <= ioctl_data;
					if (cart_hdr_cnt == 12) cart_bank_hi  <= ioctl_data > 8'h80;
					if (cart_hdr_cnt == 14) cart_bank_16k <= ioctl_data > 8'h20;
					if (cart_hdr_cnt == 15) cart_hdr_wr   <= 1;
				end
				else begin
					cart_blk_len <= cart_blk_len - 1'b1;
					ioctl_req_wr <= 1;
				end
			end
		end
		
		if (load_tap) begin
			if (ioctl_addr == 0)  ioctl_load_addr <= TAP_ADDR;
			ioctl_req_wr <= 1;
		end

		if (load_reu) begin
			if (ioctl_addr == 0) ioctl_load_addr <= REU_ADDR;
			ioctl_req_wr <= 1;
		end
	end
	
	if (old_download != ioctl_download && load_crt) begin
		cart_attached <= old_download;
		erase_cram <= 1;
		ext_crt <= ioctl_download && (ioctl_file_ext == ".CRT");
	end 

	// meminit for RAM injection
	if (old_download != ioctl_download && load_prg && !inj_meminit) begin
		inj_meminit <= 1;
		ioctl_load_addr <= 0;
	end

	if (inj_meminit) begin
		if (!ioctl_req_wr) begin
			// check if done
			if (ioctl_load_addr == 'h100) begin
				inj_meminit <= 0;
			end
			else begin
				ioctl_req_wr <= 1;
				
				// Initialize BASIC pointers to simulate the BASIC LOAD command
				case(ioctl_load_addr)
					// TXT (2B-2C)
					// Set these two bytes to $01, $08 just as they would be on reset (the BASIC LOAD command does not alter these)
					'h2B: inj_meminit_data <= 'h01;
					'h2C: inj_meminit_data <= 'h08;

					// SAVE_START (AC-AD)
					// Set these two bytes to zero just as they would be on reset (the BASIC LOAD command does not alter these)
					'hAC, 'hAD: inj_meminit_data <= 'h00;
					
					// VAR (2D-2E), ARY (2F-30), STR (31-32), LOAD_END (AE-AF)
					// Set these just as they would be with the BASIC LOAD command (essentially they are all set to the load end address)
					'h2D, 'h2F, 'h31, 'hAE: inj_meminit_data <= inj_end[7:0];
					'h2E, 'h30, 'h32, 'hAF: inj_meminit_data <= inj_end[15:8];
					
					default: begin
						ioctl_req_wr <= 0;
						
						// advance the address
						ioctl_load_addr <= ioctl_load_addr + 1'b1;
					end
				endcase
			end
		end
	end

	old_meminit <= inj_meminit;
	start_strk  <= old_meminit & ~inj_meminit;
	
	old_st0 <= status[17];
	if (~old_st0 & status[17]) cart_attached <= 0;
	
	if (!erasing && force_erase) begin
		erasing <= 1;
		ioctl_load_addr <= 0;
	end

	if (erasing && !ioctl_req_wr) begin
		erase_to <= erase_to + 1'b1;
		if (&erase_to) begin
			if (ioctl_load_addr < ({erase_cram, 16'hFFFF}))
				ioctl_req_wr <= 1;
			else begin
				erasing <= 0;
				erase_cram <= 0;
			end
		end
	end
end

reg        start_strk = 0;
reg        reset_keys = 0;
reg [10:0] key = 0;
// A savestate hotkey (Ctrl+Alt+F1..F4) is eaten: its strobe toggle is undone
// by kbd_par, so the C64 keyboard never sees the event.
reg        kbd_par = 0;
wire       kbd_par_next = kbd_par ^ ss_kbd_eat;
wire       kbd_stb = ps2_key[10] ^ kbd_par_next;
always @(posedge clk_sys) kbd_par <= kbd_par_next;
always @(posedge clk_sys) begin
	reg  [3:0] act = 0;
	reg        joy_finish = 0;
	reg [17:0] joy_last = 0;
	reg [17:0] joy_key;
	int        to;

	reset_keys <= 0;

	joy_key =(joy[9:8] == 3) ?
				(joy[0] ? 18'h005 : joy[1] ? 18'h006 : joy[2] ? 18'h004 : joy[3] ? 18'h00C  :
				 joy[4] ? 18'h003 : joy[5] ? 18'h00B : joy[6] ? 18'h083 : joy[7] ? 18'h00A  : 18'h0):
				(joy[9]) ?
				(joy[0] ? 18'h016 : joy[1] ? 18'h01E : joy[2] ? 18'h026 : joy[3] ? 18'h025  :
			    joy[4] ? 18'h02E : joy[5] ? 18'h045 : joy[6] ? 18'h035 : joy[7] ? 18'h031  : 18'h0):
				(joy[0] ? 18'h174 : joy[1] ? 18'h16B : joy[2] ? 18'h172 : joy[3] ? 18'h175  : 
				 joy[4] ? 18'h05A : joy[5] ? 18'h029 : joy[6] ? 18'h076 : joy[7] ? 18'h2276 : 18'h0);
	
	if(~reset_n) {joy_finish, act} <= 0;

	if(joy[9:8]) begin
		joy_finish <= 1;
		if(!joy[7:0] && joy_last) begin
			joy_last <= 0;
			reset_keys <= 1;
		end
		else if(!joy_last[8:0] && joy_key) begin
			to <= to + 1'd1;
			if(joy_last[17:9] != joy_key[17:9]) begin
				joy_last[17:9] <= joy_key[17:9];
				key <= joy_key[17:9];
				key[9] <= 1;
				key[10] <= ~key[10];
			end
			else if(to > 640000 && joy_last[8:0] != joy_key[8:0]) begin
				joy_last[8:0] <= joy_key[8:0];
				key <= joy_key[8:0];
				key[9] <= 1;
				key[10] <= ~key[10];
			end
		end
		else begin
			to <= 0;
		end
	end
	else if(joy_finish) begin
		joy_last   <= 0;
		key        <= 0;
		key[10]    <= kbd_stb;
		joy_finish <= 0;
		reset_keys <= 1;
	end
	else if(act) begin
		to <= to + 1;
		if(to > 1280000) begin
			to <= 0;
			act <= act + 1'd1;
			case(act)
				// PS/2 scan codes
				 1: key <= 'h2d;  // R
				 3: key <= 'h3c;  // U
				 5: key <= 'h31;  // N
				 7: key <= 'h5a;  // <RETURN>
				 9: key <= 'h00;
				10: act <= 0;
			endcase
			key[9]  <= act[0];
			key[10] <= (act >= 9) ? kbd_stb : ~key[10];
		end
	end
	else begin
		to <= 0;
		key <= {kbd_stb, ps2_key[9] & disk_ready, ps2_key[8:0]};
	end
	if(start_strk & ~status[50]) begin
		act <= 1;
		key <= 0;
	end
end

assign SDRAM_CKE  = 1;

wire [7:0] sdram_data;

// the machine's SDRAM accesses (io_cycle: host and cartridge write-back,
// ext_cycle: REU DMA, else the C64 bus); while the savestate engine owns the
// SDRAM their ce is masked (the machine is frozen or, for the power-on REU
// fill, held in reset; the port lets go on a refresh pulse, where ce is low)
// and sdram.v runs the engine transfers
wire [24:0] sdm_addr = io_cycle ? (cart_mem_req ? cart_addr   : io_cycle_addr ) : ext_cycle ? reu_ram_addr : cart_addr;
wire        sdm_ce   = io_cycle ? (cart_mem_req ? cart_ce     : io_cycle_ce   ) : ext_cycle ? reu_ram_ce   : cart_ce;
wire        sdm_we   = io_cycle ? (cart_mem_req ? cart_we     : io_cycle_we   ) : ext_cycle ? reu_ram_we   : cart_we;
wire  [7:0] sdm_din  = io_cycle ? (cart_mem_req ? cart_wrdata : io_cycle_data ) : ext_cycle ? reu_ram_dout : cart_wrdata;

sdram sdram
(
	.sd_addr(SDRAM_A),
	.sd_data(SDRAM_DQ),
	.sd_ba(SDRAM_BA),
	.sd_cs(SDRAM_nCS),
	.sd_we(SDRAM_nWE),
	.sd_ras(SDRAM_nRAS),
	.sd_cas(SDRAM_nCAS),
	.sd_clk(SDRAM_CLK),
	.sd_dqm({SDRAM_DQMH,SDRAM_DQML}),

	.clk(clk64),
	.init(~pll_locked),
	.refresh(refresh),
	.addr(sdm_addr),
	.ce(~ss_sd_own & sdm_ce),
	.we(sdm_we),
	.din(sdm_din),
	.dout(sdram_data),

	.ss_own(ss_sd_own),
	.ss_req(ss_sd_req),
	.ss_we(ss_sd_we),
	.ss_addr(ss_sd_addr),
	.ss_din(ss_sd_din),
	.ss_wtgl(ss_sd_wtgl),
	.ss_dout(ss_sd_dout),
	.ss_rtgl(ss_sd_rtgl),
	.ss_dtgl(ss_sd_dtgl)
);

wire  [7:0] c64_data_out;
wire  [7:0] c64_data_in;
wire [15:0] c64_addr;
wire        refresh;
wire        ram_ce;
wire        ram_we;
wire        nmi_ack;
wire        freeze_key;
wire        mod_key;

wire        IOE;
wire        IOF;
wire        romL;
wire        romH;
wire        UMAXromH;

wire [17:0] audio_l,audio_r;
wire  [7:0] r,g,b;
wire  [3:0] vic_idx;
wire  [9:0] vic_x;   // VIC raster position, for the output sync alignment (video_sync)
wire  [8:0] vic_y;

wire        ntsc_req = status[2];

fpga64_sid_iec fpga64
(
	.clk32(clk_sys),
	.reset_n(reset_n),
	.pause(ss_pause),
	.pause_out(c64_pause),
	.bios(status[15:14]),
	
	.turbo_mode({status[47] & ~disk_access, status[46]}),
	.turbo_speed(status[49:48]),

	.ps2_key(key),
	.kbd_reset((~reset_n & ~status[1]) | reset_keys | ss_load_done),   // D3: no stuck keys after a savestate load
	.shift_mod(~status[60:59]),

	.ramAddr(c64_addr),
	.ramDout(c64_data_out),
	.ramDin(c64_data_in),
	.ramCE(ram_ce),
	.ramWE(ram_we),

	.vic_variant(status[35:34]),
	.ntscmode(ntsc),
	.hsync(hsync),
	.vsync(vsync),
	.palette(status[84:82]),
	.r(r),
	.g(g),
	.b(b),
	.color_index(vic_idx),
	.vic_x(vic_x),
	.vic_y(vic_y),

	.game(game),
	.exrom(exrom),
	.UMAXromH(UMAXromH),
	.irq_n(1),
	.nmi_n(~nmi),
	.nmi_ack(nmi_ack),
	.freeze_key(freeze_key),
	.tape_play(tape_play),
	.tape_rew(tape_key_rew),
	.tape_stop(tape_key_stop),
	.tape_ff(tape_key_ff),
	.tape_reset_counter(tape_key_counter_reset),
	.mod_key(mod_key),
	.roml(romL),
	.romh(romH),
	.ioe(IOE),
	.iof(IOF),
	.io_rom(io_rom),
	.io_ext(cart_oe | reu_oe | opl_en),
	.io_data(cart_oe ? cart_data : reu_oe ? reu_dout : opl_dout),
	
	.dma_req(dma_req),
	.dma_cycle(dma_cycle),
	.dma_addr(dma_addr),
	.dma_dout(dma_dout),
	.dma_din(dma_din),
	.dma_we(dma_we),
	.irq_ext_n(~reu_irq),

	.cia_mode(status[45]),

	.joya({(pd12_mode && !joy[9:8]) ? joyA_c64[6:5] : 2'b00, joyA_c64[4:0] | {1'b0, pd12_mode[1] & paddle_2_btn, pd12_mode[1] & paddle_1_btn, 2'b00} | {pd12_mode[0] & mouse_btn[0], 3'b000, pd12_mode[0] & mouse_btn[1]}}),
	.joyb({(pd34_mode && !joy[9:8]) ? joyB_c64[6:5] : 2'b00, joyB_c64[4:0] | {1'b0, pd34_mode[1] & paddle_4_btn, pd34_mode[1] & paddle_3_btn, 2'b00} | {pd34_mode[0] & mouse_btn[0], 3'b000, pd34_mode[0] & mouse_btn[1]}}),

	.pot1(pd12_mode[1] ? paddle_1 : pd12_mode[0] ? mouse_x : {8{joyA_c64[5]}}),
	.pot2(pd12_mode[1] ? paddle_2 : pd12_mode[0] ? mouse_y : {8{joyA_c64[6]}}),
	.pot3(pd34_mode[1] ? paddle_3 : pd34_mode[0] ? mouse_x : {8{joyB_c64[5]}}),
	.pot4(pd34_mode[1] ? paddle_4 : pd34_mode[0] ? mouse_y : {8{joyB_c64[6]}}),

	.io_cycle(io_cycle),
	.ext_cycle(ext_cycle),
	.refresh(refresh),

	.sid_ld_clk(clk_sys),
	.sid_ld_addr(sid_ld_addr),
	.sid_ld_data(sid_ld_data),
	.sid_ld_wr(sid_ld_wr),
	.sid_mode(status[22:20]),
	.sid_filter(2'b11),
	.sid_ver({status[16],status[13]}),
	.sid_cfg({status[68:67],status[65:64]}),
	.sid_fc_off_l(status[66] ? (13'h600 - {status[72:70],7'd0}) : 13'd0),
	.sid_fc_off_r(status[69] ? (13'h600 - {status[75:73],7'd0}) : 13'd0),
	.sid_digifix(~status[37]),
	.audio_l(audio_l),
	.audio_r(audio_r),

	.iec_data_o(c64_iec_data),
	.iec_atn_o(c64_iec_atn),
	.iec_clk_o(c64_iec_clk),
	.iec_data_i(drive_iec_data),
	.iec_clk_i(drive_iec_clk),

	.pb_i(pb_i),
	.pb_o(pb_o),
	.pa2_i(pa2_i),
	.pa2_o(pa2_o),
	.pc2_n_o(pc2_n_o),
	.flag2_n_i(flag2_n_i),
	.sp2_i(sp2_i),
	.sp2_o(sp2_o),
	.sp1_i(sp1_i),
	.sp1_o(sp1_o),
	.cnt2_i(cnt2_i),
	.cnt2_o(cnt2_o),
	.cnt1_i(cnt1_i),
	.cnt1_o(cnt1_o),

	.c64rom_addr(ioctl_addr[13:0]),
	.c64rom_data(ioctl_data),
	.c64rom_wr(load_rom && !ioctl_addr[16:14] && ioctl_download && ioctl_wr),

	.cass_write(cass_write),
	.cass_motor(cass_motor),
	.cass_sense(~tape_adc_act & (use_tape ? cass_sense : cass_rtc)),
	.cass_read(tape_adc_act ? ~tape_adc : cass_read),

	.ss_cpu_sync(c64_cpu_sync),
	.ss_cram_act(ss_cram_act),
	.ss_cram_addr(ss_cram_addr),
	.ss_cram_we(ss_cram_we),
	.ss_cram_din(ss_cram_din),
	.ss_cram_q(ss_cram_q),

	// segments SYS (first in, after TOP of c64.sv), SID2, SID1, CIA2, CIA1,
	// VIC and CPU (last, out to the engine); between SYS and SID2 the chain
	// leaves through ss_ext_so and comes back on ss_ext_si (1541 x2, INPUT, CART, REU here)
	.ss_chain_en(ss_chain_en),
	.ss_hold(ss_frz_ack),
	.ss_load_done(ss_load_done),
	.ss_chain_si(ss_top_so),
	.ss_chain_so(ss_chain_si),
	.ss_ext_so(ss_ext_so),
	.ss_ext_si(ss_ext_si)
);

wire [7:0] mouse_x;
wire [7:0] mouse_y;
wire [1:0] mouse_btn;

c1351 mouse
(
	.clk_sys(clk_sys),
	.reset(~reset_n),

	.ps2_mouse(ps2_mouse),
	
	.potX(mouse_x),
	.potY(mouse_y),
	.button(mouse_btn),

	// segment INPUT: DRV8_1541 (iec_drive) -> INPUT -> CART
	.stop(c64_pause),
	.ss_en(ss_chain_en),
	.ss_hold(ss_frz_ack),
	.ss_si(ss_drv_so),
	.ss_so(ss_input_so)
);

wire       c64_iec_clk;
wire       c64_iec_data;
wire       c64_iec_atn;

wire       drive_iec_clk  = drive_iec_clk_o  & ext_iec_clk;
wire       drive_iec_data = drive_iec_data_o & ext_iec_data;

wire [7:0] drive_par_i;
wire       drive_stb_i;
wire [7:0] drive_par_o;
wire       drive_stb_o;
wire       drive_iec_clk_o;
wire       drive_iec_data_o;
wire       drive_reset = ~reset_n | status[6] | (load_c1581 & ioctl_download);

wire [1:0] drive_led;
wire [7:0] drive_track[2];
wire [1:0] drive_we;
wire       disk_ready;

reg [1:0] drive_mounted = 0;
reg [1:0] old_img_mounted;

always @(posedge clk_sys) begin 
	old_img_mounted <= img_mounted;
	if(img_mounted[0]) drive_mounted[0] <= |img_size;
	if(img_mounted[1]) drive_mounted[1] <= |img_size;
end

wire mounted_0 = ~old_img_mounted[0] & img_mounted[0];
wire mounted_1 = ~old_img_mounted[1] & img_mounted[1];
wire img_readonly_wp = img_readonly | (mounted_0 & status[76]) | (mounted_1 & status[77]);

wire par_on = (status[98:97] == 1);

iec_drive iec_drive
(
	.clk(clk_sys),
	.reset({drive_reset | ((!status[56:55]) ? ~drive_mounted[1] : status[56]),
		     drive_reset | ((!status[58:57]) ? ~drive_mounted[0] : status[58])}),

	.ce(drive_ce),

	.iec_atn_i(c64_iec_atn),
	.iec_data_i(c64_iec_data & ext_iec_data),
	.iec_clk_i(c64_iec_clk & ext_iec_clk),
	.iec_data_o(drive_iec_data_o),
	.iec_clk_o(drive_iec_clk_o),

	.pause(c64_pause),

	.img_mounted(img_mounted),
	.img_size(img_size),
	.img_readonly(img_readonly_wp),
	.img_type(&ioctl_index[7:6] ? 2'b11 : 2'b01),
	.drive_rpm(status[80:78]),
	.drive_wobble(status[81]),

	.led(drive_led),
	.out_track(drive_track),
	.out_we(drive_we),
	.disk_ready(disk_ready),

	.par_force(par_on),
	.par_data_i(drive_par_i),
	.par_stb_i(drive_stb_i),
	.par_data_o(drive_par_o),
	.par_stb_o(drive_stb_o),

	.clk_sys(clk_sys),

	.sd_lba(sd_lba),
	.sd_blk_cnt(sd_blk_cnt),
	.sd_rd(sd_rd),
	.sd_wr(sd_wr),
	.sd_ack(sd_ack),
	.sd_buff_addr(sd_buff_addr),
	.sd_buff_dout(sd_buff_dout),
	.sd_buff_din(sd_buff_din),
	.sd_buff_wr(sd_buff_wr),

	.rom_addr(load_rom ? (ioctl_addr[15:0] - 16'h4000) : {1'b1,ioctl_addr[14:0]}),
	.rom_data(ioctl_data),
	.rom_wr(((load_rom && ioctl_addr[16:14]) || load_c1581) && ioctl_download && ioctl_wr),
	.rom_std(status[14]),

	.DDRAM_BUSY(drv_ddram_busy),
	.DDRAM_BURSTCNT(drv_ddram_burstcnt),
	.DDRAM_ADDR(drv_ddram_addr),
	.DDRAM_DOUT(DDRAM_DOUT),
	.DDRAM_DOUT_READY(drv_ddram_ready),
	.DDRAM_RD(drv_ddram_rd),
	.DDRAM_WE(drv_ddram_we),
	.DDRAM_DIN(drv_ddram_din),
	.DDRAM_BE(drv_ddram_be),

	// segments DRV9_1581, DRV8_1581, DRV9_1541, DRV8_1541: OPL3 -> 1581 x2 -> 1541 x2 -> INPUT
	.ss_en(ss_chain_en),
	.ss_hold(ss_frz_ack),
	.ss_load_done(ss_load_done),
	.ss_si(ss_opl_so),
	.ss_so(ss_drv_so),
	.ss_idle(ss_drv_idle),
	.ss_1581(ss_drv_1581),
	.ss_rgn_sel(ss_drv_rgn_sel),
	.ss_rgn_sel81(ss_drv_rgn_sel81),
	.ss_rgn_addr(ss_rgn_addr[12:0]),
	.ss_rgn_req(ss_rgn_req),
	.ss_rgn_we(ss_rgn_we),
	.ss_rgn_wdata(ss_rgn_wdata),
	.ss_rgn_rdata(ss_drv_rgn_rdata),
	.ss_rgn_ack(ss_drv_rgn_ack)
	);

// TOP segment (WP A7): engine -> TAPE -> RTC -> TOP -> fpga64 (SYS). Bit 0
// leaves first: drive_sum, disk_access, disk_access_to, then the
// IEC/parallel edge detectors. The drive clock enable stops with the machine
// and keeps its phase across a pause and a load (drive_ce is 0 while stopped
// and never shifts: a bit passing through it would clock the drives); the
// activity detector (turbo off, parallel cable routing) holds on the clocks
// where the drives and the C64 hold (drv_pause). The rest of the glue here is rebuilt at every freeze
// (savestate/state_classes.yaml).
reg        drive_ce;
reg [31:0] drive_sum = 0;
reg [31:0] drive_msum;
reg        disk_access;
reg [31:0] disk_access_to = 0;
reg        c64_iec_clk_old, drive_iec_clk_old, drive_stb_i_old, drive_stb_o_old;
wire [68:0] ss_top_q = {drive_stb_o_old, drive_stb_i_old, drive_iec_clk_old, c64_iec_clk_old,
                        disk_access_to, disk_access, drive_sum};
wire [68:0] ss_top_d = {ss_rtc_so, ss_top_q[68:1]};
assign ss_top_so = ss_top_q[0];

always @(posedge clk_sys) begin
	reg [32:0] nsum;

	drive_msum <= ntsc ? 32727264 : 31527954;

	nsum = drive_sum + 16000000;
	drive_ce <= 0;
	if (ss_chain_en) drive_sum <= ss_top_d[31:0];
	else if (~c64_pause) begin
		drive_sum <= nsum[31:0];
		if(nsum >= drive_msum) begin
			drive_sum <= nsum[31:0] - drive_msum;
			drive_ce <= 1;
		end
	end
end

wire disk_parport = (status[98:97] == 0) | par_on;

// c64_pause one clock later: the clocks where the drives (c1541_multi stop)
// and the C64 (EXT5 onwards) hold, so both sides are sampled on their grid
reg drv_pause = 0;
always @(posedge clk_sys) drv_pause <= c64_pause;

always @(posedge clk_sys) begin
	if (ss_chain_en) {drive_stb_o_old, drive_stb_i_old, drive_iec_clk_old, c64_iec_clk_old, disk_access_to, disk_access} <= ss_top_d[68:32];
	else if (~drv_pause) begin   // the 0.5 s timeout holds with the machine
		c64_iec_clk_old <= c64_iec_clk;
		drive_iec_clk_old <= drive_iec_clk;
		drive_stb_i_old <= drive_stb_i;
		drive_stb_o_old <= drive_stb_o;

		if(((c64_iec_clk_old != c64_iec_clk) || (drive_iec_clk_old != drive_iec_clk)) ||
			(disk_parport && ((drive_stb_i_old != drive_stb_i) || (drive_stb_o_old != drive_stb_o))))
		begin
			disk_access <= 1;
			disk_access_to <= 16000000; // 0.5s
		end
		else if(disk_access_to) disk_access_to <= disk_access_to - 1'd1;
		else disk_access <= 0;
	end
end

wire ext_iec_en   = status[25];
wire ext_iec_clk  = |snac_mode ? 1'b1 : (USER_IN[2] | ~ext_iec_en);
wire ext_iec_data = |snac_mode ? 1'b1 : (USER_IN[4] | ~ext_iec_en);

assign USER_OUT[2] = |snac_mode ? 1'b1 : ((c64_iec_clk & drive_iec_clk_o)  | ~ext_iec_en);
assign USER_OUT[3] = |snac_mode ? 1'b1 : ((reset_n & ~status[6]) | ~ext_iec_en);
assign USER_OUT[4] = |snac_mode ? 1'b1 : ((c64_iec_data & drive_iec_data_o) | ~ext_iec_en);
assign USER_OUT[5] = |snac_mode ? 1'b1 : (c64_iec_atn | ~ext_iec_en);
assign USER_OUT[6] = '1;


wire hsync;
wire vsync;
wire hblank;
wire vblank;
wire hsync_out;
wire vsync_out;
wire vs_tick;
wire vs_resume_ok;

video_sync sync
(
	.clk32(clk_sys),
	.pause(c64_pause),
	.hsync(hsync),
	.vsync(vsync),
	.vic_x(vic_x),
	.vic_y(vic_y),
	.ntsc(ntsc),
	.wide(wide),
	.hsync_out(hsync_out),
	.vsync_out(vsync_out),
	.hblank(hblank),
	.vblank(vblank),
	.tick(vs_tick),
	.resume_ok(vs_resume_ok)
);

reg hq2x160;
always @(posedge clk_sys) begin
	reg old_vsync;

	old_vsync <= vsync_out;
	if (!old_vsync && vsync_out) begin
		hq2x160 <= (status[10:8] == 2);
	end
end

reg ce_pix;
always @(posedge CLK_VIDEO) begin
	reg [2:0] div;
	reg       lores;

	div <= div + 1'b1;
	if(&div) lores <= ~lores;
	ce_pix <= (~lores | ~hq2x160) && !div;
end

wire scandoubler = status[10:8] || forced_scandoubler;

assign CLK_VIDEO = clk64;
assign VGA_SL    = (status[10:8] > 2) ? status[9:8] - 2'd2 : 2'd0;
assign VGA_F1    = 0;

reg [9:0] vcrop;
reg wide;
always @(posedge CLK_VIDEO) begin
	vcrop <= 0;
	wide <= 0;
	if(HDMI_WIDTH >= (HDMI_HEIGHT + HDMI_HEIGHT[11:1]) && !scandoubler) begin
		if(HDMI_HEIGHT == 480)  vcrop <= 240;
		if(HDMI_HEIGHT == 600)  begin vcrop <= 200; wide <= vcrop_en; end
		if(HDMI_HEIGHT == 720)  vcrop <= 240;
		if(HDMI_HEIGHT == 768)  vcrop <= 256; // NTSC mode has 250 visible lines only!
		if(HDMI_HEIGHT == 800)  begin vcrop <= 200; wide <= vcrop_en; end
		if(HDMI_HEIGHT == 1080) vcrop <= 10'd216;
		if(HDMI_HEIGHT == 1200) vcrop <= 240;
	end
	else if(HDMI_WIDTH >= 1440 && !scandoubler) begin
		// 1920x1440 and 2048x1536 are 4:3 resolutions and won't fit in the previous if statement ( width > height * 1.5 )
		if(HDMI_HEIGHT == 1440) vcrop <= 240;
		if(HDMI_HEIGHT == 1536) vcrop <= 256;
	end
end


wire [1:0] ar = status[5:4];
wire vcrop_en = status[32];
wire vga_de;
video_freak video_freak
(
	.*,
	.VGA_DE_IN(vga_de),
	.ARX((!ar) ? (wide ? 12'd340 : 12'd400) : (ar - 1'd1)),
	.ARY((!ar) ? 12'd300 : 12'd0),
	.CROP_SIZE(vcrop_en ? vcrop : 10'd0),
	.CROP_OFF(0),
	.SCALE(status[31:30])
);

// freeze changes only on a frame boundary of the scaler (freeze_sync), so HDMI
// keeps a whole frame.
wire freeze_sync;
reg freeze = 0;
always @(posedge clk_sys) begin
	reg old_sync;
	
	old_sync <= freeze_sync;
	if(old_sync ^ freeze_sync) freeze <= OSD_STATUS & status[42];
end

// The machine stops on a C64 cycle, but restarts only when video_sync's
// free-running position is back on the one of the stopped VIC (vs_resume_ok,
// at most one frame later; after a savestate load the loaded VIC): the sync
// on the analog output and into the scaler never jumps. A watchdog releases
// anyway after 4,194,303 clk_sys (~133 ms PAL) if alignment fails.
reg        pause_rel = 0;
reg [21:0] pause_wd = 0;
always @(posedge clk_sys) begin
	// a savestate operation holds the machine through ss_freeze: wait for a
	// realignment after it (the chain moves the VIC position meanwhile), not
	// for one that came during it
	if(~c64_pause | freeze | ss_freeze_req) begin
		pause_rel <= 0;
		pause_wd  <= 0;
	end
	else begin
		if(~&pause_wd) pause_wd <= pause_wd + 1'd1;
		if(vs_resume_ok | &pause_wd) pause_rel <= 1;
	end
end
assign c64_pause_in = freeze | (c64_pause & ~pause_rel);

// Frame buffer: while stopped, the analog output (and the scaler) show the
// last frame with a regular sync instead of a stopped VIC.
wire [3:0] out_idx;
pause_fb pause_fb
(
	.clk(clk_sys),
	.tick(vs_tick),
	.hblank(hblank),
	.vblank(vblank),
	.paused(c64_pause),
	.idx_in(vic_idx),
	.idx_out(out_idx)
);

wire [7:0] vr, vg, vb;
fpga64_rgbcolor out_palette
(
	.palette(status[84:82]),
	.index(out_idx),
	.r(vr),
	.g(vg),
	.b(vb)
);

// The scaler freeze of a savestate operation also changes only on a frame
// boundary (freeze_sync), as freeze does: released mid-frame, ascal took the
// frame being written as complete and showed its top lines from an old
// buffer (one garbage frame on HDMI after some saves and loads).
reg ss_hdmi_frz = 0;
always @(posedge clk_sys) begin
	reg old_sync;

	old_sync <= freeze_sync;
	if(old_sync ^ freeze_sync) ss_hdmi_frz <= ss_frz_ack;
end

assign HDMI_FREEZE = freeze | ss_hdmi_frz;

///////////////////////////////// savestates (WP A2) /////////////////////////////////
// docs/SAVESTATES.md. Four 21 MiB slots in DDR3 at 0x2AC00000 (SS2AC00000:1500000,
// D13), the scratch slot of the OSD self-test is the 21 MiB below them
// (0x29700000).

`include "rtl/savestate/c64_savestates.vh"

// build hash in the slot: BUILD_DATE "yymmdd" as BCD 0x00yymmdd
localparam [47:0] SS_BD = `BUILD_DATE;
localparam [31:0] SS_BUILD_HASH = {8'd0, SS_BD[43:40], SS_BD[35:32], SS_BD[27:24], SS_BD[19:16], SS_BD[11:8], SS_BD[3:0]};

// configuration compared on load (map.yaml config_mask)
wire [31:0] ss_config =
	({30'd0, status[54:53]} << `SS_CFG_REU_SIZE)        |
	({31'd0, status[52]}    << `SS_CFG_GEORAM)          |
	({31'd0, ss_drv_1581[0]} << `SS_CFG_DRIVE8_TYPE)    |   // 1 = 1581 (mounted D81)
	({31'd0, ss_drv_1581[1]} << `SS_CFG_DRIVE9_TYPE)    |
	({31'd0, status[13]}    << `SS_CFG_SID_LEFT_MODEL)  |
	({31'd0, status[16]}    << `SS_CFG_SID_RIGHT_MODEL) |
	({31'd0, status[2]}     << `SS_CFG_NTSC)            |
	({30'd0, status[35:34]} << `SS_CFG_VIC_VARIANT)     |
	({31'd0, status[45]}    << `SS_CFG_CIA_MODEL)       |
	({31'd0, status[12]}    << `SS_CFG_OPL_ENABLE)      |
	({30'd0, status[15:14]} << `SS_CFG_KERNAL)          |
	({24'd0, cart_attached ? cart_id : 8'hFF} << `SS_CFG_CART_TYPE);

// Boundary of the second freeze level (ss_freeze): every bit must be 1 on the
// sample where the machine stops. Blocks expose only their idle signal.
wire       ss_drv_ddr_idle;
wire [8:0] ss_idle = {
	ss_drv_ddr_idle,                                          // 8 drive track cache: no DDR3 transfer
	tape_ss_idle,                                             // 7 tape: no TAP prefetch byte in flight
	~ioctl_req_wr & ~ioctl_req_rd,                            // 6 SDRAM: no io-cycle access of the host pending (the EasyFlash write-back is on the chain)
	~ioctl_download & ~ioctl_upload & ~inj_meminit & ~erasing & ~force_erase, // 5 no download/upload/RAM init
	~|sd_rd & ~|sd_wr & ~|sd_ack,                             // 4 drives: no SD block transfer (c1541_track, 1581 sectors)
	ss_drv_idle,                                              // 3 1541/1581 x2: CPUs between instructions, no track or sector transfer starting
	~dma_req,                                                 // 2 REU: no DMA
	reset_n & ~RESET & ~status[0] & ~status[17] & ~buttons[1] & ~reset_wait, // 1 no reset pending
	c64_cpu_sync                                              // 0 C64 CPU between instructions
};

wire       ss_frz_forced;

// A machine stopped away from a boundary (OSD pause) runs to the next one for
// the engine on the sample after vs_resume_ok, when the video output is on
// the stopped VIC: the same timing as the pause release (pause_rel)
reg        ss_run_ok = 0;
always @(posedge clk_sys) ss_run_ok <= vs_resume_ok;

ss_freeze #(.N(9), .WDOG_BITS(27)) ss_frz
(
	.clk(clk_sys),
	.req(ss_freeze_req),
	.user_pause(c64_pause_in),
	.run_ok(ss_run_ok),
	.sample(refresh),
	.c64_pause(c64_pause),
	.idle(ss_idle),
	.pause(ss_pause),
	.ack(ss_frz_ack),
	.forced(ss_frz_forced),
	.block()
);

// engine
wire        ss_busy, ss_done, ss_result_load, ss_loading;
wire  [3:0] ss_result;
wire [31:0] ss_crc;
wire [28:0] ss_ddr_addr;
wire  [7:0] ss_ddr_burstcnt, ss_ddr_be;
wire [63:0] ss_ddr_wdata;
wire        ss_ddr_rd, ss_ddr_we, ss_ddr_busy, ss_ddr_rvalid;
wire        ss_sdr_req, ss_sdr_we, ss_sdr_zero, ss_sdr_ready, ss_sdr_rvalid, ss_sdr_wtake;
wire [63:0] ss_sdr_rdata, ss_sdr_wdata;
wire [11:0] ss_map_addr;
wire        ss_map_q, ss_map_we, ss_map_wdata;
wire        ss_eng_save, ss_eng_load, ss_eng_hold;
wire [28:0] ss_eng_addr;
wire        ss_inhibit = ioctl_download | ioctl_upload | ~reset_n | erasing | inj_meminit;

// REU_RAM region: the REU is in the SDRAM at REU_ADDR, size from the OSD option.
// Its pages written since power on go into the slot (D13).
wire [24:0] ss_reu_bytes = (reu_cfg == 2'd1) ? 25'h0080000 :
                           (reu_cfg == 2'd2) ? 25'h0200000 :
                           (reu_cfg == 2'd3) ? 25'h1000000 : 25'd0;

// regions present: RAM, Color RAM, REU and GeoRAM when enabled, cartridge RAM
// banks with a CRT attached (the EasyFlash RAM is bank 0), EasyFlash flash with
// an EasyFlash CRT (D2), RAM, RAM expansion and track buffer of both 1541 units
// (A8), RAM and sector buffer of both 1581 units (A10), the OPL3 register
// shadow with the Sound Expander on (A9).
wire [`SS_REGION_COUNT:0] ss_present =
	(1 << (`SS_RGN_RAM + 1)) | (1 << (`SS_RGN_COLORRAM + 1)) |
	({31'd0, |reu_cfg}       << (`SS_RGN_REU_RAM + 1))    |
	({31'd0, status[52] & ~cart_attached} << (`SS_RGN_GEORAM + 1)) |
	({31'd0, cart_attached}  << (`SS_RGN_CART_RAM + 1))   |
	({31'd0, cart_ezfl}      << (`SS_RGN_CART_FLASH + 1)) |
	(1 << (`SS_RGN_RAM_DRV8 + 1))    | (1 << (`SS_RGN_RAM_DRV9 + 1))    |
	(1 << (`SS_RGN_EXTRAM_DRV8 + 1)) | (1 << (`SS_RGN_EXTRAM_DRV9 + 1)) |
	(1 << (`SS_RGN_TRACK_DRV8 + 1))  | (1 << (`SS_RGN_TRACK_DRV9 + 1))  |
	(1 << (`SS_RGN_RAM_1581_8 + 1))  | (1 << (`SS_RGN_RAM_1581_9 + 1))  |
	(1 << (`SS_RGN_FDC_BUF_8 + 1))   | (1 << (`SS_RGN_FDC_BUF_9 + 1))   |
	({31'd0, opl_en}         << (`SS_RGN_OPL3_REGS + 1));

// LIVE: map.yaml segments inserted in the chain below (bit `SS_SEG_<NAME>)
savestates #(.BUILD_HASH(SS_BUILD_HASH), .LIVE((32'd1 << `SS_SEG_CPU) | (32'd1 << `SS_SEG_VIC) | (32'd1 << `SS_SEG_CIA1) |
                                               (32'd1 << `SS_SEG_CIA2) | (32'd1 << `SS_SEG_SID1) | (32'd1 << `SS_SEG_SID2) |
                                               (32'd1 << `SS_SEG_REU) | (32'd1 << `SS_SEG_CART) | (32'd1 << `SS_SEG_SYS) |
                                               (32'd1 << `SS_SEG_RTC) | (32'd1 << `SS_SEG_TAPE) | (32'd1 << `SS_SEG_INPUT) |
                                               (32'd1 << `SS_SEG_TOP) | (32'd1 << `SS_SEG_DRV8_1541) | (32'd1 << `SS_SEG_DRV9_1541) |
                                               (32'd1 << `SS_SEG_DRV8_1581) | (32'd1 << `SS_SEG_DRV9_1581) |
                                               (32'd1 << `SS_SEG_OPL3))) ss_engine
(
	.clk(clk_sys),
	.reset(~pll_locked),

	.save(ss_eng_save),
	.load(ss_eng_load),
	.slot_addr(ss_eng_addr),
	.hold(ss_eng_hold | ss_opl_replay),   // an OPL3 replay holds the machine until it is queued
	.sd_count(~status[99]),
	.inhibit(ss_inhibit),
	.busy(ss_busy),
	.done(ss_done),
	.result(ss_result),
	.result_load(ss_result_load),
	.last_crc(ss_crc),

	.freeze_req(ss_freeze_req),
	.freeze_ack(ss_frz_ack),
	.freeze_forced(ss_frz_forced),

	.config_mask(ss_config),
	.rgn_present(ss_present),
	.reu_bytes(ss_reu_bytes),

	.chain_en(ss_chain_en),
	.chain_so(ss_chain_so),
	.chain_si(ss_chain_si),
	.loading(ss_loading),
	.load_done(ss_load_done),

	.rgn_tag(ss_rgn_tag),
	.rgn_addr(ss_rgn_addr),
	.rgn_req(ss_rgn_req),
	.rgn_we(ss_rgn_we),
	.rgn_wdata(ss_rgn_wdata),
	.rgn_rdata(ss_rgn_rdata),
	.rgn_ack(ss_rgn_ack),
	.sd_req(ss_sdr_req),
	.sd_we(ss_sdr_we),
	.sd_zero(ss_sdr_zero),
	.sd_ready(ss_sdr_ready),
	.sd_rvalid(ss_sdr_rvalid),
	.sd_rdata(ss_sdr_rdata),
	.sd_wtake(ss_sdr_wtake),
	.sd_wdata(ss_sdr_wdata),

	.map_addr(ss_map_addr),
	.map_q(ss_map_q),
	.map_we(ss_map_we),
	.map_wdata(ss_map_wdata),

	.ddr_addr(ss_ddr_addr),
	.ddr_burstcnt(ss_ddr_burstcnt),
	.ddr_rd(ss_ddr_rd),
	.ddr_we(ss_ddr_we),
	.ddr_wdata(ss_ddr_wdata),
	.ddr_be(ss_ddr_be),
	.ddr_busy(ss_ddr_busy),
	.ddr_rdata(DDRAM_DOUT),
	.ddr_rvalid(ss_ddr_rvalid)
);

// Scan chain, in clk_sys: engine -> [segment with the highest map word
// address] -> ... -> [word 0] -> engine, each shifting on ss_chain_en. A chip
// WP inserts its segment here and sets its bit in LIVE above; segments not
// live are not on the chain (their words are written as 0). Live: TAPE ->
// RTC -> TOP (c64.sv) -> SYS (fpga64) -> ss_ext_so -> OPL3 -> DRV9_1581 ->
// DRV8_1581 -> DRV9_1541 -> DRV8_1541 (iec_drive) -> INPUT (mouse) -> CART
// (cartridge, DigiMax) -> REU -> ss_ext_si -> SID2 -> SID1 -> CIA2 -> CIA1 ->
// VIC -> CPU (fpga64).

// SDRAM regions in 256-byte transfers of sdram.v: RAM 0x0000000, cartridge
// RAM banks 0x0010000 (cartridge.v get_bank), EasyFlash flash 0x0200000
// (ezmem_addr), GeoRAM 0x0C00000 ({3'b011, geo_bank}), REU 0x1000000 (REU_ADDR)
reg [24:0] ss_rgn_sd_addr;
always @* begin
	case (ss_rgn_tag)
		`SS_TAG_REU_RAM:    ss_rgn_sd_addr = REU_ADDR + {1'b0, ss_rgn_addr};
		`SS_TAG_GEORAM:     ss_rgn_sd_addr = 25'h0C00000 + {3'b000, ss_rgn_addr[21:0]};
		`SS_TAG_CART_FLASH: ss_rgn_sd_addr = 25'h0200000 + {5'd0, ss_rgn_addr[19:0]};
		`SS_TAG_CART_RAM:   ss_rgn_sd_addr = 25'h0010000 + {9'd0, ss_rgn_addr[15:0]};
		default:            ss_rgn_sd_addr = {9'd0, ss_rgn_addr[15:0]};
	endcase
end

wire ss_reu_clr_done;
always @(posedge clk_sys) if (ss_reu_clr_done) ss_reu_clr <= 0;

ss_sdram_port #(.CLR_BASE(REU_ADDR)) ss_sdram
(
	.clk(clk_sys),
	.refresh(refresh),
	.enable(ss_frz_ack & ss_busy),
	.clear(ss_reu_clr),
	.clear_done(ss_reu_clr_done),

	.req(ss_sdr_req),
	.we(ss_sdr_we),
	.zero(ss_sdr_zero),
	.addr(ss_rgn_sd_addr),
	.ready(ss_sdr_ready),
	.rvalid(ss_sdr_rvalid),
	.rdata(ss_sdr_rdata),
	.wtake(ss_sdr_wtake),
	.wdata(ss_sdr_wdata),

	.own(ss_sd_own),
	.sd_req(ss_sd_req),
	.sd_we(ss_sd_we),
	.sd_addr(ss_sd_addr),
	.sd_din(ss_sd_din),
	.sd_wtgl(ss_sd_wtgl),
	.sd_rtgl(ss_sd_rtgl),
	.sd_dtgl(ss_sd_dtgl),
	.sd_dout(ss_sd_dout)
);

// REU pages written since power on (D13): every write of the machine into
// the REU lane of the SDRAM (REU DMA, REU file load, any other writer)
ss_reu_map ss_reu_pages
(
	.clk(clk_sys),
	.trk_we(~ss_sd_own & sdm_ce & sdm_we & sdm_addr[24]),
	.trk_page(sdm_addr[23:12]),
	.eng_we(ss_map_we),
	.eng_page(ss_map_addr),
	.eng_bit(ss_map_wdata),
	.rd_page(ss_map_addr),
	.q(ss_map_q)
);

// Color RAM: the engine borrows the fpga64 port (spram, 1 clock read latency)
reg       ss_cram_ack = 0;
reg [1:0] ss_cram_st = 0;
always @(posedge clk_sys) begin
	ss_cram_ack <= 0;
	ss_cram_we  <= 0;
	if (ss_rgn_req && ss_rgn_tag == `SS_TAG_COLORRAM) begin
		ss_cram_act  <= 1;
		ss_cram_addr <= ss_rgn_addr[9:0];
		ss_cram_we   <= ss_rgn_we;
		ss_cram_din  <= ss_rgn_wdata[3:0];
		ss_cram_st   <= 1;
	end
	else if (ss_cram_st == 1) ss_cram_st <= 2;
	else if (ss_cram_st == 2) begin
		ss_cram_st  <= 0;
		ss_cram_ack <= 1;
	end
	if (~ss_busy) ss_cram_act <= 0;
end

// Drive regions through the byte port of iec_drive (block RAM port a, 3 clocks
// per byte): RAM, RAM expansion and track buffer of each 1541 unit, RAM and
// sector buffer (WD1772 FIFO) of each 1581 unit
assign ss_drv_rgn_sel = {ss_rgn_tag == `SS_TAG_TRACK_DRV9, ss_rgn_tag == `SS_TAG_EXTRAM_DRV9, ss_rgn_tag == `SS_TAG_RAM_DRV9,
                         ss_rgn_tag == `SS_TAG_TRACK_DRV8, ss_rgn_tag == `SS_TAG_EXTRAM_DRV8, ss_rgn_tag == `SS_TAG_RAM_DRV8};
assign ss_drv_rgn_sel81 = {ss_rgn_tag == `SS_TAG_FDC_BUF_9, ss_rgn_tag == `SS_TAG_RAM_1581_9,
                           ss_rgn_tag == `SS_TAG_FDC_BUF_8, ss_rgn_tag == `SS_TAG_RAM_1581_8};

assign ss_rgn_ack   = ss_cram_ack | ss_drv_rgn_ack | ss_opl_rgn_ack;
assign ss_rgn_rdata = ss_cram_ack ? {4'h0, ss_cram_q} : ss_drv_rgn_ack ? ss_drv_rgn_rdata : ss_opl_rgn_rdata;

// DDR3: drive track cache and savestate engine
ss_ddram_arb ss_ddr
(
	.clk(clk_sys),

	.d_burstcnt(drv_ddram_burstcnt),
	.d_addr(drv_ddram_addr),
	.d_rd(drv_ddram_rd),
	.d_we(drv_ddram_we),
	.d_din(drv_ddram_din),
	.d_be(drv_ddram_be),
	.d_busy(drv_ddram_busy),
	.d_dout_ready(drv_ddram_ready),
	.d_idle(ss_drv_ddr_idle),

	.e_burstcnt(ss_ddr_burstcnt),
	.e_addr(ss_ddr_addr),
	.e_rd(ss_ddr_rd),
	.e_we(ss_ddr_we),
	.e_din(ss_ddr_wdata),
	.e_be(ss_ddr_be),
	.e_busy(ss_ddr_busy),
	.e_dout_ready(ss_ddr_rvalid),

	.DDRAM_BUSY(DDRAM_BUSY),
	.DDRAM_BURSTCNT(DDRAM_BURSTCNT),
	.DDRAM_ADDR(DDRAM_ADDR),
	.DDRAM_DOUT(DDRAM_DOUT),
	.DDRAM_DOUT_READY(DDRAM_DOUT_READY),
	.DDRAM_RD(DDRAM_RD),
	.DDRAM_WE(DDRAM_WE),
	.DDRAM_DIN(DDRAM_DIN),
	.DDRAM_BE(DDRAM_BE)
);

// requests and self-test
wire [1:0] ss_active_slot;
wire       ss_active_load, ss_active_test, ss_test_done, ss_test_pass;
wire       ss_ui_save, ss_ui_load, ss_ui_test;

statemanager #(.BASE(`SS_DDR_BASE >> 3), .SLOT_WORDS(`SS_SLOT_BYTES >> 3)) ss_mgr
(
	.clk(clk_sys),
	.reset(~reset_n),
	.slot(ss_slot),
	.save(ss_ui_save),
	.load(ss_ui_load),
	.selftest(ss_ui_test),
	.eng_save(ss_eng_save),
	.eng_load(ss_eng_load),
	.eng_addr(ss_eng_addr),
	.eng_hold(ss_eng_hold),
	.eng_busy(ss_busy | ss_opl_replay),   // next operation after the OPL3 replay
	.eng_done(ss_done),
	.eng_result(ss_result),
	.eng_crc(ss_crc),
	.active_slot(ss_active_slot),
	.active_load(ss_active_load),
	.active_test(ss_active_test),
	.test_done(ss_test_done),
	.test_pass(ss_test_pass)
);

savestate_ui #(.INFO_TIMEOUT_BITS(25)) ss_ui
(
	.clk(clk_sys),
	.ps2_key(ps2_key),
	.allow_ss(reset_n & ~ioctl_download & ~ioctl_upload),
	.joySS(joy[10]),
	.joyRight(joy[0]),
	.joyLeft(joy[1]),
	.joyDown(joy[2]),
	.joyUp(joy[3]),
	.status_slot(status[101:100]),
	.OSD_saveload(status[104:102]),
	.ss_save(ss_ui_save),
	.ss_load(ss_ui_load),
	.ss_test(ss_ui_test),
	.ss_info_req(ss_info_req),
	.ss_info(ss_info),
	.kbd_eat(ss_kbd_eat),
	.ss_done(ss_done),
	.ss_result(ss_result),
	.ss_test_active(ss_active_test),
	.ss_test_done(ss_test_done),
	.ss_test_pass(ss_test_pass),
	.ss_active_slot(ss_active_slot),
	.ss_active_load(ss_active_load),
	.statusUpdate(ss_status_upd),
	.selected_slot(ss_slot)
);

// Snoop DDRAM reads and writes for debug overlay
reg [63:0] dbg_ddram_data = 0;
reg [31:0] dbg_ddram_addr = 0;
reg [31:0] dbg_out_addr   = 0;
reg        dbg_wait_data  = 0;
reg        dbg_valid      = 0;
reg  [7:0] dbg_burst_cnt  = 0;

reg [63:0] dbg_wr_data    = 0;
reg [31:0] dbg_wr_addr    = 0;
reg        dbg_wr_valid   = 0;

always @(posedge clk_sys) begin
    reg old_rd, old_we;

    old_rd <= drv_ddram_rd;
    old_we <= drv_ddram_we;

    dbg_valid <= 0;
    if (~old_rd & drv_ddram_rd) begin
		dbg_ddram_addr <= {3'b0, drv_ddram_addr};
        dbg_burst_cnt <= drv_ddram_burstcnt;
        dbg_wait_data <= 1;
		end

		if (drv_ddram_ready && dbg_wait_data) begin
			dbg_ddram_data <= DDRAM_DOUT;
			dbg_out_addr   <= dbg_ddram_addr;
			dbg_valid      <= 1;

			if (dbg_burst_cnt <= 8'd1) begin
				dbg_wait_data  <= 0;
			end else begin
				dbg_burst_cnt  <= dbg_burst_cnt - 8'd1;
				dbg_ddram_addr <= dbg_ddram_addr + 1'd1;
			end
		end

    dbg_wr_valid <= 0;
    if (~old_we & drv_ddram_we) begin
		dbg_wr_addr <= {3'b0, drv_ddram_addr};
        dbg_wr_data <= drv_ddram_din;
        dbg_wr_valid <= 1;
	end
end

// Allow cursor keys to change debug base addr for overlay
// addr stepsize h008 for cursor up & down
// addr stepsize h100 for cursor left & right
// timed autorepeat and debounce

reg [31:0] dbg_base_addr = 32'h06000000;
reg old_ps2_stb;
reg [23:0] repeat_timer;
reg repeat_active;
reg dir_up;
reg dir_down;
reg dir_left;
reg dir_right;

always @(posedge clk_sys) begin
    old_ps2_stb <= ps2_key[10];

    if (old_ps2_stb != ps2_key[10]) begin
        if (ps2_key[9]) begin
            if (ps2_key[8] && ps2_key[7:0] == 8'h75) begin // Up Arrow
                dbg_base_addr <= dbg_base_addr - 8;
                dir_up <= 1; dir_down <= 0; dir_left <= 0; dir_right <= 0;
                repeat_timer <= 24'd15000000; // ~0.3s delay
                repeat_active <= 1;
            end else if (ps2_key[8] && ps2_key[7:0] == 8'h72) begin // Down Arrow
                dbg_base_addr <= dbg_base_addr + 8;
                dir_up <= 0; dir_down <= 1; dir_left <= 0; dir_right <= 0;
                repeat_timer <= 24'd15000000;
                repeat_active <= 1;
            end else if (ps2_key[8] && ps2_key[7:0] == 8'h6B) begin // Left Arrow
                dbg_base_addr <= dbg_base_addr - 32'h100;
                dir_up <= 0; dir_down <= 0; dir_left <= 1; dir_right <= 0;
                repeat_timer <= 24'd15000000;
                repeat_active <= 1;
            end else if (ps2_key[8] && ps2_key[7:0] == 8'h74) begin // Right Arrow
                dbg_base_addr <= dbg_base_addr + 32'h100;
                dir_up <= 0; dir_down <= 0; dir_left <= 0; dir_right <= 1;
                repeat_timer <= 24'd15000000;
                repeat_active <= 1;
            end else begin
                repeat_active <= 0;
            end
        end else begin
            if ((ps2_key[8] && ps2_key[7:0] == 8'h75 && dir_up) ||
                (ps2_key[8] && ps2_key[7:0] == 8'h72 && dir_down) ||
                (ps2_key[8] && ps2_key[7:0] == 8'h6B && dir_left) ||
                (ps2_key[8] && ps2_key[7:0] == 8'h74 && dir_right)) begin
                repeat_active <= 0;
                dir_up <= 0;
                dir_down <= 0;
                dir_left <= 0;
                dir_right <= 0;
            end
        end
    end else if (repeat_active) begin
        if (repeat_timer == 0) begin
            if (dir_up) dbg_base_addr <= dbg_base_addr - 8;
            if (dir_down) dbg_base_addr <= dbg_base_addr + 8;
            if (dir_left) dbg_base_addr <= dbg_base_addr - 32'h100;
            if (dir_right) dbg_base_addr <= dbg_base_addr + 32'h100;
            repeat_timer <= 24'd2000000; // ~0.04s repeat
        end else begin
            repeat_timer <= repeat_timer - 1'd1;
        end
    end
end

// Drive Overlay display:
//  - three modes: on activity (default), if enabled, debug and off
//  - color coded: green for idle (only shows in "if enabled" and "debug" mode)
//                 yellow for (read) activity (via drive led)
//                 red for write activity (covers writes to disk & flushing to sd)
//  - track number: Full tracks and half tracks (e.g. 33.5)
//  - drive number: (#8, #9)
//  - auto adjusts for pal/ntsc
//
// debug mode captures DDRAM reads/writes:
//  - reads displayed on the left (green), writes on the right (yellow)
//  - rolling buffer (top 8 lines) shows the last 8 reads/writes and addresses
//  - base address captures (botoom 8 lines) shows 8 read/writes starting at base address
//  - base address can be changed in real time with cursor keys (left, right, up, down)
//  - captures live read/writes not memory content, so set address before you expect read/writes (!)
//
//
wire [2:0] drv_ovl_color;

reg [1:0] ce_sys_div = 0;
wire ce_sys = (ce_sys_div == 0);
always @(posedge clk_sys) ce_sys_div <= ce_sys_div + 1'd1;

drv_overlay drv_ovl (
	.clk(clk_sys),
	.ce(ce_sys),
	.hblank(hblank),
	.vblank(vblank),

	.drive_osd_mode(status[86:85]),
	.ntsc(ntsc),
	.drive_led(drive_led),
	.drive_mounted(drive_mounted),
	.drive_track_0(drive_track[0]),
	.drive_track_1(drive_track[1]),
	.drive_we(drive_we),

	.valid(dbg_valid),
	.addr(dbg_out_addr),
	.data(dbg_ddram_data),
	.wr_valid(dbg_wr_valid),
	.wr_addr(dbg_wr_addr),
	.wr_data(dbg_wr_data),
	.base_addr(dbg_base_addr),

	.pixel_color(drv_ovl_color)
);

reg [2:0] ovl_color;
always @(posedge CLK_VIDEO) ovl_color <= tape_ovl_color | drv_ovl_color;

video_mixer #(.GAMMA(1)) video_mixer
(
	.CLK_VIDEO(CLK_VIDEO),

	.hq2x(~status[10] & (status[9] ^ status[8])),
	.scandoubler(scandoubler),
	.gamma_bus(gamma_bus),

	.ce_pix(ce_pix),
	.R((ovl_color & 4) ? 8'hFF : ovl_color ? 8'h00 : vr),
	.G((ovl_color & 2) ? 8'hFF : ovl_color ? 8'h00 : vg),
	.B((ovl_color & 1) ? 8'hFF : ovl_color ? 8'h00 : vb),
	.HSync(hsync_out),
	.VSync(vsync_out),
	.HBlank(hblank),
	.VBlank(vblank),

	.HDMI_FREEZE(HDMI_FREEZE),
	.freeze_sync(freeze_sync),

	.CE_PIXEL(CE_PIXEL),
	.VGA_R(VGA_R),
	.VGA_G(VGA_G),
	.VGA_B(VGA_B),
	.VGA_VS(VGA_VS),
	.VGA_HS(VGA_HS),
	.VGA_DE(vga_de)
);

wire        opl_en = status[12];
wire [15:0] opl_out;
wire  [7:0] opl_dout;
opl3 #(.OPLCLK(47291931)) opl_inst
(
	.clk(clk_sys),
	.clk_opl(clk48),
	.rst_n(reset_n & opl_en),
	.pause(c64_pause),

	.addr(c64_addr[4]),
	.dout(opl_dout),
	.we(ram_we & IOF & opl_en & c64_addr[6] & ~c64_addr[5]),
	.din(c64_data_out),

	.sample_l(opl_out),

	// segment OPL3: ss_ext_so (SYS) -> OPL3 -> 1541 x2; region OPL3_REGS
	.ss_en(ss_chain_en),
	.ss_hold(ss_frz_ack),
	.ss_load_done(ss_load_done),
	.ss_si(ss_ext_so),
	.ss_so(ss_opl_so),
	.ss_replay(ss_opl_replay),
	.ss_rgn_sel(ss_rgn_tag == `SS_TAG_OPL3_REGS),
	.ss_rgn_req(ss_rgn_req),
	.ss_rgn_we(ss_rgn_we),
	.ss_rgn_addr(ss_rgn_addr[7:0]),
	.ss_rgn_wdata(ss_rgn_wdata),
	.ss_rgn_rdata(ss_opl_rgn_rdata),
	.ss_rgn_ack(ss_opl_rgn_ack)
);

// The FM part runs on clk48 and stops a few clocks after the machine: the mix
// takes its sample once per running C64 cycle (DMA0), so a pause or a save
// leaves no trace in the mix.
reg [15:0] opl_s;
always @(posedge clk_sys) if (ext_cycle & ~ext_cycle_d) opl_s <= opl_out;

reg ioe_we, iof_we;
always @(posedge clk_sys) begin
	reg old_ioe, old_iof;

	old_ioe <= IOE;
	ioe_we <= ~old_ioe & IOE & ram_we;

	old_iof <= IOF;
	iof_we <= ~old_iof & IOF & ram_we;
end

reg [11:0] sid_ld_addr = 0;
reg [15:0] sid_ld_data = 0;
reg        sid_ld_wr   = 0;
always @(posedge clk_sys) begin
	sid_ld_wr <= 0;
	if(ioctl_wr && load_flt && ioctl_addr < 6144) begin
		if(ioctl_addr[0]) begin
			sid_ld_data[15:8] <= ioctl_data;
			sid_ld_addr <= ioctl_addr[12:1];
			sid_ld_wr <= 1;
		end
		else begin
			sid_ld_data[7:0] <= ioctl_data;
		end
	end
end

// DigiMax (savestate segment CART, after cartridge.v: digimax_act then
// digimax_dac[0..3] from bit 0; dac_l/dac_r are rebuilt every clock)
reg [8:0] dac_l, dac_r;
reg [8:0] digimax_dac[4];
reg [3:0] digimax_act;
wire [39:0] ss_dmax_q = {digimax_dac[3], digimax_dac[2], digimax_dac[1], digimax_dac[0], digimax_act};
assign ss_dmax_so = ss_dmax_q[0];
always @(posedge clk_sys) begin
	if (ss_chain_en) {digimax_dac[3], digimax_dac[2], digimax_dac[1], digimax_dac[0], digimax_act} <= {ss_cart_so, ss_dmax_q[39:1]};
	else if (~c64_pause) begin   // holds with the machine (and while the chain shifts)
		if(!status[41:40] || ~reset_n) begin
			digimax_dac <= '{0,0,0,0};
			digimax_act <= 0;
		end
		else if((status[41] ? iof_we : ioe_we) && ~c64_addr[2]) begin
			digimax_dac[c64_addr[1:0]] <= c64_data_out;
			if(c64_data_out) digimax_act[c64_addr[1:0]] <= 1;
		end
	end

	// guess mono/stereo/4-chan modes
	if(digimax_act<2) begin
		dac_l <= digimax_dac[0] + digimax_dac[0];
		dac_r <= digimax_dac[0] + digimax_dac[0];
	end
	else if(digimax_act<3) begin
		dac_l <= digimax_dac[1] + digimax_dac[1];
		dac_r <= digimax_dac[0] + digimax_dac[0];
	end
	else begin
		dac_l <= digimax_dac[1] + digimax_dac[2];
		dac_r <= digimax_dac[0] + digimax_dac[3];
	end
end

localparam [3:0] comp_f1 = 4;
localparam [3:0] comp_a1 = 2;
localparam       comp_x1 = ((32767 * (comp_f1 - 1)) / ((comp_f1 * comp_a1) - 1)) + 1; // +1 to make sure it won't overflow
localparam       comp_b1 = comp_x1 * comp_a1;

function [15:0] compr; input [15:0] inp;
	reg [15:0] v, v1;
	begin
		v  = inp[15] ? (~inp) + 1'd1 : inp;
		v1 = (v < comp_x1[15:0]) ? (v * comp_a1) : (((v - comp_x1[15:0])/comp_f1) + comp_b1[15:0]);
		v  = v1;
		compr = inp[15] ? ~(v-1'd1) : v;
	end
endfunction

reg [15:0] alo,aro;
always @(posedge clk_sys) begin
	reg [16:0] alm,arm;
	reg [15:0] cout;
	reg [15:0] cin;
	
	cin  <= opl_s - {{3{opl_s[15]}},opl_s[15:3]};
	cout <= compr(cin);

	alm <= {cout[15],cout} + {audio_l[17],audio_l[17:2]} + {2'b0,dac_l,6'd0} + {cass_snd, 9'd0};
	arm <= {cout[15],cout} + {audio_r[17],audio_r[17:2]} + {2'b0,dac_r,6'd0} + {cass_snd, 9'd0};
	alo <= ^alm[16:15] ? {alm[16], {15{alm[15]}}} : alm[15:0];
	aro <= ^arm[16:15] ? {arm[16], {15{arm[15]}}} : arm[15:0];
end

assign AUDIO_L = alo;
assign AUDIO_R = aro;
assign AUDIO_S = 1;
assign AUDIO_MIX = status[19:18];

//------------- TAP / C1530 Datassette -------------------

wire       cass_write;
wire       cass_motor;
wire       cass_sense;
wire       cass_read;
wire       cass_run;
wire       cass_finish;
wire       cass_snd = cass_read & ~cass_run & status[11] & ~cass_finish;

wire       tap_loaded;
wire [24:0] tap_play_addr;
wire [24:0] tap_last_addr;

wire [2:0] tape_ovl_color;

tape_subsystem tape
(
	.clk(clk_sys),
	.ce(ce_sys),
	.pause(c64_pause),
	.reset_n(reset_n),
	.hblank(hblank),
	.vblank(vblank),
	.ntsc(ntsc),

	.ioctl_download(ioctl_download),
	.ioctl_wr(ioctl_wr),
	.ioctl_addr(ioctl_addr),
	.ioctl_data(ioctl_data),
	.load_tap(load_tap),
	.ioctl_wait(tape_ioctl_wait),

	.io_cycle(io_cycle),
	.sdram_data(sdram_data),

	.cmd_play(status[7] | tape_play),
	.cmd_stop(status[95] | tape_key_stop),
	.cmd_rew(status[93] | tape_key_rew),
	.cmd_ff(status[94] | tape_key_ff),
	.cmd_unload(status[23]),
	.cmd_counter_reset(status[91] | tape_key_counter_reset),
	.counter_enable(status[92]),
	.tape_autoplay_off(status[39]),
	.tape_autounload_off(status[96]),

	.cass_write(cass_write),
	.cass_motor(cass_motor),
	.cass_sense(cass_sense),
	.cass_read(cass_read),
	.cass_run(cass_run),
	.cass_finish(cass_finish),

	.tap_loaded(tap_loaded),
	.tap_play_addr(tap_play_addr),
	.ss_idle(tape_ss_idle),
	.tap_last_addr(tap_last_addr),

	.pixel_color(tape_ovl_color),

	.ss_en(ss_chain_en),
	.ss_hold(ss_frz_ack),
	.ss_si(ss_chain_so),
	.ss_so(ss_tapess_so)
);

// TAPE segment (WP A7), first in from the engine: chain_so -> tape_subsystem
// -> use_tape_to, ss_use_tape (bit 0 leaves first) -> RTC. use_tape drives
// the cassette sense mux and the RTC reset on every clock: the chain carries
// its copy ss_use_tape. The 4 s timeout holds with the machine.
reg        use_tape;
reg [31:0] use_tape_to = 0;
reg        ss_use_tape;
wire [32:0] ss_tapeg_q = {ss_use_tape, use_tape_to};
assign ss_tape_so = ss_tapeg_q[0];
always @(posedge clk_sys) begin
	if (ss_chain_en) {ss_use_tape, use_tape_to} <= {ss_tapess_so, ss_tapeg_q[32:1]};
	else if (~ss_frz_ack) ss_use_tape <= use_tape;

	if (~c64_pause & ~ss_chain_en) begin
		if(use_tape_to) use_tape_to <= use_tape_to - 1'd1;
		else use_tape <= status[36];

		if(tap_loaded | ~cass_sense) begin
			use_tape <= 1;
			use_tape_to <= 128000000; //4s
		end
	end
	if (ss_load_done) use_tape <= ss_use_tape;
end

reg [26:0] act_cnt;
always @(posedge clk_sys) act_cnt <= act_cnt + (cass_sense ? 4'd1 : 4'd8);
wire tape_led = tap_loaded && (act_cnt[26] ? (~(~cass_sense & cass_motor) && act_cnt[25:18] > act_cnt[7:0]) : act_cnt[25:18] <= act_cnt[7:0]);

wire tape_adc, tape_adc_act;
ltc2308_tape #(.CLK_RATE(32000000)) ltc2308_tape
(
  .clk(clk_sys),
  .ADC_BUS(ADC_BUS),
  .dout(tape_adc),
  .active(tape_adc_act)
);

//------------- USER PORT -----------------

wire [7:0] pb_i, pb_o;
wire       pa2_i, pa2_o;
wire       pc2_n_o;
wire       flag2_n_i;
wire       sp2_i, sp2_o, sp1_o, sp1_i;
wire       cnt2_i, cnt2_o, cnt1_o, cnt1_i;

always_comb begin
	pa2_i       = 1;
	flag2_n_i   = 1;
	sp1_i       = 1;
	sp2_i       = 1;
	cnt1_i      = 1;
	cnt2_i      = 1;
	pb_i        = 8'hFF;
	UART_TXD    = 1;
	UART_RTS    = 0;
	UART_DTR    = 0;
	drive_par_i = 8'hFF;
	drive_stb_i = 1;
	USER_OUT[0] = 1;
	USER_OUT[1] = 1;

	// Parallel Cable: Auto uses the idle timer; On keeps the cable connected.
	if(par_on | (disk_parport & disk_access)) begin
		drive_par_i = pb_o;
		drive_stb_i = pc2_n_o;
		pb_i        = drive_par_o;
		flag2_n_i   = drive_stb_o;
	end
	else if(status[43]) begin
		UART_TXD  = pa2_o & uart_int;
		flag2_n_i = uart_rxd;
		sp2_i     = uart_rxd;
		pb_i[0]   = uart_rxd;
		UART_RTS  = ~pb_o[1] & uart_int;
		UART_DTR  = ~pb_o[2] & uart_int;
		pb_i[4]   = ~uart_dsr;
		pb_i[6]   = ~uart_cts;
		pb_i[7]   = ~uart_dsr;

		USER_OUT[1] = pa2_o | uart_int;

		if(~status[51]) begin
			UART_TXD = pa2_o & sp1_o & uart_int;
			pb_i[7]  = cnt2_o;
			cnt2_i   = pb_o[7];

			USER_OUT[1] = (pa2_o & sp1_o) | uart_int;
		end
	end
	else begin
		pb_i[5:0] = {!joyD_c64[6:4], !joyC_c64[6:4], pb_o[7] ? ~joyC_c64[3:0] : ~joyD_c64[3:0]};
	end
end

wire uart_int = ~status[33];

reg uart_rxd, uart_dsr, uart_cts;
always @(posedge clk_sys) begin
	reg rxd1, rxd2, dsr1, dsr2, cts1, cts2;

	rxd1 <= uart_int ? UART_RXD : USER_IN[0]; rxd2 <= rxd1; if(rxd1 == rxd2) uart_rxd <= rxd2;
	cts1 <= UART_CTS & uart_int; cts2 <= cts1; if(cts1 == cts2) uart_cts <= cts2;
	dsr1 <= UART_DSR & uart_int; dsr2 <= dsr1; if(dsr1 == dsr2) uart_dsr <= dsr2;
end

// RTC segment (WP A7): engine chain_so -> rtcF83 -> use_rtc_to, ss_use_rtc
// (bit 0 leaves first) -> fpga64 ss_chain_si. use_rtc drives the cassette
// read line on every clock: the chain carries its copy ss_use_rtc.
wire rtcF83_sda;
wire ss_rtcf_so;
rtcF83 #(16000000, 0) rtcF83
(
	.clk(clk_sys),
	.ce(drive_ce & ~c64_pause),
	.reset(~reset_n | use_tape),
	.RTC(RTC),
	.scl_i(cass_write),
	.sda_i(cass_motor),
	.sda_o(rtcF83_sda),

	.stop(c64_pause),
	.ss_en(ss_chain_en),
	.ss_hold(ss_frz_ack),
	.ss_load_done(ss_load_done),
	.ss_si(ss_tape_so),
	.ss_so(ss_rtcf_so)
);

reg        use_rtc = 0;
reg [20:0] use_rtc_to = 0;
reg        ss_use_rtc;
wire [21:0] ss_rtc_q = {ss_use_rtc, use_rtc_to};
assign ss_rtc_so = ss_rtc_q[0];
always @(posedge clk_sys) begin
	if (ss_chain_en) {ss_use_rtc, use_rtc_to} <= {ss_rtcf_so, ss_rtc_q[21:1]};
	else if (~ss_frz_ack) ss_use_rtc <= use_rtc;

	if (~c64_pause & ~ss_chain_en) begin   // the timeout holds with the machine
		if(use_rtc_to) use_rtc_to <= use_rtc_to - 1'd1;
		use_rtc <= |use_rtc_to;

		if(cass_write) use_rtc_to <= '1;
	end
	if (ss_load_done) use_rtc <= ss_use_rtc;
end

wire cass_rtc = ~(rtcF83_sda & use_rtc & cass_motor);

endmodule
