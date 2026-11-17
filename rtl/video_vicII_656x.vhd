-- -----------------------------------------------------------------------
--
--                                 FPGA 64
--
--     A fully functional commodore 64 implementation in a single FPGA
--
-- -----------------------------------------------------------------------
-- Peter Wendrich (pwsoft@syntiac.com)
-- http://www.syntiac.com/fpga64.html
-- -----------------------------------------------------------------------
--
-- VIC-II - Video Interface Chip no 2
--
-- -----------------------------------------------------------------------
-- Dar 08/03/2014 : shift hsync to sprite #3
-- -----------------------------------------------------------------------

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.numeric_std.ALL;

entity video_vicii_656x is
	generic (
		registeredAddress : boolean;
		emulateRefresh : boolean := false;
		emulateLightpen : boolean := false;
		emulateGraphics : boolean := true
	);
	port (
		clk: in std_logic;
		-- phi = 0 is VIC cycle
		-- phi = 1 is CPU cycle (only used by VIC when BA is low)
		phi : in std_logic;
		enaData : in std_logic;
		enaPixel : in std_logic;

		baSync : in std_logic;
		ba: out std_logic;
		ba_dma : out std_logic;

		mode6569 : in std_logic; -- PAL 63 cycles and 312 lines
		mode6567old : in std_logic; -- old NTSC 64 cycles and 262 line
		mode6567R8 : in std_logic; -- new NTSC 65 cycles and 263 line
		mode6572 : in std_logic; -- PAL-N 65 cycles and 312 lines

		turbo_en   : in  std_logic;
		turbo_state: out std_logic;

		variant : in std_logic_vector(1 downto 0); -- 00 - NMOS, 01 - HMOS, 10 - old HMOS
		reset : in std_logic;
		cs : in std_logic;
		we : in std_logic;
		lp_n : in std_logic;

		aRegisters: in unsigned(5 downto 0);
		diRegisters: in unsigned(7 downto 0);

		di: in unsigned(7 downto 0);
		diColor: in unsigned(3 downto 0);
		do: out unsigned(7 downto 0);

		vicAddr: out unsigned(13 downto 0);
		irq_n: out std_logic;

		-- Video output
		hSync : out std_logic;
		vSync : out std_logic;
		colorIndex : out unsigned(3 downto 0);
		-- raster position for the output sync of the core (c64.sv video_sync):
		-- X, and the raster line with the delayed step of the last line to
		-- line 0 already applied
		rasterXpos : out unsigned(9 downto 0);
		rasterYpos : out unsigned(8 downto 0);

		-- Debug outputs
		debugX  : out unsigned(9 downto 0);
		debugY  : out unsigned(8 downto 0);
		vicRefresh : out std_logic;
		addrValid : out std_logic;

		-- savestate scan chain, segment VIC (WP A5, docs/SAVESTATES.md):
		-- ss_en shifts, ss_hold freezes every process that runs on each clock
		ss_en    : in  std_logic := '0';
		ss_hold  : in  std_logic := '0';
		ss_si    : in  std_logic := '0';
		ss_so    : out std_logic
	);
end entity;

architecture rtl of video_vicii_656x is
	type vicCycles is (
		cycleRefresh1, cycleRefresh2, cycleRefresh3, cycleRefresh4, cycleRefresh5,
		cycleIdle1, cycleIdle2,
		cycleChar,
		cycleCalcSprites, cycleSpriteBa1, cycleSpriteBa2, cycleSpriteBa3,
		cycleSpriteA, cycleSpriteB
	);
	subtype ColorDef is unsigned(3 downto 0);
	type MFlags is array(0 to 7) of boolean;
	type MXdef is array(0 to 7) of unsigned(8 downto 0);
	type MYdef is array(0 to 7) of unsigned(7 downto 0);
	type MCntDef is array(0 to 7) of unsigned(5 downto 0);
	type MPixelsDef is array(0 to 7) of unsigned(23 downto 0);
	type MCurrentPixelDef is array(0 to 7) of unsigned(1 downto 0);
	type charStoreDef is array(38 downto 0) of unsigned(11 downto 0);
	type spriteColorsDef is array(7 downto 0) of unsigned(3 downto 0);
	type pixelColorStoreDef is array(7 downto 0) of unsigned(3 downto 0);

	constant PIX_DELAY : integer := 6;

