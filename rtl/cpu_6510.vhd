-- -----------------------------------------------------------------------
--
--                                 FPGA 64
--
--     A fully functional commodore 64 implementation in a single FPGA
--
-- -----------------------------------------------------------------------
-- Copyright 2005-2008 by Peter Wendrich (pwsoft@syntiac.com)
-- http://www.syntiac.com/fpga64.html
-- -----------------------------------------------------------------------
--
-- 6510 wrapper for 65xx core
-- Adds 8 bit I/O port mapped at addresses $0000 to $0001
--
-- -----------------------------------------------------------------------

library IEEE;
use ieee.std_logic_1164.ALL;
use ieee.numeric_std.ALL;

-- -----------------------------------------------------------------------

entity cpu_6510 is
	port (
		clk     : in  std_logic;
		enable  : in  std_logic;
		reset   : in  std_logic;
		nmi_n   : in  std_logic;
		nmi_ack : out std_logic;
		irq_n   : in  std_logic;
		rdy     : in  std_logic;

		di      : in  unsigned(7 downto 0);
		do      : out unsigned(7 downto 0);
		addr    : out unsigned(15 downto 0);
		we      : out std_logic;

		diIO    : in  unsigned(7 downto 0);
		doIO    : out unsigned(7 downto 0);

		sync    : out std_logic;  -- opcode fetch cycle (T65 MCycle 0): savestate boundary

		-- savestate scan chain, segment CPU (docs/SAVESTATES.md): ss_en shifts,
		-- ss_hold = the engine owns the stopped machine, ss_load_done pulses
		-- after a load (before the machine is released)
		ss_en        : in  std_logic := '0';
		ss_hold      : in  std_logic := '0';
		ss_load_done : in  std_logic := '0';
		ss_si        : in  std_logic := '0';
		ss_so        : out std_logic
	);
end cpu_6510;

-- -----------------------------------------------------------------------

architecture rtl of cpu_6510 is
	signal localA : std_logic_vector(23 downto 0);
	signal localDi : std_logic_vector(7 downto 0);
	signal localDo : std_logic_vector(7 downto 0);
	signal localWe : std_logic;

	signal currentIO : std_logic_vector(7 downto 0);
	signal ioDir : std_logic_vector(7 downto 0);
	signal ioData : std_logic_vector(7 downto 0);
	
	signal accessIO : std_logic;
	signal nmi_ack_i : std_logic;

	-- currentIO is rewritten every clock and drives the cassette lines (RTC
	-- I2C, use_rtc) and the banking: it never shifts. The chain carries
	-- ss_currentio, its copy taken until the engine holds the machine,
	-- written back on ss_load_done.
	signal ss_currentio : std_logic_vector(7 downto 0);
	signal ss_t65_so    : std_logic;
	signal ss_port      : std_logic_vector(23 downto 0);
begin

	cpu: work.T65
	port map(
		Mode    => "00",
		Res_n   => not reset,
		Enable  => enable,
		Clk     => clk,
		Rdy     => rdy,
		Abort_n => '1',
		IRQ_n   => irq_n,
		NMI_n   => nmi_n,
		SO_n    => '1',
		R_W_n   => localWe,
		A       => localA,
		DI      => localDi,
		DO      => localDo,
		NMI_ack => nmi_ack_i,
		Sync    => sync,
		SS_En   => ss_en,
		SS_Hold => ss_hold,
		SS_SI   => ss_si,
		SS_SO   => ss_t65_so
	);

	accessIO <= '1' when localA(15 downto 1) = X"000"&"000" else '0';
	localDi  <= localDo when localWe = '0' else std_logic_vector(di) when accessIO = '0' else ioDir when localA(0) = '0' else currentIO;

	-- NMI_ack is 0 at a boundary (MCycle 0); masked while the chain shifts so
	-- a cartridge freezer never sees a pulse
	nmi_ack <= nmi_ack_i and not ss_en;

	-- segment bits: the T65 bits, then iodir, iodata, currentio (bit 0 out first)
	ss_port <= iodir & ioData & ss_currentio;
	ss_so   <= ss_port(0);

	process(clk)
	begin
		if rising_edge(clk) then
			if accessIO = '1' then
				if localWe = '0' and enable = '1' then
					if localA(0) = '0' then
						ioDir <= localDo;
					else
						ioData <= localDo;
					end if;
				end if;
			end if;

			-- held while the engine owns the machine: ioDir/ioData shift then,
			-- and an input bit (it keeps its level) would latch a passing bit
			if ss_hold = '0' then
				currentIO <= (ioData and ioDir) or (std_logic_vector(diIO) and not ioDir);
			end if;

			if reset = '1' then
				ioDir <= (others => '0');
				ioData <= (others => '1');
				currentIO <= "00111111";  -- upper two bits are unused; ensure that the KERNAL is able to set Zero Page address $01 to $37 by default
			end if;

			if ss_en = '1' then
				ss_currentio <= ss_port(8 downto 1);
				ioData       <= ss_port(16 downto 9);
				ioDir        <= ss_t65_so & ss_port(23 downto 17);
			elsif ss_hold = '0' then
				ss_currentio <= currentIO;
			end if;
			if ss_load_done = '1' then
				currentIO <= ss_currentio;
			end if;
		end if;
	end process;

	-- Cunnect zee wires
	addr <= unsigned(localA(15 downto 0));
	do <= unsigned(localDo);
	we <= not localWe;
	doIO <= unsigned(currentIO);
end architecture;
