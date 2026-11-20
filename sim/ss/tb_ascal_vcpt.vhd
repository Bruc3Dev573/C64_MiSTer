-- tb_ascal_vcpt: the C64 core local change in sys/ascal.vhd (OSWEEP), the
-- end-of-frame compare o_vcpt_pre3+1>=o_vtotal registered one clock before
-- its use (o_vcpt_pre3_end). Three copies of the line counter on one clock:
--   A as upstream Template_MiSTer (compare on the clock of use),
--   B as changed (registered compare),
--   C as upstream with o_vtotal one clock late.
-- B must equal C on every clock: the change is exactly a one-clock later
-- sample of o_vtotal, which ascal takes from the mode setting without any
-- synchronization (`-- <ASYNC> ?`). Phase 1: o_vtotal changes at any clock,
-- also on a line-end clock and below the current line, o_htotal changes,
-- random o_ce and VRR jumps. Phase 2: A is set to B's counter, then
-- o_vtotal never changes on a line-end clock: A must equal B on every clock,
-- including the first line ends after each change. OSWEEP has no reset: the
-- counters start at 0 and the registered compare at false, which is 0+1 >=
-- o_vtotal for every o_vtotal >= 2. Line ends are at least two clocks apart
-- for o_htotal >= 2 (every real mode).
library ieee;
use ieee.std_logic_1164.all;
use ieee.math_real.all;

entity tb_ascal_vcpt is
end entity;

architecture sim of tb_ascal_vcpt is
	subtype uint12 is natural range 0 to 4095;
	signal clk : std_logic := '0';
	signal done : boolean := false;
	signal o_ce : std_logic := '0';
	signal o_htotal : uint12 := 5;
	signal o_vtotal, o_vtotal_d : uint12 := 20;
	signal o_vrr_sync2, resync : boolean := false;
	signal o_hcpt : uint12 := 0;
	signal a_v, b_v, c_v : uint12 := 0;
	signal b_end : boolean := false;
	constant VSSTART : uint12 := 7;
	constant N : natural := 4_000_000;
begin
	clk <= not clk after 5 ns when not done;

	-- the three counters, o_hcpt as upstream (shared)
	process(clk)
	begin
		if rising_edge(clk) then
			o_vtotal_d <= o_vtotal;
			b_end <= b_v + 1 >= o_vtotal;
			if o_ce = '1' then
				if o_hcpt + 1 < o_htotal then
					o_hcpt <= (o_hcpt + 1) mod 4096;
				else
					o_hcpt <= 0;
					if a_v + 1 >= o_vtotal then a_v <= 0;
					elsif o_vrr_sync2 then a_v <= VSSTART;
					else a_v <= (a_v + 1) mod 4096; end if;
					if b_end then b_v <= 0;
					elsif o_vrr_sync2 then b_v <= VSSTART;
					else b_v <= (b_v + 1) mod 4096; end if;
					if c_v + 1 >= o_vtotal_d then c_v <= 0;
					elsif o_vrr_sync2 then c_v <= VSSTART;
					else c_v <= (c_v + 1) mod 4096; end if;
				end if;
			end if;
			if resync then a_v <= b_v; end if;   -- only on a clock without line end
		end if;
	end process;

	process
		variable s1, s2 : positive := 7;
		variable r : real;
		variable phase2, ce, le : boolean := false;
		variable ht : uint12;
		variable n_vchg, n_le_chg, n_apart, n_wraps : natural := 0;
		impure function rnd(k : positive) return natural is
		begin
			uniform(s1, s2, r);
			return integer(trunc(r * real(k)));
		end function;
	begin
		for i in 0 to N loop
			-- inputs seen by the next rising edge E
			resync <= false;
			ce := rnd(10) < 7;
			ht := o_htotal;
			if rnd(3000) = 0 then ht := 2 + rnd(12); end if;
			if i = N / 2 then
				phase2 := true;
				resync <= true;
				ce := false;
			end if;
			le := ce and o_hcpt + 1 >= ht;   -- E is a line end
			o_ce <= '1' when ce else '0';
			o_htotal <= ht;
			o_vrr_sync2 <= rnd(300) = 0;
			if rnd(400) = 0 and not (phase2 and le) then
				o_vtotal <= 2 + rnd(60);
				n_vchg := n_vchg + 1;
				if le then n_le_chg := n_le_chg + 1; end if;
			end if;
			wait until rising_edge(clk);
			wait until falling_edge(clk);
			assert b_v = c_v report "B differs from upstream with o_vtotal one clock late" severity failure;
			if le and b_v = 0 then n_wraps := n_wraps + 1; end if;
			if a_v /= b_v then
				assert not phase2 or i = N / 2 report "A differs from B in phase 2 at clock " & integer'image(i) severity failure;
				n_apart := n_apart + 1;
			end if;
		end loop;
		report "tb_ascal_vcpt: " & integer'image(n_vchg) & " o_vtotal changes (" & integer'image(n_le_chg) &
			" on a line-end clock, phase 1), " & integer'image(n_wraps) & " frame wraps, A apart from B on " &
			integer'image(n_apart) & " clocks of phase 1, B = C on every clock, A = B in phase 2";
		report "tb_ascal_vcpt: PASS";
		done <= true;
		wait;
	end process;
end architecture;