-- State machine
	signal lastLineFlag : boolean; -- True for on last line of the frame.
	-- vicCycle is stored as a vector ('pos of the enum): a chain cell must hold
	-- any bit pattern while the chain shifts
	signal vicCycle_v : std_logic_vector(3 downto 0) := "0000";
	signal vicCycle : vicCycles;
	signal sprite : unsigned(2 downto 0) := "000";
	signal shiftChars : boolean;
	signal shiftLoadEna : boolean;
	signal idle: std_logic := '1';
	signal rasterIrqDone : std_logic; -- Only one interrupt each rasterLine
	signal rasterEnable: std_logic;

-- BA signal
	signal badLine : boolean; -- true if we have a badline condition
	signal baLoc : std_logic;
	signal baCnt : unsigned(2 downto 0);

	signal baChars : std_logic;
	signal baSprite04 : std_logic;
	signal baSprite15 : std_logic;
	signal baSprite26 : std_logic;
	signal baSprite37 : std_logic;
	signal baSpriteLast : std_logic;

-- Memory refresh cycles
	signal refreshCounter : unsigned(7 downto 0);

-- User registers
	signal MX : MXdef; -- Sprite X
	signal MY : MYdef; -- Sprite Y
	signal ME : unsigned(7 downto 0); -- Sprite enable
	signal MXE : unsigned(7 downto 0); -- Sprite X expansion
	signal MYE : unsigned(7 downto 0); -- Sprite Y expansion
	signal MPRIO : unsigned(7 downto 0); -- Sprite priority

	signal MC : unsigned(7 downto 0); -- sprite multi color
	signal MCDelay : unsigned(7 downto 0); -- sprite multi color
	signal MCColorDelay : unsigned(7 downto 0);
	signal MCColor : unsigned(7 downto 0); -- sprite multi color switch for color decoding

	-- mode
	signal BMM: std_logic; -- Bitmap mode
	signal BMMDelay: std_logic;
	signal ECM: std_logic; -- Extended color mode
	signal ECMDelay: std_logic;
	signal MCM: std_logic; -- Multi color mode
	signal MCMDelay: std_logic;
	signal DEN: std_logic; -- DMA enable
	signal RSEL: std_logic; -- Visible rows selection (24/25)
	signal CSEL: std_logic; -- Visible columns selection (38/40)

	signal RES: std_logic;

	signal VM: unsigned(13 downto 10);
	signal CB: unsigned(13 downto 11);

	signal EC : ColorDef;  -- border color
	signal B0C : ColorDef; -- background color 0
	signal B1C : ColorDef; -- background color 1
	signal B2C : ColorDef; -- background color 2
	signal B3C : ColorDef; -- background color 3
	signal MM0 : ColorDef; -- sprite multicolor 0
	signal MM1 : ColorDef; -- sprite multicolor 1
	signal spriteColors: spriteColorsDef;

-- borders and blanking
	signal MainBorder: std_logic;
	signal TBBorder: std_logic;
	signal setTBBorder: boolean;
	signal hBlack: std_logic;
	signal vBlanking : std_logic;
	signal hBlanking : std_logic;
	signal xscroll: unsigned(2 downto 0);
	signal yscroll: unsigned(2 downto 0);
	signal rasterCmp : unsigned(8 downto 0);

-- Address generator
	signal vicAddrReg : unsigned(13 downto 0);
	signal vicAddrLoc : unsigned(13 downto 0);

-- Address counters
	signal ColCounter: unsigned(9 downto 0) := (others => '0'); -- VC
	signal ColRestart: unsigned(9 downto 0) := (others => '0'); -- VCBASE
	signal RowCounter: unsigned(2 downto 0) := (others => '0');

-- IRQ Registers
	signal IRST: std_logic := '0';
	signal ERST: std_logic := '0';
	signal IMBC: std_logic := '0';
	signal EMBC: std_logic := '0';
	signal IMMC: std_logic := '0';
	signal EMMC: std_logic := '0';
	signal ILP: std_logic := '0';
	signal ELP: std_logic := '0';
	signal IRQ: std_logic;

-- Collision detection registers
	signal collision : unsigned(7 downto 0);
	signal M2M: unsigned(7 downto 0); -- Sprite to sprite collision
	signal M2D: unsigned(7 downto 0); -- Sprite to character collision
	signal M2DDelay: unsigned(7 downto 0); -- Sprite to character collision
	signal M2Mhit : std_logic;
	signal M2Dhit : std_logic;
	signal M2MClr : std_logic; -- collision register clear flag

-- Raster counters
	signal rasterX : unsigned(9 downto 0) := (others => '0');
	signal rasterY : unsigned(8 downto 0) := (others => '0');
	signal rasterY_next : unsigned(8 downto 0);
	signal cycleLast : boolean;
	signal cycleLastDelay : boolean;
	signal rasterXDelay : unsigned(9 downto 0);

-- Light pen
	signal lightPenHit: std_logic;
	signal lpX : unsigned(7 downto 0);
	signal lpY : unsigned(7 downto 0);

-- IRQ Resets
	signal resetLightPenIrq: std_logic;
	signal resetIMMC : std_logic;
	signal resetIMBC : std_logic;
	signal resetRasterIrq : std_logic;

-- Character generation
	signal charStore: charStoreDef;
	signal nextChar : unsigned(11 downto 0);
	-- Char/Pixels pair waiting to be shifted
	signal waitingChar : unsigned(11 downto 0);
	signal waitingChar_r : unsigned(11 downto 0);
	signal waitingPixels : unsigned(7 downto 0);
	signal waitingPixels_r : unsigned(7 downto 0);
	-- Stores colorinfo and the Pixels that are currently in shift register
	signal shiftingChar : unsigned(11 downto 0);
	signal shiftingChar_d : unsigned(11 downto 0);
	signal shiftingPixels : unsigned(7 downto 0);
	signal currentPixels : unsigned(1 downto 0);
	signal currentPixels_d : unsigned(1 downto 0);
	signal shifting_ff : std_logic; -- Multicolor shift-regiter status bit.

-- Sprite work registers
	signal MPtr : unsigned(7 downto 0); -- sprite base pointer
	signal MPixels : MPixelsDef; -- Sprite 24 bit shift register
	signal MPixelStore : unsigned(15 downto 0); -- Store fetched sprite bytes until ready to load into the shift register
	signal MActive : MFlags; -- Sprite is active
	signal MActive_next : MFlags; -- Sprite is active combinatorial
	signal MDMA : MFlags; -- Sprite DMA is enabled
	signal MDMA_next : MFlags; -- Sprite DMA is enabled combinatorial
	signal MCnt : MCntDef;
	signal MCnt_next : MCntDef;
	signal MCBase : MCntDef;
	signal MCBase_next : MCntDef;
	signal MXE_ff : unsigned(7 downto 0); -- Sprite X expansion flipflop
	signal MYE_ff : unsigned(7 downto 0); -- Sprite Y expansion flipflop
	signal MYE_ff_next : unsigned(7 downto 0); -- Sprite Y expansion flipflop combinatorial
	signal MC_ff : unsigned(7 downto 0); -- controls sprite shift-register in multicolor
	signal MShift_stop : MFlags; -- Stop sprite shifting flag
	signal MCurrentPixel_r : MCurrentPixelDef;
	signal MCurrentPixel : MCurrentPixelDef;

-- Current colors and pixels
	signal pixelBgFlag: std_logic; -- For collision detection

-- Read/Write lines
	signal we_r : std_logic;
	signal rd_r : std_logic;
	signal addr_r: unsigned(5 downto 0);
	signal di_r: unsigned(7 downto 0);

	signal myWr_phi1 : std_logic;
	signal myWr_a : std_logic;
	signal myWr_b : std_logic;
	signal myWr_c : std_logic;
	signal myRd : std_logic;
	
	signal turbo_reg : std_logic;

	-- registers behind the output ports (read back for the savestate chain)
	signal do_r : unsigned(7 downto 0);
	signal colorIndex_r : unsigned(3 downto 0);
	signal vicRefresh_r : std_logic;
	signal MShift_r : MFlags;   -- the sprite shift flags, kept in a variable inside the process

-- Savestate chain: segment vector (bit 0 leaves first), field offsets in
-- savestate/map.yaml order
	constant O_WE_R : natural := 0;
	constant O_RD_R : natural := 1;
	constant O_ADDR_R : natural := 2;
	constant O_DI_R : natural := 8;
	constant O_BACNT : natural := 16;
	constant O_LASTLINEFLAG : natural := 19;
	constant O_VICCYCLE : natural := 20;
	constant O_SPRITE : natural := 24;
	constant O_VICADDRREG : natural := 27;
	constant O_NEXTCHAR : natural := 41;
	constant O_CHARSTORE : natural := 53;
	constant O_MPTR : natural := 521;
	constant O_VICREFRESH : natural := 529;
	constant O_REFRESHCOUNTER : natural := 530;
	constant O_RASTERENABLE : natural := 538;
	constant O_BACHARS : natural := 539;
	constant O_BASPRITE04 : natural := 540;
	constant O_BASPRITE15 : natural := 541;
	constant O_BASPRITE26 : natural := 542;
	constant O_BASPRITE37 : natural := 543;
	constant O_BASPRITELAST : natural := 544;
	constant O_COLCOUNTER : natural := 545;
	constant O_ROWCOUNTER : natural := 555;
	constant O_COLRESTART : natural := 558;
	constant O_IDLE : natural := 568;
	constant O_RASTERX : natural := 569;
	constant O_RASTERXDELAY : natural := 579;
	constant O_CYCLELASTDELAY : natural := 589;
	constant O_RASTERY : natural := 590;
	constant O_RASTERIRQDONE : natural := 599;
	constant O_IRST : natural := 600;
	constant O_ILP : natural := 601;
	constant O_LIGHTPENHIT : natural := 602;
	constant O_LPX : natural := 603;
	constant O_LPY : natural := 611;
	constant O_HBLACK : natural := 619;
	constant O_HBLANKING : natural := 620;
	constant O_MAINBORDER : natural := 621;
	constant O_TBBORDER : natural := 622;
	constant O_SETTBBORDER : natural := 623;
	constant O_SHIFTING_FF : natural := 624;
	constant O_WAITINGCHAR_R : natural := 625;
	constant O_WAITINGPIXELS_R : natural := 637;
	constant O_SHIFTINGCHAR : natural := 645;
	constant O_SHIFTINGPIXELS : natural := 657;
	constant O_CURRENTPIXELS : natural := 665;
	constant O_PIXELBGFLAG : natural := 667;
	constant O_CURRENTPIXELS_D : natural := 668;
	constant O_SHIFTINGCHAR_D : natural := 670;
	constant O_MCMDELAY : natural := 682;
	constant O_ECMDELAY : natural := 683;
	constant O_BMMDELAY : natural := 684;
	constant O_WAITINGPIXELS : natural := 685;
	constant O_WAITINGCHAR : natural := 693;
	constant O_MCBASE : natural := 705;
	constant O_MDMA : natural := 753;
	constant O_MYE_FF : natural := 761;
	constant O_MCNT : natural := 769;
	constant O_MACTIVE : natural := 817;
	constant O_MSHIFT : natural := 825;
	constant O_MSHIFT_STOP : natural := 833;
	constant O_MXE_FF : natural := 841;
	constant O_MC_FF : natural := 849;
	constant O_MCURRENTPIXEL_R : natural := 857;
	constant O_MPIXELS : natural := 873;
	constant O_MCURRENTPIXEL : natural := 1065;
	constant O_MC : natural := 1081;
	constant O_MCCOLORDELAY : natural := 1089;
	constant O_MCCOLOR : natural := 1097;
	constant O_MPIXELSTORE : natural := 1105;
	constant O_COLORINDEX : natural := 1121;
	constant O_M2MCLR : natural := 1125;
	constant O_IMMC : natural := 1126;
	constant O_COLLISION : natural := 1127;
	constant O_M2M : natural := 1135;
	constant O_M2MHIT : natural := 1143;
	constant O_IMBC : natural := 1144;
	constant O_M2DDELAY : natural := 1145;
	constant O_M2D : natural := 1153;
	constant O_M2DHIT : natural := 1161;
	constant O_RESETLIGHTPENIRQ : natural := 1162;
	constant O_RESETIMMC : natural := 1163;
	constant O_RESETIMBC : natural := 1164;
	constant O_RESETRASTERIRQ : natural := 1165;
	constant O_MX : natural := 1166;
	constant O_RASTERCMP : natural := 1238;
	constant O_ECM : natural := 1247;
	constant O_BMM : natural := 1248;
	constant O_DEN : natural := 1249;
	constant O_RSEL : natural := 1250;
	constant O_YSCROLL : natural := 1251;
	constant O_ME : natural := 1254;
	constant O_RES : natural := 1262;
	constant O_MCM : natural := 1263;
	constant O_CSEL : natural := 1264;
	constant O_XSCROLL : natural := 1265;
	constant O_MYE : natural := 1268;
	constant O_VM : natural := 1276;
	constant O_CB : natural := 1280;
	constant O_ELP : natural := 1283;
	constant O_EMMC : natural := 1284;
	constant O_EMBC : natural := 1285;
	constant O_ERST : natural := 1286;
	constant O_MPRIO : natural := 1287;
	constant O_MCDELAY : natural := 1295;
	constant O_MXE : natural := 1303;
	constant O_EC : natural := 1311;
	constant O_B0C : natural := 1315;
	constant O_B1C : natural := 1319;
	constant O_B2C : natural := 1323;
	constant O_B3C : natural := 1327;
	constant O_MM0 : natural := 1331;
	constant O_MM1 : natural := 1335;
	constant O_SPRITECOLORS : natural := 1339;
	constant O_TURBO_REG : natural := 1371;
	constant O_MY : natural := 1372;
	constant O_DO : natural := 1436;
	constant SS_BITS : natural := 1444;

	signal ss_q, ss_d : std_logic_vector(SS_BITS-1 downto 0);

	function b2s(b : boolean) return std_logic is
	begin
		if b then return '1'; else return '0'; end if;
	end function;
	function vcv(c : vicCycles) return std_logic_vector is
	begin
		return std_logic_vector(to_unsigned(vicCycles'pos(c), 4));
	end function;
	-- the two unused patterns only appear while the chain shifts (machine stopped)
	function vcd(v : std_logic_vector(3 downto 0)) return vicCycles is
		variable i : natural range 0 to 15;
	begin
		i := to_integer(unsigned(v));
		if i > vicCycles'pos(vicCycles'high) then i := 0; end if;
		return vicCycles'val(i);
	end function;

begin
-- -----------------------------------------------------------------------
-- Ouput signals
-- -----------------------------------------------------------------------
	ba <= baLoc;
	vicAddr <= vicAddrReg when registeredAddress else vicAddrLoc;
	hSync <= hBlanking;
	vSync <= vBlanking;
	rasterXpos <= rasterX;
	rasterYpos <= (others => '0') when cycleLastDelay else rasterY;
	irq_n <= not IRQ;
	turbo_state <= turbo_reg;
	do <= do_r;
	colorIndex <= colorIndex_r;
	vicRefresh <= vicRefresh_r;
	vicCycle <= vcd(vicCycle_v);

-- -----------------------------------------------------------------------
-- Savestate chain: pack the registers (unpacked in the process of each)
-- -----------------------------------------------------------------------
	ss_q(O_WE_R) <= we_r;
	ss_q(O_RD_R) <= rd_r;
	ss_q(O_ADDR_R+5 downto O_ADDR_R) <= std_logic_vector(addr_r);
	ss_q(O_DI_R+7 downto O_DI_R) <= std_logic_vector(di_r);
	ss_q(O_BACNT+2 downto O_BACNT) <= std_logic_vector(baCnt);
	ss_q(O_LASTLINEFLAG) <= b2s(lastLineFlag);
	ss_q(O_VICCYCLE+3 downto O_VICCYCLE) <= vicCycle_v;
	ss_q(O_SPRITE+2 downto O_SPRITE) <= std_logic_vector(sprite);
	ss_q(O_VICADDRREG+13 downto O_VICADDRREG) <= std_logic_vector(vicAddrReg);
	ss_q(O_NEXTCHAR+11 downto O_NEXTCHAR) <= std_logic_vector(nextChar);
	g_cs: for i in 0 to 38 generate
		ss_q(O_CHARSTORE+12*i+11 downto O_CHARSTORE+12*i) <= std_logic_vector(charStore(i));
	end generate;
	ss_q(O_MPTR+7 downto O_MPTR) <= std_logic_vector(MPtr);
	ss_q(O_VICREFRESH) <= vicRefresh_r;
	ss_q(O_REFRESHCOUNTER+7 downto O_REFRESHCOUNTER) <= std_logic_vector(refreshCounter);
	ss_q(O_RASTERENABLE) <= rasterEnable;
	ss_q(O_BACHARS) <= baChars;
	ss_q(O_BASPRITE04) <= baSprite04;
	ss_q(O_BASPRITE15) <= baSprite15;
	ss_q(O_BASPRITE26) <= baSprite26;
	ss_q(O_BASPRITE37) <= baSprite37;
	ss_q(O_BASPRITELAST) <= baSpriteLast;
	ss_q(O_COLCOUNTER+9 downto O_COLCOUNTER) <= std_logic_vector(colCounter);
	ss_q(O_ROWCOUNTER+2 downto O_ROWCOUNTER) <= std_logic_vector(rowCounter);
	ss_q(O_COLRESTART+9 downto O_COLRESTART) <= std_logic_vector(colRestart);
	ss_q(O_IDLE) <= idle;
	ss_q(O_RASTERX+9 downto O_RASTERX) <= std_logic_vector(rasterX);
	ss_q(O_RASTERXDELAY+9 downto O_RASTERXDELAY) <= std_logic_vector(rasterXDelay);
	ss_q(O_CYCLELASTDELAY) <= b2s(cycleLastDelay);
	ss_q(O_RASTERY+8 downto O_RASTERY) <= std_logic_vector(rasterY);
	ss_q(O_RASTERIRQDONE) <= rasterIrqDone;
	ss_q(O_IRST) <= IRST;
	ss_q(O_ILP) <= ILP;
	ss_q(O_LIGHTPENHIT) <= lightPenHit;
	ss_q(O_LPX+7 downto O_LPX) <= std_logic_vector(lpX);
	ss_q(O_LPY+7 downto O_LPY) <= std_logic_vector(lpY);
	ss_q(O_HBLACK) <= hBlack;
	ss_q(O_HBLANKING) <= hBlanking;
	ss_q(O_MAINBORDER) <= MainBorder;
	ss_q(O_TBBORDER) <= TBBorder;
	ss_q(O_SETTBBORDER) <= b2s(setTBBorder);
	ss_q(O_SHIFTING_FF) <= shifting_ff;
	ss_q(O_WAITINGCHAR_R+11 downto O_WAITINGCHAR_R) <= std_logic_vector(waitingChar_r);
	ss_q(O_WAITINGPIXELS_R+7 downto O_WAITINGPIXELS_R) <= std_logic_vector(waitingPixels_r);
	ss_q(O_SHIFTINGCHAR+11 downto O_SHIFTINGCHAR) <= std_logic_vector(shiftingChar);
	ss_q(O_SHIFTINGPIXELS+7 downto O_SHIFTINGPIXELS) <= std_logic_vector(shiftingPixels);
	ss_q(O_CURRENTPIXELS+1 downto O_CURRENTPIXELS) <= std_logic_vector(currentPixels);
	ss_q(O_PIXELBGFLAG) <= pixelBgFlag;
	ss_q(O_CURRENTPIXELS_D+1 downto O_CURRENTPIXELS_D) <= std_logic_vector(currentPixels_d);
	ss_q(O_SHIFTINGCHAR_D+11 downto O_SHIFTINGCHAR_D) <= std_logic_vector(shiftingChar_d);
	ss_q(O_MCMDELAY) <= MCMDelay;
	ss_q(O_ECMDELAY) <= ECMDelay;
	ss_q(O_BMMDELAY) <= BMMDelay;
	ss_q(O_WAITINGPIXELS+7 downto O_WAITINGPIXELS) <= std_logic_vector(waitingPixels);
	ss_q(O_WAITINGCHAR+11 downto O_WAITINGCHAR) <= std_logic_vector(waitingChar);
	g_spr: for i in 0 to 7 generate
		ss_q(O_MCBASE+6*i+5 downto O_MCBASE+6*i) <= std_logic_vector(MCBase(i));
		ss_q(O_MDMA+i) <= b2s(MDMA(i));
		ss_q(O_MCNT+6*i+5 downto O_MCNT+6*i) <= std_logic_vector(MCnt(i));
		ss_q(O_MACTIVE+i) <= b2s(MActive(i));
		ss_q(O_MSHIFT+i) <= b2s(MShift_r(i));
		ss_q(O_MSHIFT_STOP+i) <= b2s(MShift_stop(i));
		ss_q(O_MCURRENTPIXEL_R+2*i+1 downto O_MCURRENTPIXEL_R+2*i) <= std_logic_vector(MCurrentPixel_r(i));
		ss_q(O_MPIXELS+24*i+23 downto O_MPIXELS+24*i) <= std_logic_vector(MPixels(i));
		ss_q(O_MCURRENTPIXEL+2*i+1 downto O_MCURRENTPIXEL+2*i) <= std_logic_vector(MCurrentPixel(i));
		ss_q(O_MX+9*i+8 downto O_MX+9*i) <= std_logic_vector(MX(i));
		ss_q(O_MY+8*i+7 downto O_MY+8*i) <= std_logic_vector(MY(i));
		ss_q(O_SPRITECOLORS+4*i+3 downto O_SPRITECOLORS+4*i) <= std_logic_vector(spriteColors(i));
	end generate;
	ss_q(O_MYE_FF+7 downto O_MYE_FF) <= std_logic_vector(MYE_ff);
	ss_q(O_MXE_FF+7 downto O_MXE_FF) <= std_logic_vector(MXE_ff);
	ss_q(O_MC_FF+7 downto O_MC_FF) <= std_logic_vector(MC_ff);
	ss_q(O_MC+7 downto O_MC) <= std_logic_vector(MC);
	ss_q(O_MCCOLORDELAY+7 downto O_MCCOLORDELAY) <= std_logic_vector(MCColorDelay);
	ss_q(O_MCCOLOR+7 downto O_MCCOLOR) <= std_logic_vector(MCColor);
	ss_q(O_MPIXELSTORE+15 downto O_MPIXELSTORE) <= std_logic_vector(MPixelStore);
	ss_q(O_COLORINDEX+3 downto O_COLORINDEX) <= std_logic_vector(colorIndex_r);
	ss_q(O_M2MCLR) <= M2MClr;
	ss_q(O_IMMC) <= IMMC;
	ss_q(O_COLLISION+7 downto O_COLLISION) <= std_logic_vector(collision);
	ss_q(O_M2M+7 downto O_M2M) <= std_logic_vector(M2M);
	ss_q(O_M2MHIT) <= M2Mhit;
	ss_q(O_IMBC) <= IMBC;
	ss_q(O_M2DDELAY+7 downto O_M2DDELAY) <= std_logic_vector(M2DDelay);
	ss_q(O_M2D+7 downto O_M2D) <= std_logic_vector(M2D);
	ss_q(O_M2DHIT) <= M2Dhit;
	ss_q(O_RESETLIGHTPENIRQ) <= resetLightPenIrq;
	ss_q(O_RESETIMMC) <= resetIMMC;
	ss_q(O_RESETIMBC) <= resetIMBC;
	ss_q(O_RESETRASTERIRQ) <= resetRasterIrq;
	ss_q(O_RASTERCMP+8 downto O_RASTERCMP) <= std_logic_vector(rasterCmp);
	ss_q(O_ECM) <= ECM;
	ss_q(O_BMM) <= BMM;
	ss_q(O_DEN) <= DEN;
	ss_q(O_RSEL) <= RSEL;
	ss_q(O_YSCROLL+2 downto O_YSCROLL) <= std_logic_vector(yscroll);
	ss_q(O_ME+7 downto O_ME) <= std_logic_vector(ME);
	ss_q(O_RES) <= RES;
	ss_q(O_MCM) <= MCM;
	ss_q(O_CSEL) <= CSEL;
	ss_q(O_XSCROLL+2 downto O_XSCROLL) <= std_logic_vector(xscroll);
	ss_q(O_MYE+7 downto O_MYE) <= std_logic_vector(MYE);
	ss_q(O_VM+3 downto O_VM) <= std_logic_vector(VM);
	ss_q(O_CB+2 downto O_CB) <= std_logic_vector(CB);
	ss_q(O_ELP) <= ELP;
	ss_q(O_EMMC) <= EMMC;
	ss_q(O_EMBC) <= EMBC;
	ss_q(O_ERST) <= ERST;
	ss_q(O_MPRIO+7 downto O_MPRIO) <= std_logic_vector(MPRIO);
	ss_q(O_MCDELAY+7 downto O_MCDELAY) <= std_logic_vector(MCDelay);
	ss_q(O_MXE+7 downto O_MXE) <= std_logic_vector(MXE);
	ss_q(O_EC+3 downto O_EC) <= std_logic_vector(EC);
	ss_q(O_B0C+3 downto O_B0C) <= std_logic_vector(B0C);
	ss_q(O_B1C+3 downto O_B1C) <= std_logic_vector(B1C);
	ss_q(O_B2C+3 downto O_B2C) <= std_logic_vector(B2C);
	ss_q(O_B3C+3 downto O_B3C) <= std_logic_vector(B3C);
	ss_q(O_MM0+3 downto O_MM0) <= std_logic_vector(MM0);
	ss_q(O_MM1+3 downto O_MM1) <= std_logic_vector(MM1);
	ss_q(O_TURBO_REG) <= turbo_reg;
	ss_q(O_DO+7 downto O_DO) <= std_logic_vector(do_r);

	ss_d  <= ss_si & ss_q(SS_BITS-1 downto 1);
	ss_so <= ss_q(0);

-- -----------------------------------------------------------------------
-- chip-select signals and data/address bus latch
-- -----------------------------------------------------------------------
	process(clk)
	begin
		if rising_edge(clk) then
			if phi = '1' then
				we_r <= cs and we;
				rd_r <= cs and not we;
				addr_r <= aRegisters;
				di_r <= diRegisters;
			end if;
			if ss_en = '1' then
				we_r <= ss_d(O_WE_R);
				rd_r <= ss_d(O_RD_R);
				addr_r <= unsigned(ss_d(O_ADDR_R+5 downto O_ADDR_R));
				di_r <= unsigned(ss_d(O_DI_R+7 downto O_DI_R));
			end if;
		end if;
	end process;

	myWr_phi1 <= cs and phi and we;
	myWr_a <= '1' when we_r = '1' and enaPixel = '1' and rasterX(2 downto 0) = "011" else '0';
	myWr_b <= '1' when we_r = '1' and enaPixel = '1' and rasterX(2 downto 0) = "100" else '0';
	myWr_c <= '1' when we_r = '1' and enaPixel = '1' and rasterX(2 downto 0) = "101" else '0';
	-- timing of the read is only important for the collision register reads
	myRd   <= '1' when cs = '1' and phi = '1' and we = '0' and enaPixel = '1' and rasterX(1 downto 0) = "01" else '0';

-- -----------------------------------------------------------------------
-- debug signals
-- -----------------------------------------------------------------------
	debugX <= rasterXDelay;
	debugY <= rasterY;

-- -----------------------------------------------------------------------
-- Badline condition
-- -----------------------------------------------------------------------
	process(rasterY, yscroll, rasterEnable)
	begin
		badLine <= false;
		if (rasterY(2 downto 0) = yscroll)
		and (rasterEnable = '1') then
			badLine <= true;
		end if;
	end process;

-- -----------------------------------------------------------------------
-- BA=low counter
-- -----------------------------------------------------------------------
	process(clk)
	begin
		if rising_edge(clk) then
			if ss_hold = '0' then
				if baLoc = '0' then
					if phi = '0'
					and enaData = '1'
					and baCnt(2) = '0' then
						baCnt <= baCnt + 1;
					end if;
				else
					baCnt <= (others => '0');
				end if;
			end if;
			if ss_en = '1' then
				baCnt <= unsigned(ss_d(O_BACNT+2 downto O_BACNT));
			end if;
		end if;
	end process;

-- -----------------------------------------------------------------------
-- Calculate lastLineFlag
-- -----------------------------------------------------------------------
	process(clk)
		variable rasterLines : integer range 0 to 312;
	begin
		if rising_edge(clk) then
			if ss_hold = '0' then
				lastLineFlag <= false;

				rasterLines := 311; -- PAL
				if mode6567old = '1' then
					rasterLines := 261; -- NTSC (R7 and earlier have 262 lines)
				end if;
				if mode6567R8 = '1' then
					rasterLines := 262; -- NTSC (R8 and newer have 263 lines)
				end if;
				if rasterY = rasterLines then
					lastLineFlag <= true;
				end if;
			end if;
			if ss_en = '1' then
				lastLineFlag <= ss_d(O_LASTLINEFLAG) = '1';
			end if;
		end if;
	end process;

-- -----------------------------------------------------------------------
-- State machine
-- -----------------------------------------------------------------------
vicStateMachine: process(clk)
	begin
		if rising_edge(clk) then
			if enaData = '1'
			and baSync = '0' then
				if phi = '0' then
					case vicCycle is
					when cycleRefresh1 => vicCycle_v <= vcv(cycleRefresh2);
					when cycleRefresh2 => vicCycle_v <= vcv(cycleRefresh3);
					when cycleRefresh3 => vicCycle_v <= vcv(cycleRefresh4);  -- X=0..7 on this cycle
					when cycleRefresh4 => vicCycle_v <= vcv(cycleRefresh5);
					when cycleRefresh5 => vicCycle_v <= vcv(cycleChar);
					when cycleChar =>
						if rasterX(9 downto 3) = "0101000" then
							if mode6569 = '1' or mode6572 = '1' then -- PAL/PAL-N
							vicCycle_v <= vcv(cycleCalcSprites);
						end if;
							if mode6567R8  = '1' or mode6567old = '1' then -- New/Old NTSC
								vicCycle_v <= vcv(cycleIdle1);
							end if;
						end if;
					when cycleIdle1 =>
						if mode6567R8  = '1' then
							vicCycle_v <= vcv(cycleIdle2); -- New NTSC - 2 extra idle cycles (65 cycles/line)
						else
							vicCycle_v <= vcv(cycleCalcSprites); -- Old NTSC - 1 extra idle cycle (64 cycles/line)
						end if;
					when cycleIdle2 => vicCycle_v <= vcv(cycleCalcSprites);
					when cycleCalcSprites => vicCycle_v <= vcv(cycleSpriteBa1);
					when cycleSpriteBa1   => vicCycle_v <= vcv(cycleSpriteBa2);
					when cycleSpriteBa2   => vicCycle_v <= vcv(cycleSpriteBa3);
					when others =>
						null;
					end case;
				else
					case vicCycle is
					when cycleSpriteBa3 => vicCycle_v <= vcv(cycleSpriteA);
					when cycleSpriteA =>
						vicCycle_v <= vcv(cycleSpriteB);
					when cycleSpriteB =>
						vicCycle_v <= vcv(cycleSpriteA);
						if sprite = 7 then
							vicCycle_v <= vcv(cycleRefresh1);
						end if;
					when others =>
						null;
					end case;
				end if;
			end if;
			if ss_en = '1' then
				vicCycle_v <= ss_d(O_VICCYCLE+3 downto O_VICCYCLE);
			end if;
		end if;
	end process;

-- -----------------------------------------------------------------------
-- Iterate through all sprites.
-- Only used when state-machine above is in any sprite cycles.
-- -----------------------------------------------------------------------
	process(clk)
	begin
		if rising_edge(clk) then
			if phi = '1'
			and enaData = '1'
			and vicCycle = cycleSpriteB
			and baSync = '0' then
				sprite <= sprite + 1;
			end if;
			if ss_en = '1' then
				sprite <= unsigned(ss_d(O_SPRITE+2 downto O_SPRITE));
			end if;
		end if;
	end process;

-- -----------------------------------------------------------------------
-- Address generator
-- -----------------------------------------------------------------------
	process(phi, vicCycle, sprite, shiftChars, idle,
			VM, CB, ECM, BMM, nextChar, colCounter, rowCounter, MPtr, MCnt,
			MDMA_next, refreshCounter)
	begin
		--
		-- Default case ($3FFF fetches)
		vicAddrLoc <= (others => '1');
		if (idle = '0')
		and shiftChars then
			if BMM = '1' then
				vicAddrLoc <= CB(13) & colCounter & rowCounter;
			else
				vicAddrLoc <= CB & nextChar(7 downto 0) & rowCounter;
			end if;
		end if;

		case vicCycle is
		when cycleRefresh1 | cycleRefresh2 | cycleRefresh3 | cycleRefresh4 | cycleRefresh5 =>
			if emulateRefresh then
				vicAddrLoc <= "111111" & refreshCounter;
			else
				vicAddrLoc <= (others => '-');
			end if;
		when cycleSpriteBa1 | cycleSpriteBa2 | cycleSpriteBa3 =>
			vicAddrLoc <= (others => '1');
		when cycleSpriteA =>
			if phi = '1' then
				if MDMA_Next(to_integer(sprite)) then
					vicAddrLoc <= MPtr & MCnt(to_integer(sprite));
				end if;
			else
				vicAddrLoc <= VM & "1111111" & sprite;
			end if;
		when cycleSpriteB =>
			if MDMA_Next(to_integer(sprite)) then
				vicAddrLoc <= MPtr & MCnt(to_integer(sprite));
			end if;
		when others =>
			if ECM = '1' then
				vicAddrLoc(10 downto 9) <= "00";
			end if;
			if phi = '1' then
				vicAddrLoc <= VM & colCounter;
			end if;
		end case;
	end process;

	-- Registered address
	process(clk)
	begin
		if rising_edge(clk) then
			if ss_hold = '0' then
				vicAddrReg <= vicAddrLoc;
			end if;
			if ss_en = '1' then
				vicAddrReg <= unsigned(ss_d(O_VICADDRREG+13 downto O_VICADDRREG));
			end if;
		end if;
	end process;

-- -----------------------------------------------------------------------
-- Character storage
-- -----------------------------------------------------------------------
	process(clk)
	begin
		if rising_edge(clk) then
			if enaData = '1'
			and shiftChars
			and phi = '1' then
				if baChars = '0' then
					nextChar(7 downto 0) <= di;
					nextChar(11 downto 8) <= diColor;
				else
					nextChar <= charStore(38);
				end if;
				charStore <= charStore(37 downto 0) & nextChar;
			end if;
			if ss_en = '1' then
				nextChar <= unsigned(ss_d(O_NEXTCHAR+11 downto O_NEXTCHAR));
				for i in 0 to 38 loop
					charStore(i) <= unsigned(ss_d(O_CHARSTORE+12*i+11 downto O_CHARSTORE+12*i));
				end loop;
			end if;
		end if;
	end process;

-- -----------------------------------------------------------------------
-- Sprite base pointer (MPtr)
-- -----------------------------------------------------------------------
	process(clk)
	begin
		if rising_edge(clk) then
			if phi = '0'
			and enaData = '1'
			and vicCycle = cycleSpriteA then
				MPtr <= (others => '1');
				if MActive_next(to_integer(sprite)) then
					MPtr <= di;
				end if;

				-- If refresh counter is not emulated we don't care about
				-- MPtr having the correct value in idle state.
				if not emulateRefresh then
					MPtr <= di;
				end if;
			end if;
			if ss_en = '1' then
				MPtr <= unsigned(ss_d(O_MPTR+7 downto O_MPTR));
			end if;
		end if;
	end process;

-- -----------------------------------------------------------------------
-- Refresh counter
-- -----------------------------------------------------------------------
	process(clk)
	begin
		if rising_edge(clk) then
			if ss_hold = '0' then
				vicRefresh_r <= '0';
				case vicCycle is
				when cycleRefresh1 | cycleRefresh2 | cycleRefresh3 | cycleRefresh4 | cycleRefresh5 =>
					vicRefresh_r <= '1';
					if phi = '0'
					and enaData = '1'
					and baSync = '0' then
						refreshCounter <= refreshCounter - 1;
					end if;
				when others =>
					null;
				end case;
				if lastLineFlag then
					refreshCounter <= (others => '1');
				end if;
			end if;
			if ss_en = '1' then
				vicRefresh_r <= ss_d(O_VICREFRESH);
				refreshCounter <= unsigned(ss_d(O_REFRESHCOUNTER+7 downto O_REFRESHCOUNTER));
			end if;
		end if;
	end process;

-- -----------------------------------------------------------------------
-- Generate Raster Enable
-- -----------------------------------------------------------------------
	process(clk)
	begin
		-- Enable screen and character display.
		-- This is only possible in line 48 on the VIC-II.
		-- On other lines any DEN changes are ignored.
		if rising_edge(clk) then
			if ss_hold = '0' then
				if (rasterY = 48) and (DEN = '1') then
					rasterEnable <= '1';
				end if;
				if (rasterY = 248) then
					rasterEnable <= '0';
				end if;
			end if;
			if ss_en = '1' then
				rasterEnable <= ss_d(O_RASTERENABLE);
			end if;
		end if;
	end process;


-- -----------------------------------------------------------------------
-- BA generator (Text/Bitmap)
-- -----------------------------------------------------------------------
--
-- For Text/Bitmap BA goes low 3 cycles before real access. So BA starts
-- going low during refresh2 state. See diagram below for timing:
--
-- X               0  0  0  0  0
--                 0  0  0  0  1
--                 0  4  8  C  0
--
-- phi ___   ___   ___   ___   ___   ___   ___   ___...
--        ___   ___   ___   ___   ___   ___   ___   ...
--
--          |     |     |     |     |     |     |...
--     rfr2  rfr3  rfr4  rfr5  char1 char2 char3
--
-- BA _______
--        \\\_______________________________________
--          |  1  |  2  |  3  |
--
-- BACnt 000  001 | 010 | 011 | 100   100   100  ...
--
-- -----------------------------------------------------------------------
	process(clk)
	begin
		if rising_edge(clk) then
			if phi = '0' and ss_hold = '0' then
				baChars <= '1';
				case vicCycle is
				when cycleRefresh2 | cycleRefresh3 | cycleRefresh4 | cycleRefresh5 =>
					if badLine then
						baChars <= '0';
					end if;
				when others =>
					if rasterX(9 downto 3) < "0101001"
					and badLine then
						baChars <= '0';
					end if;
				end case;
			end if;
			if ss_en = '1' then
				baChars <= ss_d(O_BACHARS);
			end if;
		end if;
	end process;

-- -----------------------------------------------------------------------
-- BA generator (Sprites)
-- -----------------------------------------------------------------------
	process(clk)
	begin
		if rising_edge(clk) then
			if phi = '0' and ss_hold = '0' then
				if sprite = 1 then
					baSprite04 <= '1';
				end if;
				if sprite = 2 then
					baSprite15 <= '1';
				end if;
				if sprite = 3 then
					baSprite26 <= '1';
				end if;
				if sprite = 4 then
					baSprite37 <= '1';
				end if;
				if sprite = 5 then
					baSprite04 <= '1';
				end if;
				if sprite = 6 then
					baSprite15 <= '1';
				end if;
				if sprite = 7 then
					baSprite26 <= '1';
				end if;
				if vicCycle = cycleRefresh1 then
					baSprite37 <= '1';
					baSpriteLast <= baSpriteLast and baSprite37;
				end if;
				if vicCycle = cycleRefresh3 then
					baSprite37 <= '1';
					baSpriteLast <= '1';
				end if;

				if MDMA_next(0) and (vicCycle = cycleCalcSprites) then
					baSprite04 <= '0';
				end if;
				if MDMA(1) and (vicCycle = cycleSpriteBa2) then
					baSprite15 <= '0';
				end if;
				if MDMA(2) and (vicCycle = cycleSpriteB) and (sprite = 0) then
					baSprite26 <= '0';
				end if;
				if MDMA(3) and (vicCycle = cycleSpriteB) and (sprite = 1) then
					baSprite37 <= '0';
				end if;
				if MDMA(4) and (vicCycle = cycleSpriteB) and (sprite = 2) then
					baSprite04 <= '0';
				end if;
				if MDMA(5) and (vicCycle = cycleSpriteB) and (sprite = 3) then
					baSprite15 <= '0';
				end if;
				if MDMA(6) and (vicCycle = cycleSpriteB) and (sprite = 4) then
					baSprite26 <= '0';
				end if;
				if MDMA(7) and (vicCycle = cycleSpriteB) and (sprite = 5) then
					baSprite37 <= '0';
				end if;
			end if;
			if ss_en = '1' then
				baSprite04   <= ss_d(O_BASPRITE04);
				baSprite15   <= ss_d(O_BASPRITE15);
				baSprite26   <= ss_d(O_BASPRITE26);
				baSprite37   <= ss_d(O_BASPRITE37);
				baSpriteLast <= ss_d(O_BASPRITELAST);
			end if;
		end if;
	end process;
	baLoc <= baChars and baSprite04 and baSprite15 and baSprite26 and baSprite37;
	ba_dma <= '1' when (baSpriteLast = '0' or vicCycle = cycleRefresh3) and badLine else '0';

-- -----------------------------------------------------------------------
-- Address valid?
-- -----------------------------------------------------------------------
	process(phi, baCnt)
	begin
		addrValid <= '0';
		if phi = '0'
		or baCnt(2) = '1' then
			addrValid <= '1';
		end if;
	end process;

-- -----------------------------------------------------------------------
-- Generate ShiftChars and ShiftLoadEna flags
-- -----------------------------------------------------------------------
	process(rasterX, rasterXDelay)
	begin
		shiftChars <= false;
		if rasterX(9 downto 3) > "0000001"
		and rasterX(9 downto 3) <= "0101001" then
			shiftChars <= true;
		end if;
		shiftLoadEna <= false;
		if rasterXDelay(9 downto 3) > "0000001"
		and rasterXDelay(9 downto 3) <= "0101010" then
			shiftLoadEna <= true;
		end if;

	end process;

-- -----------------------------------------------------------------------
-- RowCounter and ColCounter
-- -----------------------------------------------------------------------
	process(clk)
	begin
		if rising_edge(clk) then
			if phi = '0'
			and enaData = '1'
			and baSync = '0' then
				-- 4. VC and VMLI are incremented after each g-access in display state.
				if shiftChars
				and idle = '0' then
					colCounter <= colCounter + 1;
				end if;

				case vicCycle is
				when cycleRefresh4 =>
					-- 2. In the first phase of cycle 14 of each line, VC is loaded from VCBASE
					-- (VCBASE->VC) and VMLI is cleared. If there is a Bad Line Condition in
					-- this phase, RC is also reset to zero.
					colCounter <= colRestart;
					if badline then
						rowCounter <= (others => '0');
					end if;
				when cycleSpriteA =>
					-- 5. In the first phase of cycle 58, the VIC checks if RC=7. If so, the video
					-- logic goes to idle state and VCBASE is loaded from VC (VC->VCBASE). If
					-- the video logic is in display state afterwards (this is always the case
					-- if there is a Bad Line Condition), RC is incremented.
					if sprite = "000" then
						if rowCounter = 7 then
							colRestart <= colCounter;
							idle <= '1';
						else
							rowCounter <= rowCounter + 1;
						end if;
						if badline then
							rowCounter <= rowCounter + 1;
						end if;
					end if;
				when others =>
					null;					
				end case;
				if lastLineFlag then
					-- 1. Once somewhere outside of the range of raster lines $30-$f7 (i.e.
					-- outside of the Bad Line range), VCBASE is reset to zero. This is
					-- presumably done in raster line 0, the exact moment cannot be determined
					-- and is irrelevant.
					colRestart <= (others => '0');
				end if;

				-- Set display mode (leave idle-mode) as soon as
				-- there is a badline condition.
				if badline then
					idle <= '0';
				end if;
			end if;
			if ss_en = '1' then
				colCounter <= unsigned(ss_d(O_COLCOUNTER+9 downto O_COLCOUNTER));
				rowCounter <= unsigned(ss_d(O_ROWCOUNTER+2 downto O_ROWCOUNTER));
				colRestart <= unsigned(ss_d(O_COLRESTART+9 downto O_COLRESTART));
				idle       <= ss_d(O_IDLE);
			end if;
		end if;
	end process;

-- -----------------------------------------------------------------------
-- X/Y Raster counter
-- -----------------------------------------------------------------------
cycleLast <= (vicCycle = cycleSpriteB) and (sprite = 2);
rasterY_next <= (others => '0') when lastLineFlag else RasterY + 1;

rasterCounters: process(clk, rasterX, rasterXDelay)
	begin
		if rising_edge(clk) then
			if enaPixel = '1' then
				rasterX(2 downto 0) <= rasterX(2 downto 0) + 1;
				rasterXDelay <= rasterXDelay + 1;
				if rasterX = PIX_DELAY - 1 then
					rasterXDelay <= (others => '0');
				end if;
			end if;
			if phi = '0'
			and enaData = '1'
			and baSync = '0' then
				rasterX(9 downto 3) <= rasterX(9 downto 3) + 1;
				rasterX(2 downto 0) <= (others => '0');
				if vicCycle = cycleRefresh3 then
					rasterX <= (others => '0');
				end if;
			end if;
			if phi = '1'
			and enaData = '1'
			and baSync = '0' then
				cycleLastDelay <= false;
				if (lastLineFlag) then cycleLastDelay <= cycleLast; end if;
				if (lastLineFlag and cycleLastDelay) or (not lastLineFlag and cycleLast) then
					rasterY <= rasterY_next;
				end if;
			end if;
			if ss_en = '1' then
				rasterX        <= unsigned(ss_d(O_RASTERX+9 downto O_RASTERX));
				rasterXDelay   <= unsigned(ss_d(O_RASTERXDELAY+9 downto O_RASTERXDELAY));
				cycleLastDelay <= ss_d(O_CYCLELASTDELAY) = '1';
				rasterY        <= unsigned(ss_d(O_RASTERY+8 downto O_RASTERY));
			end if;
		end if;
	end process;

-- -----------------------------------------------------------------------
-- Raster IRQ
-- -----------------------------------------------------------------------
	process(clk)
	begin
		if rising_edge(clk) then
			if ss_hold = '0' then
				if phi = '1'
				and enaData = '1'
				and baSync = '0'
				and ((lastLineFlag and cycleLastDelay) or (not lastLineFlag and cycleLast)) then
					rasterIrqDone <= '0';
				end if;
				if resetRasterIrq = '1' then
					IRST <= '0';
				end if;
				if (rasterIrqDone = '0')
				and (rasterY = rasterCmp) then
					rasterIrqDone <= '1';
					IRST <= '1';
				end if;
			end if;
			if ss_en = '1' then
				rasterIrqDone <= ss_d(O_RASTERIRQDONE);
				IRST          <= ss_d(O_IRST);
			end if;
		end if;
	end process;


-- -----------------------------------------------------------------------
-- Light pen
-- -----------------------------------------------------------------------
-- On a negative edge on the LP input, the current position of the raster beam
-- is latched in the registers LPX ($d013) and LPY ($d014). LPX contains the
-- upper 8 bits (of 9) of the X position and LPY the lower 8 bits (likewise of
-- 9) of the Y position. So the horizontal resolution of the light pen is
-- limited to 2 pixels.

-- Only one negative edge on LP is recognized per frame. If multiple edges
-- occur on LP, all following ones are ignored. The trigger is not released
-- until the next vertical blanking interval.
-- -----------------------------------------------------------------------
lightPen: process(clk)
	begin
		if rising_edge(clk) then
			if ss_hold = '0' then
				if emulateLightpen then
					if resetLightPenIrq = '1' then
						-- Reset light pen interrupt
						ILP <= '0';
					end if;
					if lastLineFlag then
						-- Reset lightpen state at beginning of frame
						lightPenHit <= '0';
					elsif (lightPenHit = '0') and (lp_n = '0') then
						-- One hit/frame
						lightPenHit <= '1';
						-- Toggle Interrupt
						ILP <= '1';
						-- Store position of beam
						lpx <= rasterX(8 downto 1);
						lpy <= rasterY(7 downto 0);
					end if;
				else
					ILP <= '0';
					lpx <= (others => '1');
					lpy <= (others => '1');
				end if;
			end if;
			if ss_en = '1' then
				ILP         <= ss_d(O_ILP);
				lightPenHit <= ss_d(O_LIGHTPENHIT);
				lpx         <= unsigned(ss_d(O_LPX+7 downto O_LPX));
				lpy         <= unsigned(ss_d(O_LPY+7 downto O_LPY));
			end if;
		end if;
	end process;

-- -----------------------------------------------------------------------
-- VSync
-- -----------------------------------------------------------------------
doVBlanking: process(clk, mode6569, mode6567old, mode6567R8)
		variable rasterBlank : integer range 0 to 300;
	begin
		rasterBlank := 300;
		if (mode6567old or mode6567R8) = '1' then
			rasterBlank := 12;
		end if;
		-- rebuilt, not on the chain: (rasterY = rasterBlank), held with the machine
		if rising_edge(clk) then
			if ss_hold = '0' then
				vBlanking <= '0';
				if rasterY = rasterBlank then
					vBlanking <= '1';
				end if;
			end if;
		end if;
	end process;

-- -----------------------------------------------------------------------
-- HSync
-- -----------------------------------------------------------------------
doHBlanking: process(clk)
	begin
		if rising_edge(clk) then
			if enaPixel = '1' then
				if sprite = 2 then
					hBlack <= '1';
				end if;
				if vicCycle = cycleRefresh1 then
					hBlack <= '0';
				end if;
				if rasterX = 396 then -- from VIC II datasheet
					hBlanking <= '1';
				elsif rasterX = 496 then -- from VIC II datasheet
					hBlanking <= '0';
				end if;
			end if;
			if ss_en = '1' then
				hBlack    <= ss_d(O_HBLACK);
				hBlanking <= ss_d(O_HBLANKING);
			end if;
		end if;
	end process;

-- -----------------------------------------------------------------------
-- Borders
-- -----------------------------------------------------------------------
calcBorders: process(clk)
	variable newTBBorder: std_logic;
	begin
		if rising_edge(clk) then
			if enaPixel = '1' then
				newTBBorder := TBBorder;
				-- 1. If the X coordinate reaches the right comparison value, the main border
				--   flip flop is set (comparison values are from VIC II datasheet).
				if (rasterX = 339 + 3 and CSEL = '0') or (rasterX = 348 + 3 and CSEL = '1')  then
					MainBorder <= '1';
				end if;
				-- 2. If the Y coordinate reaches the bottom comparison value in cycle 63, the
				-- vertical border flip flop is set. FIX: compare during the whole line, but set at cycle 63
				-- 3. If the Y coordinate reaches the top comparison value in cycle 63 and the
				-- DEN bit in register $d011 is set, the vertical border flip flop is
				-- reset. FIX: compare during the whole line and act immediately
				if (rasterY = 247 and RSEL = '0') or (rasterY = 251 and RSEL = '1') then
					setTBBorder <= true;
				end if;
				if ((rasterY = 55 and RSEL = '0') or (rasterY = 51 and RSEL = '1')) and DEN = '1' then
					newTBBorder := '0';
				end if;
				if cycleLast then
					if setTBBorder then
						newTBBorder := '1';
						setTBBorder <= false;
					end if;
				end if;
				if (rasterX = 35 + 3 and CSEL = '0') or (rasterX = 28 + 3 and CSEL = '1') then
					-- 4. If the X coordinate reaches the left comparison value and the Y
					-- coordinate reaches the bottom one, the vertical border flip flop is set.
					-- FIX: act on the already triggered condition
					if setTBBorder then
						newTBBorder := '1';
						setTBBorder <= false;
					end if;
					-- 5. If the X coordinate reaches the left comparison value and the Y
					-- coordinate reaches the top one and the DEN bit in register $d011 is set,
					-- the vertical border flip flop is reset.
					if ((rasterY = 55 and RSEL = '0') or (rasterY = 51 and RSEL = '1')) and DEN = '1' then
						newTBBorder := '0';
					end if;
					-- 6. If the X coordinate reaches the left comparison value and the vertical
					-- border flip flop is not set, the main flip flop is reset.
					if newTBBorder = '0' and setTBBorder = false then
						MainBorder <= '0';
					end if;
				end if;
				TBBorder <= newTBBorder;
			end if;
			if ss_en = '1' then
				MainBorder  <= ss_d(O_MAINBORDER);
				TBBorder    <= ss_d(O_TBBORDER);
				setTBBorder <= ss_d(O_SETTBBORDER) = '1';
			end if;
		end if;
	end process;

-- -----------------------------------------------------------------------
-- Pixel generator for Text/Bitmap screen
-- -----------------------------------------------------------------------
calcBitmap: process(clk)
	variable multiColor : std_logic;
	begin
		if rising_edge(clk) then
			if enaPixel = '1' then
				--
				-- Toggle flipflop for multicolor 2-bits shift.
				shifting_ff <= not shifting_ff;

				--
				-- Multicolor mode is active with MCM, but for character
				-- mode it depends on bit3 of color ram too.
				multiColor := MCM and (BMM or ECM or shiftingChar(11));

				-- store the waiting values to be ready at the start of the delayed cell matrix,
				-- otherwise they'll be overwritten too soon
				if rasterXDelay(2 downto 0) = "111" then
					waitingChar_r <= waitingChar;
					waitingPixels_r <= waitingPixels;
				end if;
				
				--
				-- Reload shift register when xscroll=rasterX
				-- otherwise shift pixels
				if shiftLoadEna and xscroll = rasterXDelay(2 downto 0) then
					shifting_ff <= '0';
					shiftingChar <= waitingChar_r;
					shiftingPixels <= waitingPixels_r;
					currentPixels <= waitingPixels_r(7 downto 6);
				else
					shiftingPixels <= shiftingPixels(6 downto 0) & '0';
					if multiColor = '0' or shifting_ff = '1' then
						currentPixels <= shiftingPixels(6 downto 5);
					end if;
				end if;

				--
				-- Calculate if pixel is in foreground or background
				pixelBgFlag <= currentPixels(1);

				currentPixels_d <= currentPixels;
				shiftingChar_d <= shiftingChar;
				MCMDelay <= MCM;
				ECMDelay <= ECM;
				BMMDelay <= BMM;
			end if;

			--
			-- Store fetched pixels, until current pixels are displayed
			-- and shift-register is empty.
			if enaData = '1'
			and phi = '0' then
				-- Store the characters until shiftregister is empty
				waitingPixels <= (others => '0');
				if shiftChars then
					waitingPixels <= di;
					waitingChar <= (others => '0');
					if idle = '0' then
						waitingChar <= nextChar;
					end if;
				end if;
			end if;

			if ss_en = '1' then
				shifting_ff     <= ss_d(O_SHIFTING_FF);
				waitingChar_r   <= unsigned(ss_d(O_WAITINGCHAR_R+11 downto O_WAITINGCHAR_R));
				waitingPixels_r <= unsigned(ss_d(O_WAITINGPIXELS_R+7 downto O_WAITINGPIXELS_R));
				shiftingChar    <= unsigned(ss_d(O_SHIFTINGCHAR+11 downto O_SHIFTINGCHAR));
				shiftingPixels  <= unsigned(ss_d(O_SHIFTINGPIXELS+7 downto O_SHIFTINGPIXELS));
				currentPixels   <= unsigned(ss_d(O_CURRENTPIXELS+1 downto O_CURRENTPIXELS));
				pixelBgFlag     <= ss_d(O_PIXELBGFLAG);
				currentPixels_d <= unsigned(ss_d(O_CURRENTPIXELS_D+1 downto O_CURRENTPIXELS_D));
				shiftingChar_d  <= unsigned(ss_d(O_SHIFTINGCHAR_D+11 downto O_SHIFTINGCHAR_D));
				MCMDelay        <= ss_d(O_MCMDELAY);
				ECMDelay        <= ss_d(O_ECMDELAY);
				BMMDelay        <= ss_d(O_BMMDELAY);
				waitingPixels   <= unsigned(ss_d(O_WAITINGPIXELS+7 downto O_WAITINGPIXELS));
				waitingChar     <= unsigned(ss_d(O_WAITINGCHAR+11 downto O_WAITINGCHAR));
			end if;
		end if;
	end process;

-- -----------------------------------------------------------------------
-- Sprite byte counter
-- Y expansion flipflop
-- -----------------------------------------------------------------------

	process(rasterX, rasterY, MDMA, MCnt, MCBase, MCBase_next, MActive, MYE_ff, ME, MY, MYE, vicCycle, sprite)
	begin
		MCBase_next <= MCBase;
		MDMA_next <= MDMA;
		MYE_ff_next <= MYE_ff;
		MCnt_next <= MCnt;
		MActive_next <= MActive;

		-- 1. The expansion flip flip is set as long as the bit in MxYE in register
		-- $d017 corresponding to the sprite is cleared.
		for i in 0 to 7 loop
			if MYE(i) = '0' then
				MYE_ff_next(i) <= '1';
			end if;
		end loop;

		case vicCycle is

		when cycleChar =>
			-- 7. In the first phase of cycle 16, it is checked if the expansion flip flop
			-- is set. If so, MCBASE load from MC (MC->MCBASE), unless the CPU cleared
			-- the Y expansion bit in $d017 in the second phase of cycle 15, in which case
			-- MCBASE is set to X = (101010 & (MCBASE & MC)) | (010101 & (MCBASE | MC)).
			-- After the MCBASE update, the VIC checks if MCBASE is equal to 63 and turns
			-- off the DMA of the sprite if it is. (VIC Addendum)
			if rasterX(9 downto 3) = "0000010" then
				for i in 0 to 7 loop
					if MDMA(i) then
						if MYE_ff(i) = '1' then
							MCBase_next(i) <= MCnt(i);
						elsif MYE(i) = '0' then
							-- MYE just turned off
							MCBase_next(i) <= ("101010" and (MCBase(i) and MCnt(i))) or ("010101" and (MCBase(i) or MCnt(i)));
						end if;
						if MCBase_next(i) = 63 then
							MDMA_next(i) <= false;
						end if;
					end if;
				end loop;
			end if;

		when cycleCalcSprites | cycleSpriteBa1 =>
			-- 2. If the MxYE bit is set in the first phase of cycle 55, the expansion
			-- flip flop is inverted. FIX: VirtualC64 does it at cycle 56, FLI demos likes it
			for i in 0 to 7 loop
				if MYE(i) = '1' and vicCycle = cycleSpriteBa1 then
					MYE_ff_next(i) <= not MYE_ff(i);
				end if;
			end loop;
			-- 3. In the first phases of cycle 55 and 56, the VIC checks for every sprite
			-- if the corresponding MxE bit in register $d015 is set and the Y
			-- coordinate of the sprite (odd registers $d001-$d00f) match the lower 8
			-- bits of RASTER. If this is the case and the DMA for the sprite is still
			-- off, the DMA is switched on, MCBASE is cleared, and if the MxYE bit is
			-- set the expansion flip flip is reset.
			for i in 0 to 7 loop
				if not MDMA(i) and ME(i) = '1' and rasterY(7 downto 0) = MY(i) then
					MCBase_Next(i) <= (others => '0');
					MDMA_Next(i) <= true;
					if MYE(i) = '1' then
						if vicCycle = cycleCalcSprites then
							MYE_ff_Next(i) <= '1'; -- will inverted in the next cycle
						else
							MYE_ff_Next(i) <= '0';
						end if;
					end if;
				end if;
			end loop;

		when cycleSpriteA =>
			-- 4. In the first phase of cycle 58, the MC of every sprite is loaded from
			-- its belonging MCBASE (MCBASE->MC) and it is checked if the DMA for the
			-- sprite is turned on and the Y coordinate of the sprite matches the lower
			-- 8 bits of RASTER. If this is the case, the display of the sprite is
			-- turned on.
			-- VIC Addendum: the actual disabling of sprite display is likely handled
			-- during the first phase of cycle 58 (see rule 4).

			if sprite = "000" then
				for i in 0 to 7 loop
					MCnt_Next(i) <= MCBase(i);
					if MDMA(i) then
						if ME(i) = '1' and rasterY(7 downto 0) = MY(i) then
							MActive_Next(i) <= true;
						end if;
					else
						MActive_next(i) <= false;
					end if;
				end loop;
			end if;

		when others => null;
		end case;

	end process;

	process(clk)
	begin
		if rising_edge(clk) then

			if phi = '0'
			and enaData = '1' then
				MCBase <= MCBase_Next;
				MDMA <= MDMA_Next;
				MYE_ff <= MYE_ff_Next;
				MCnt <= MCnt_Next;
			end if;
			if phi = '1'
			and enaPixel = '1' then
				MActive <= MActive_Next;
			end if;

			-- 5. If the DMA for a sprite is turned on, three s-accesses are done in
			-- sequence in the corresponding cycles assigned to the sprite (see the
			-- diagrams in section 3.6.3.). The p-accesses are always done, even if the
			-- sprite is turned off. The read data of the first access is stored in the
			-- upper 8 bits of the shift register, that of the second one in the middle
			-- 8 bits and that of the third one in the lower 8 bits.
			-- MC is incremented by one after each s-access.
			if enaData = '1' then
				if (vicCycle = cycleSpriteA and phi = '1')
				or (vicCycle = cycleSpriteB) then
					if MDMA(to_integer(sprite)) then
						MCnt(to_integer(sprite)) <= MCnt(to_integer(sprite)) + 1;
					end if;
				end if;
			end if;
			if ss_en = '1' then
				MYE_ff <= unsigned(ss_d(O_MYE_FF+7 downto O_MYE_FF));
				for i in 0 to 7 loop
					MCBase(i)  <= unsigned(ss_d(O_MCBASE+6*i+5 downto O_MCBASE+6*i));
					MDMA(i)    <= ss_d(O_MDMA+i) = '1';
					MCnt(i)    <= unsigned(ss_d(O_MCNT+6*i+5 downto O_MCNT+6*i));
					MActive(i) <= ss_d(O_MACTIVE+i) = '1';
				end loop;
			end if;
		end if;
	end process;

-- -----------------------------------------------------------------------
-- Sprite pixel Shift register
-- -----------------------------------------------------------------------
	process(clk)
	variable MShift : MFlags; -- Sprite is shifting (kept in MShift_r between clocks)
	begin

		if rising_edge(clk) then
			if enaPixel = '1' then
				MShift := MShift_r;
				for i in 0 to 7 loop
					-- Enable sprites on the correct X position
					if MActive(i) and rasterXDelay = MX(i) then
						MShift(i) := true;
					end if;
					-- Stop shifting in the third s cycle
					MShift_stop(i) <= false;
					if sprite = i and phi = '1' and vicCycle = cycleSpriteB then
						MShift_stop(i) <= true;
					end if;
					if MShift_stop(i) then
						MShift(i) := false;
					end if;
				end loop;

				-- Shift one pixel of the sprite from the shift register.
				for i in 0 to 7 loop
					if MShift(i) then
						MXE_ff(i) <= (not MXE_ff(i)) and MXE(i);
						if MXE_ff(i) = '0' then
							MC_ff(i) <= (not MC_ff(i)) and MC(i);
							if MC_ff(i) = '0' then
								MCurrentPixel_r(i) <= MPixels(i)(23 downto 22);
								if MPixels(i) = 0 then
									MShift(i) := false;
								end if;
							end if;
							-- Don't shift in the s cycles (sprite0move.prg, demusinterruptus.prg)
							if not (sprite = i and ((vicCycle = cycleSpriteA and phi = '1') or vicCycle = cycleSpriteB)) then
								MPixels(i) <= MPixels(i)(22 downto 0) & '0';
							end if;
						end if;
					else
						MXE_ff(i) <= '0';
						MC_ff(i) <= '0';
						MCurrentPixel_r(i) <= "00";
					end if;
					MCurrentPixel(i) <= MCurrentPixel_r(i);
				end loop;

				-- Changing the MC register directly affects the MC flip-flop
				-- Also looks like the value used for color decoding is delayed to
				-- what's used for the shift register (ss-hires-mc.prg)
				for i in 0 to 7 loop
					MC(i) <= MCDelay(i);
					MCColorDelay(i) <= MC(i);
					MCColor(i) <= MCColorDelay(i);
					if MCDelay(i) /= MC(i) then
						MC_ff(i) <= MCDelay(i);
					end if;
				end loop;
				MShift_r <= MShift;
			end if;

			--
			-- Fill Sprite shift-register with new data (even if the sprite is not active)
			if enaData = '1' then
				case vicCycle is
				when cycleSpriteA =>
					if phi = '1' then
						MPixelStore(15 downto 8) <= di;
					end if;
				when cycleSpriteB =>
					if phi = '0' then
						MPixelStore(7 downto 0) <= di;
					else
						MPixels(to_integer(sprite)) <= MPixelStore & di;
					end if;
					when others => null;
				end case;
			end if;
			if ss_en = '1' then
				MXE_ff       <= unsigned(ss_d(O_MXE_FF+7 downto O_MXE_FF));
				MC_ff        <= unsigned(ss_d(O_MC_FF+7 downto O_MC_FF));
				MC           <= unsigned(ss_d(O_MC+7 downto O_MC));
				MCColorDelay <= unsigned(ss_d(O_MCCOLORDELAY+7 downto O_MCCOLORDELAY));
				MCColor      <= unsigned(ss_d(O_MCCOLOR+7 downto O_MCCOLOR));
				MPixelStore  <= unsigned(ss_d(O_MPIXELSTORE+15 downto O_MPIXELSTORE));
				for i in 0 to 7 loop
					MShift_r(i)        <= ss_d(O_MSHIFT+i) = '1';
					MShift_stop(i)     <= ss_d(O_MSHIFT_STOP+i) = '1';
					MCurrentPixel_r(i) <= unsigned(ss_d(O_MCURRENTPIXEL_R+2*i+1 downto O_MCURRENTPIXEL_R+2*i));
					MPixels(i)         <= unsigned(ss_d(O_MPIXELS+24*i+23 downto O_MPIXELS+24*i));
					MCurrentPixel(i)   <= unsigned(ss_d(O_MCURRENTPIXEL+2*i+1 downto O_MCURRENTPIXEL+2*i));
				end loop;
			end if;
		end if;
	end process;

-- -----------------------------------------------------------------------
-- Video output
-- -----------------------------------------------------------------------

	process(clk)
		variable pixelColor: ColorDef;
		variable multiColor : std_logic;
		variable myColor: unsigned(3 downto 0);
		variable muxSprite : unsigned(2 downto 0);
		variable muxColor : unsigned(1 downto 0);
		-- 00 = pixels
		-- 01 = MM0
		-- 10 = Sprite
		-- 11 = MM1
	begin
		if rising_edge(clk) then
			muxColor := "00";
			muxSprite := (others => '-');
			for i in 7 downto 0 loop
				if MCColor(i) = '1' then
					if MCurrentPixel(i) /= "00" then
						if (MPRIO(i) = '0') or (pixelBgFlag = '0') then
							muxColor := MCurrentPixel(i);
						else
							muxColor := "00";
						end if;
						muxSprite := to_unsigned(i, 3);
					end if;
				elsif MCurrentPixel(i)(1) = '1' then
					if (MPRIO(i) = '0') or (pixelBgFlag = '0') then
						muxColor := "10";
					else
						muxColor := "00";
					end if;
					muxSprite := to_unsigned(i, 3);
				end if;
			end loop;

			-- Multicolor mode is active with MCM, but for character
			-- mode it depends on bit3 of color ram too.
			multiColor := MCMDelay and (BMMDelay or ECMDelay or shiftingChar_d(11));

			--
			-- Calculate color of next pixel
			pixelColor := B0C;
			if (BMMDelay = '0') and (ECMDelay='0') then
				if (multiColor = '0') then
					-- normal character mode
					if currentPixels_d(1) = '1' then
						pixelColor := shiftingChar_d(11 downto 8);
					end if;
				else
					-- multi-color character mode
					case currentPixels_d is
					when "01" => pixelColor := B1C;
					when "10" => pixelColor := B2C;
					when "11" => pixelColor := '0' & shiftingChar_d(10 downto 8);
					when others => null;
					end case;
				end if;
			elsif (MCMDelay = '0') and (BMMDelay = '0') and (ECMDelay = '1') then
				-- extended-color character mode
				-- multiple background colors but only 64 characters
				if currentPixels_d(1) = '1' then
					pixelColor := shiftingChar_d(11 downto 8);
				else
					case shiftingChar_d(7 downto 6) is
					when "01" => pixelColor := B1C;
					when "10" => pixelColor := B2C;
					when "11" => pixelColor := B3C;
					when others	=> null;
					end case;
				end if;
			elsif emulateGraphics and (MCMDelay = '0') and (BMMDelay = '1') and (ECMDelay = '0') then
				-- highres bitmap mode
				if currentPixels_d(1) = '1' then
					pixelColor := shiftingChar_d(7 downto 4);
				else
					pixelColor := shiftingChar_d(3 downto 0);
				end if;
			elsif emulateGraphics and (MCMDelay = '1') and (BMMDelay = '1') and (ECMDelay = '0') then
				-- Multi-color bitmap mode
				case currentPixels_d is
				when "01" => pixelColor := shiftingChar_d(7 downto 4);
				when "10" => pixelColor := shiftingChar_d(3 downto 0);
				when "11" => pixelColor := shiftingChar_d(11 downto 8);
				when others => null;
				end case;
			else
				-- illegal display mode, the output is black
				pixelColor := "0000";
			end if;

			myColor := pixelColor;
			case muxColor is
			when "01" => myColor := MM0;
			when "10" => myColor := spriteColors(to_integer(muxSprite));
			when "11" => myColor := MM1;
			when others =>
				null;
			end case;
		
		
--			myColor := pixelColor;
--			for i in 7 downto 0 loop
--				if (MPRIO(i) = '0') or (pixelBgFlag = '0') then
--					if MC(i) = '1' then
--						case MCurrentPixel(i) is
--						when "01" => myColor := MM0;
--						when "10" => myColor := spriteColors(i);
--						when "11" => myColor := MM1;
--						when others => null;
--						end case;
--					elsif MCurrentPixel(i)(1) = '1' then
--						myColor := spriteColors(i);
--					end if;
--				end if;
--			end loop;
			
			if enaPixel = '1' then
				colorIndex_r <= myColor;

-- Krestage 3 debugging routine
--				if (cs = '1' and aRegisters = "011100") then
--					colorIndex_r <= "1111";
--				end if;
				if MainBorder = '1' then
					colorIndex_r <= EC;
				end if;
				if (hBlack = '1') then
					colorIndex_r <= (others => '0');
				end if;
			end if;
			if ss_en = '1' then
				colorIndex_r <= unsigned(ss_d(O_COLORINDEX+3 downto O_COLORINDEX));
			end if;
		end if;
	end process;

-- -----------------------------------------------------------------------
-- Collision register clear flag
-- -----------------------------------------------------------------------
collisionClearFlag: process(clk)
	begin
		if rising_edge(clk) then
			-- spritevssprite.prg
			if myRd = '1' and aRegisters = "011110" then
				M2MClr <= '1';
			end if;
			if phi = '0' and enaPixel = '1' and not (addr_r = "011110" and rd_r = '1') then
				M2MClr <= '0';
			end if;
			if ss_en = '1' then
				M2MClr <= ss_d(O_M2MCLR);
			end if;
		end if;
	end process;

-- -----------------------------------------------------------------------
-- Sprite to sprite collision
-- -----------------------------------------------------------------------
spriteSpriteCollision: process(clk)
	begin
		if rising_edge(clk) then
			if resetIMMC = '1' and ss_hold = '0' then
				IMMC <= '0';
			end if;

			if enaPixel = '1' then
				for i in 0 to 7 loop
					if MC(i) = '0' then
						collision(i) <= MCurrentPixel(i)(1);
					else
						collision(i) <= MCurrentPixel(i)(1) or MCurrentPixel(i)(0);
					end if;
				end loop;
				if  (collision /= "00000000")
				and (collision /= "00000001")
				and (collision /= "00000010")
				and (collision /= "00000100")
				and (collision /= "00001000")
				and (collision /= "00010000")
				and (collision /= "00100000")
				and (collision /= "01000000")
				and (collision /= "10000000") then
					M2M <= M2M or collision;

				end if;

				-- Give collision interrupt but only once until clear of register
				if M2M /= 0 and M2Mhit = '0' then
					IMMC <= '1';
					M2Mhit <= '1';
				end if;

				if M2MClr = '1' then
					M2M <= (others => '0');
					M2Mhit <= '0';
				end if;
			end if;
			if ss_en = '1' then
				IMMC      <= ss_d(O_IMMC);
				collision <= unsigned(ss_d(O_COLLISION+7 downto O_COLLISION));
				M2M       <= unsigned(ss_d(O_M2M+7 downto O_M2M));
				M2Mhit    <= ss_d(O_M2MHIT);
			end if;
		end if;
	end process;

-- -----------------------------------------------------------------------
-- Sprite to background collision
-- -----------------------------------------------------------------------
spriteBackgroundCollision: process(clk)
	begin
		if rising_edge(clk) then
			if resetIMBC = '1' and ss_hold = '0' then
				IMBC <= '0';
			end if;

			if enaPixel = '1' then
				for i in 0 to 7 loop
					if ((MC(i) = '0' and MCurrentPixel(i)(1) = '1') or
					    (MC(i) = '1' and MCurrentPixel(i) /= "00"))
					and pixelBgFlag = '1'
					and (TBBorder = '0') then
						M2DDelay(i) <= '1';
					end if;
				end loop;

				M2D <= M2DDelay;
				-- Give collision interrupt but only once until clear of register
				if M2DDelay /= 0 and M2Dhit = '0' then
					IMBC <= '1';
					M2Dhit <= '1';
				end if;
			end if;

			if (myRd = '1')
			and	(aRegisters = "011111") then
				M2D <= (others => '0');
				M2DDelay <= (others => '0');
				M2Dhit <= '0';
			end if;
			if ss_en = '1' then
				IMBC     <= ss_d(O_IMBC);
				M2DDelay <= unsigned(ss_d(O_M2DDELAY+7 downto O_M2DDELAY));
				M2D      <= unsigned(ss_d(O_M2D+7 downto O_M2D));
				M2Dhit   <= ss_d(O_M2DHIT);
			end if;
		end if;
	end process;

-- -----------------------------------------------------------------------
-- Generate IRQ signal
-- -----------------------------------------------------------------------
	IRQ <= (ILP and ELP) or (IMMC and EMMC) or (IMBC and EMBC) or (IRST and ERST);

-- -----------------------------------------------------------------------
-- Write registers
-- -----------------------------------------------------------------------
writeRegisters: process(clk)
	begin
		if rising_edge(clk) then
		-- the reset pulses are cleared on every clock: held with the machine
		if ss_hold = '0' then
			resetLightPenIrq <= '0';
			resetIMMC <= '0';
			resetIMBC <= '0';
			resetRasterIrq <= '0';
		
			--
			-- write to registers
			if(reset = '1') then
				MX(0) <= (others => '0');
				MX(1) <= (others => '0');
				MX(2) <= (others => '0');
				MX(3) <= (others => '0');
				MX(4) <= (others => '0');
				MX(5) <= (others => '0');
				MX(6) <= (others => '0');
				MX(7) <= (others => '0');
				rasterCmp <= (others => '0');
				ECM <= '0';
				BMM <= '0';
				DEN <= '0';
				RSEL <= '0';
				yscroll <= (others => '0');
				ME <= (others => '0');
				RES <= '0';
				MCM <= '0';
				CSEL <= '0';
				xscroll <= (others => '0');
				MYE <= (others => '0');
				VM <= (others => '0');
				CB <= (others => '0');
				resetLightPenIrq <= '0';
				resetIMMC <= '0';
				resetIMBC <= '0';
				resetRasterIrq <= '0';
				ELP <= '0';
				EMMC <= '0';
				EMBC <= '0';
				ERST <= '0';
				MPRIO <= (others => '0');
				MCDelay <= (others => '0');
				MXE <= (others => '0');
				EC <= (others => '0');
				B0C <= (others => '0');
				B1C <= (others => '0');
				B2C <=(others => '0');
				B3C <= (others => '0');
				MM0 <= (others => '0');
				MM1 <= (others => '0');
				spriteColors(0) <= (others => '0');
				spriteColors(1) <= (others => '0');
				spriteColors(2) <= (others => '0');
				spriteColors(3) <= (others => '0');
				spriteColors(4) <= (others => '0');
				spriteColors(5) <= (others => '0');
				spriteColors(6) <= (others => '0');
				spriteColors(7) <= (others => '0');
				turbo_reg <= '0';
			else

				if (myWr_phi1 = '1' and (rasterX(1 downto 0) = "00" and enaPixel = '0' and variant = "01")) then
					-- HMOS versions seems to use the color registers too fast, before they latch the proper value from the bus
					case aRegisters is
					when "100000" => EC <= x"F";
					when "100001" => B0C <= x"F";
					when "100010" => B1C <= x"F";
					when "100011" => B2C <= x"F";
					when "100100" => B3C <= x"F";
					when "100101" => MM0 <= x"F";
					when "100110" => MM1 <= x"F";
					when "100111" => spriteColors(0) <= x"F";
					when "101000" => spriteColors(1) <= x"F";
					when "101001" => spriteColors(2) <= x"F";
					when "101010" => spriteColors(3) <= x"F";
					when "101011" => spriteColors(4) <= x"F";
					when "101100" => spriteColors(5) <= x"F";
					when "101101" => spriteColors(6) <= x"F";
					when "101110" => spriteColors(7) <= x"F";
					when others => null;
					end case;
				end if;

				if (myWr_phi1 = '1' and (enaPixel = '1' or variant = "10")) then
					-- assumption: color registers are latched during the whole PHI high cycle
					case aRegisters is
					when "100000" => EC <= diRegisters(3 downto 0);
					when "100001" => B0C <= diRegisters(3 downto 0);
					when "100010" => B1C <= diRegisters(3 downto 0);
					when "100011" => B2C <= diRegisters(3 downto 0);
					when "100100" => B3C <= diRegisters(3 downto 0);
					when "100101" => MM0 <= diRegisters(3 downto 0);
					when "100110" => MM1 <= diRegisters(3 downto 0);
					when "100111" => spriteColors(0) <= diRegisters(3 downto 0);
					when "101000" => spriteColors(1) <= diRegisters(3 downto 0);
					when "101001" => spriteColors(2) <= diRegisters(3 downto 0);
					when "101010" => spriteColors(3) <= diRegisters(3 downto 0);
					when "101011" => spriteColors(4) <= diRegisters(3 downto 0);
					when "101100" => spriteColors(5) <= diRegisters(3 downto 0);
					when "101101" => spriteColors(6) <= diRegisters(3 downto 0);
					when "101110" => spriteColors(7) <= diRegisters(3 downto 0);
					when others => null;
					end case;
				end if;

				if (myWr_a = '1') then
					case addr_r is
					when "010001" =>
						RSEL <= di_r(3);
					when "011001" =>
						resetLightPenIrq <= di_r(3);
						resetIMMC <= di_r(2);
						resetIMBC <= di_r(1);
						resetRasterIrq <= di_r(0);
					when "011101" => MXE <= di_r;
					when others => null;
					end case;
				end if;
				if (myWr_b = '1') then
					case addr_r is
					when "010001" =>
						rasterCmp(8) <= di_r(7);
						ECM <= di_r(6);
						BMM <= di_r(5);
						DEN <= di_r(4);
						yscroll <= di_r(2 downto 0);
					when "010010" =>
						rasterCmp(7 downto 0) <= di_r;
					when "010101" =>
						ME <= di_r;
					when "010110" =>
						RES <= di_r(5);
						MCM <= di_r(4);
						CSEL <= di_r(3);
					when "010111" => MYE <= di_r;
					when "011000" =>
						VM <= di_r(7 downto 4);
						CB <= di_r(3 downto 1);
					when "011010" =>
						ELP <= di_r(3);
						EMMC <= di_r(2);
						EMBC <= di_r(1);
						ERST <= di_r(0);
					when "011011" => MPRIO <= di_r;
					when "011100" =>
						-- MC <= di_r;
						MCDelay <= di_r; -- !!! Krestage 3 hack
					when others => null;
					end case;
				elsif (myWr_c = '1') then
					case addr_r is
					when "000000" => MX(0)(7 downto 0) <= di_r;
					when "000001" => MY(0) <= di_r;
					when "000010" => MX(1)(7 downto 0) <= di_r;
					when "000011" => MY(1) <= di_r;
					when "000100" => MX(2)(7 downto 0) <= di_r;
					when "000101" => MY(2) <= di_r;
					when "000110" => MX(3)(7 downto 0) <= di_r;
					when "000111" => MY(3) <= di_r;
					when "001000" => MX(4)(7 downto 0) <= di_r;
					when "001001" => MY(4) <= di_r;
					when "001010" => MX(5)(7 downto 0) <= di_r;
					when "001011" => MY(5) <= di_r;
					when "001100" => MX(6)(7 downto 0) <= di_r;
					when "001101" => MY(6) <= di_r;
					when "001110" => MX(7)(7 downto 0) <= di_r;
					when "001111" => MY(7) <= di_r;
					when "010110" => xscroll <= di_r(2 downto 0);
					when "010000" =>
						MX(0)(8) <= di_r(0);
						MX(1)(8) <= di_r(1);
						MX(2)(8) <= di_r(2);
						MX(3)(8) <= di_r(3);
						MX(4)(8) <= di_r(4);
						MX(5)(8) <= di_r(5);
						MX(6)(8) <= di_r(6);
						MX(7)(8) <= di_r(7);
					when "110000" => turbo_reg <= diRegisters(0);
					when others => null;
					end case;
				end if;
			end if;
		end if;
			if ss_en = '1' then
				resetLightPenIrq <= ss_d(O_RESETLIGHTPENIRQ);
				resetIMMC        <= ss_d(O_RESETIMMC);
				resetIMBC        <= ss_d(O_RESETIMBC);
				resetRasterIrq   <= ss_d(O_RESETRASTERIRQ);
				rasterCmp        <= unsigned(ss_d(O_RASTERCMP+8 downto O_RASTERCMP));
				ECM              <= ss_d(O_ECM);
				BMM              <= ss_d(O_BMM);
				DEN              <= ss_d(O_DEN);
				RSEL             <= ss_d(O_RSEL);
				yscroll          <= unsigned(ss_d(O_YSCROLL+2 downto O_YSCROLL));
				ME               <= unsigned(ss_d(O_ME+7 downto O_ME));
				RES              <= ss_d(O_RES);
				MCM              <= ss_d(O_MCM);
				CSEL             <= ss_d(O_CSEL);
				xscroll          <= unsigned(ss_d(O_XSCROLL+2 downto O_XSCROLL));
				MYE              <= unsigned(ss_d(O_MYE+7 downto O_MYE));
				VM               <= unsigned(ss_d(O_VM+3 downto O_VM));
				CB               <= unsigned(ss_d(O_CB+2 downto O_CB));
				ELP              <= ss_d(O_ELP);
				EMMC             <= ss_d(O_EMMC);
				EMBC             <= ss_d(O_EMBC);
				ERST             <= ss_d(O_ERST);
				MPRIO            <= unsigned(ss_d(O_MPRIO+7 downto O_MPRIO));
				MCDelay          <= unsigned(ss_d(O_MCDELAY+7 downto O_MCDELAY));
				MXE              <= unsigned(ss_d(O_MXE+7 downto O_MXE));
				EC               <= unsigned(ss_d(O_EC+3 downto O_EC));
				B0C              <= unsigned(ss_d(O_B0C+3 downto O_B0C));
				B1C              <= unsigned(ss_d(O_B1C+3 downto O_B1C));
				B2C              <= unsigned(ss_d(O_B2C+3 downto O_B2C));
				B3C              <= unsigned(ss_d(O_B3C+3 downto O_B3C));
				MM0              <= unsigned(ss_d(O_MM0+3 downto O_MM0));
				MM1              <= unsigned(ss_d(O_MM1+3 downto O_MM1));
				turbo_reg        <= ss_d(O_TURBO_REG);
				for i in 0 to 7 loop
					MX(i)           <= unsigned(ss_d(O_MX+9*i+8 downto O_MX+9*i));
					MY(i)           <= unsigned(ss_d(O_MY+8*i+7 downto O_MY+8*i));
					spriteColors(i) <= unsigned(ss_d(O_SPRITECOLORS+4*i+3 downto O_SPRITECOLORS+4*i));
				end loop;
			end if;
		end if;
	end process;

-- -----------------------------------------------------------------------
-- Read registers
-- -----------------------------------------------------------------------
readRegisters: process(clk)
	begin
		if rising_edge(clk) then
			if myRd = '1' then
			case aRegisters is
			when "000000" => do_r <= MX(0)(7 downto 0);
			when "000001" => do_r <= MY(0);
			when "000010" => do_r <= MX(1)(7 downto 0);
			when "000011" => do_r <= MY(1);
			when "000100" => do_r <= MX(2)(7 downto 0);
			when "000101" => do_r <= MY(2);
			when "000110" => do_r <= MX(3)(7 downto 0);
			when "000111" => do_r <= MY(3);
			when "001000" => do_r <= MX(4)(7 downto 0);
			when "001001" => do_r <= MY(4);
			when "001010" => do_r <= MX(5)(7 downto 0);
			when "001011" => do_r <= MY(5);
			when "001100" => do_r <= MX(6)(7 downto 0);
			when "001101" => do_r <= MY(6);
			when "001110" => do_r <= MX(7)(7 downto 0);
			when "001111" => do_r <= MY(7);
			when "010000" =>
				do_r <= MX(7)(8) & MX(6)(8) & MX(5)(8) & MX(4)(8)
				& MX(3)(8) & MX(2)(8) & MX(1)(8) & MX(0)(8);
			when "010001" => do_r <= rasterY(8) & ECM & BMM & DEN & RSEL & yscroll;
			when "010010" => do_r <= rasterY(7 downto 0);
			when "010011" => do_r <= lpX;
			when "010100" => do_r <= lpY;
			when "010101" => do_r <= ME;
			when "010110" => do_r <= "11" & RES & MCM & CSEL & xscroll;
			when "010111" => do_r <= MYE;
			when "011000" => do_r <= VM & CB & '1';
			when "011001" => do_r <= IRQ & "111" & ILP & IMMC & IMBC & IRST;
			when "011010" => do_r <= "1111" & ELP & EMMC & EMBC & ERST;
			when "011011" => do_r <= MPRIO;
			when "011100" => do_r <= MC;
			when "011101" => do_r <= MXE;
			when "011110" => do_r <= M2M;
			when "011111" => do_r <= M2D;
			when "100000" => do_r <= "1111" & EC;
			when "100001" => do_r <= "1111" & B0C;
			when "100010" => do_r <= "1111" & B1C;
			when "100011" => do_r <= "1111" & B2C;
			when "100100" => do_r <= "1111" & B3C;
			when "100101" => do_r <= "1111" & MM0;
			when "100110" => do_r <= "1111" & MM1;
			when "100111" => do_r <= "1111" & spriteColors(0);
			when "101000" => do_r <= "1111" & spriteColors(1);
			when "101001" => do_r <= "1111" & spriteColors(2);
			when "101010" => do_r <= "1111" & spriteColors(3);
			when "101011" => do_r <= "1111" & spriteColors(4);
			when "101100" => do_r <= "1111" & spriteColors(5);
			when "101101" => do_r <= "1111" & spriteColors(6);
			when "101110" => do_r <= "1111" & spriteColors(7);
			when "110000" => do_r <= "1111111" & (turbo_reg or not turbo_en);
			when others => do_r <= (others => '1');
			end case;
			end if;
			if ss_en = '1' then
				do_r <= unsigned(ss_d(O_DO+7 downto O_DO));
			end if;
		end if;
	end process;
end architecture;
