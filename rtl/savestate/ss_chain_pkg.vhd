-- Savestate scan chain: segment helpers (VHDL).
--
-- Same contract as rtl/savestate/ss_chain.sv: one serial chain in clk_sys,
-- one 2:1 mux per flip-flop. Bit 0 of a segment vector is the first bit that
-- leaves the segment, so the field offsets of savestate/map.yaml are bit
-- indexes of that vector. Chain order:
--   engine.chain_so -> [last segment] -> ... -> [VIC] -> [CPU] -> engine.chain_si
--
-- Instrumenting a VHDL chip (pattern):
--
--   signal ss_q : std_logic_vector(W-1 downto 0);
--   ...
--   ss_q   <= reg_c & reg_b & reg_a;          -- reg_a(0) leaves first
--   ss_so  <= ss_q(0);
--   process(clk) begin
--      if rising_edge(clk) then
--         if ss_scan_en = '1' then
--            (reg_c, reg_b, reg_a) <= ss_shift(ss_q, ss_si);  -- or slices
--         else
--            ... normal logic ...
--         end if;
--      end if;
--   end process;
--
-- or instantiate entity ss_chain_vseg (below) to get the shifted vector
-- (the SystemVerilog module of the same job is ss_chain_seg; one library).

library ieee;
use ieee.std_logic_1164.all;

package ss_chain_pkg is
	-- value of a segment after one chain step: scan_in enters at the top,
	-- bit 0 leaves (it is the segment's scan_out before the step)
	function ss_shift(q : std_logic_vector; si : std_logic) return std_logic_vector;
	-- port width of a segment that may be empty (W = 0)
	function ss_w(w : natural) return natural;
end package;

package body ss_chain_pkg is
	function ss_shift(q : std_logic_vector; si : std_logic) return std_logic_vector is
		variable v : std_logic_vector(q'length-1 downto 0);
		variable r : std_logic_vector(q'length-1 downto 0);
	begin
		v := q;
		if q'length = 1 then
			r(0) := si;
		else
			r := si & v(q'length-1 downto 1);
		end if;
		return r;
	end function;

	function ss_w(w : natural) return natural is
	begin
		if w = 0 then return 1; else return w; end if;
	end function;
end package body;

library ieee;
use ieee.std_logic_1164.all;
use work.ss_chain_pkg.all;

-- W = 0 is a reservation without bits: scan_out = scan_in.
entity ss_chain_vseg is
	generic (W : natural := 1);
	port (
		q        : in  std_logic_vector(ss_w(W)-1 downto 0);
		scan_in  : in  std_logic;
		d        : out std_logic_vector(ss_w(W)-1 downto 0);
		scan_out : out std_logic
	);
end entity;

architecture rtl of ss_chain_vseg is
begin
	g_empty: if W = 0 generate
		d        <= (others => '0');
		scan_out <= scan_in;
	end generate;
	g_bits: if W > 0 generate
		d        <= ss_shift(q, scan_in);
		scan_out <= q(0);
	end generate;
end architecture;
