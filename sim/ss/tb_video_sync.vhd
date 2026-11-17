library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;

-- video_sync driven by a model of the core's VIC raster timing
-- (fpga64_sid_iec, video_vicII_656x). A C64 cycle is 32 clk32 (positions
-- 0-31). While the machine runs, X steps on the clocks into positions 0, 4,
-- ..., 28 and wraps at the line length; the raster line steps where X
-- becomes y_step (404 PAL, 420 NTSC), the last line one cycle later (vic_y
-- shows line 0 in that cycle). The VIC hsync is high from X 397 to 496, its
-- vsync is (line = 300 PAL, 12 NTSC) one clock late. fpga64 samples its
-- pause input on the clock from position 7 to 8, so the machine stops at
-- X = 8n+6. A load puts another stop position into X and the line while
-- stopped, after the chain has moved X, the line and the VIC hsync through
-- other values. The release follows c64.sv: resume_ok sets pause_rel, the
-- next sample lets the machine run.
--
-- Checked all along: the hsync and vsync outputs keep one line and one frame
-- period across plain pauses, loads and resumes; a plain pause lasts whole
-- frames; every resume comes at most one frame after the release. The loads
-- go to the middle of the frame, both sides of the VIC frame wrap and of the
-- counter frame wrap (the vsync line), the stop positions where the dot
-- counter and the raster line step apart (X 398 PAL, 398-414 NTSC), the
-- delayed last line, the last stop of the frame and the same position, and
-- one is followed by a pause. After running PAL/NTSC switches X and the
-- line are outside the new frame; the next pause still resumes within a
-- frame.
entity tb_video_sync is
end;

architecture test of tb_video_sync is
	signal clk32 : std_logic := '1';
	signal pause, hsync, vsync, ntsc : std_logic := '0';
	signal vic_x : std_logic_vector(9 downto 0) := (others => '0');
	signal vic_y : std_logic_vector(8 downto 0) := (others => '0');
	signal hsync_out, vsync_out, hblank, vblank, tick, resume_ok : std_logic;
	signal armed : boolean := false;
begin
	dut : entity work.video_sync port map (
		clk32 => clk32, pause => pause, hsync => hsync, vsync => vsync, vic_x => vic_x, vic_y => vic_y,
		ntsc => ntsc, wide => '0', hsync_out => hsync_out, vsync_out => vsync_out,
		hblank => hblank, vblank => vblank, tick => tick, resume_ok => resume_ok
	);

	-- output periods: one line and one frame whenever armed
	check : process(clk32)
		variable t, hs_at, vs_at : natural := 0;
		variable hs_r, vs_r : std_logic := '0';
		variable line, frame : natural;
	begin
		if rising_edge(clk32) then
			t := t + 1;
			if ntsc = '1' then line := 520 * 4; frame := line * 263; else line := 504 * 4; frame := line * 312; end if;
			if not armed then hs_at := 0; vs_at := 0; end if;
			if hsync_out = '1' and hs_r = '0' then
				assert hs_at = 0 or t - hs_at = line
					report "FAIL: hsync period " & integer'image(t - hs_at) & ", expected " & integer'image(line) severity failure;
				hs_at := t;
			end if;
			if vsync_out = '1' and vs_r = '0' then
				assert vs_at = 0 or t - vs_at = frame
					report "FAIL: vsync period " & integer'image(t - vs_at) & ", expected " & integer'image(frame) severity failure;
				vs_at := t;
			end if;
			hs_r := hsync_out; vs_r := vsync_out;
		end if;
	end process;

	stim : process
		variable dots, lines, y_step, y_sync : natural := 1;
		-- raster X and line (rasterY); X is 8n+4 on position 0 (fpga64: X steps
		-- to the next cycle, low bits 0, on the clock into position 16)
		variable x : natural := 4;
		variable y : natural := 0;
		variable dly : boolean := false;       -- last line: the step to line 0 one cycle later
		variable pos : natural := 0;           -- clk32 in the C64 cycle
		variable run : boolean := true;
		variable rel : boolean := false;       -- c64.sv pause_rel
		variable hb, vb : std_logic := '0';
		variable clocks, loads, pauses : natural := 0;

		procedure geometry(n : std_logic) is
		begin
			ntsc <= n;
			if n = '1' then dots := 520; lines := 263; y_step := 420; y_sync := 12;
			else dots := 504; lines := 312; y_step := 404; y_sync := 300; end if;
		end;

		-- one clk32: the core's registers change on the rising edge, video_sync
		-- takes what they held before it
		procedure cycle(stop_req : boolean := false; go : boolean := false) is
			variable ro, was_run : boolean;
		begin
			ro := resume_ok = '1';             -- pause_rel takes resume_ok of this clock
			clk32 <= '0'; wait for 5 ns;
			clk32 <= '1'; wait for 1 ns;
			clocks := clocks + 1;
			was_run := run;
			if pos = 7 then                    -- fpga64 pause sample, with pause_rel of this clock
				if run and stop_req then run := false;
				elsif not run and rel then run := true; end if;
			end if;
			if was_run or not go then rel := false; elsif ro then rel := true; end if;
			if y = y_sync then vb := '1'; else vb := '0'; end if;
			if was_run and pos mod 4 = 3 then    -- pixel step on the clocks into positions 0, 4, ...
				if x = 396 then hb := '1'; elsif x = 496 then hb := '0'; end if;
				x := x + 1;
				if x >= dots and x mod 8 = 0 then x := 0; end if;   -- the VIC wraps X on a cycle step
				if x = y_step then
					if y = lines - 1 then dly := true; elsif y >= 511 then y := 0; else y := y + 1; end if;
				elsif x = y_step + 8 and dly then
					y := 0; dly := false;
				end if;
			end if;
			pos := (pos + 1) mod 32;
			if run then pause <= '0'; else pause <= '1'; end if;
			hsync <= hb; vsync <= vb;
			vic_x <= std_logic_vector(to_unsigned(x, 10));
			if dly then vic_y <= (others => '0'); else vic_y <= std_logic_vector(to_unsigned(y, 9)); end if;
			wait for 4 ns;
		end;

		procedure run_clocks(n : natural) is
		begin
			for i in 1 to n loop cycle; end loop;
		end;

		procedure run_to_line(l : natural) is
		begin
			while y /= l or dly loop cycle; end loop;
		end;

		-- stop on the next pause sample: the VIC stops at X = 8n+6
		procedure stop is
		begin
			while run loop cycle(stop_req => true); end loop;
			assert x mod 8 = 6 report "FAIL: model stopped at X " & integer'image(x) severity failure;
		end;

		-- the release after hold clocks; the machine must run again within a frame
		procedure resume(hold : natural; what : string) is
			variable c : natural := 0;
		begin
			run_clocks(hold);
			while not run loop
				cycle(go => true);
				c := c + 1;
				assert c <= dots * lines * 4 + 64 report "FAIL: no resume within a frame after the release, " & what severity failure;
			end loop;
		end;

		-- a frame and a line of output after a resume: the checker sees the
		-- next hsync and vsync of the VIC
		procedure settle is
		begin
			run_clocks(dots * lines * 4 + 4 * dots);
		end;

		procedure plain_pause(hold : natural; what : string) is
			variable sx, sy, t0 : natural;
		begin
			stop;
			sx := x; sy := y; t0 := clocks;
			resume(hold, what);
			assert x = sx and y = sy report "FAIL: " & what & " moved the VIC" severity failure;
			assert (clocks - t0) mod (dots * lines * 4) = 0
				report "FAIL: " & what & " lasted " & integer'image(clocks - t0) & " clocks, not whole frames" severity failure;
			pauses := pauses + 1;
			settle;
		end;

		-- a load while stopped: the chain moves X, the line and the VIC hsync
		-- through other values, then the VIC is at the saved stop position
		-- (X lx = 8n+6 on raster line ly); hold: the pause after it
		procedure load(lx, ly : natural; what : string; hold : natural := 3) is
		begin
			stop;
			for i in 1 to 37 loop
				hb := not hb;
				x := (x * 7 + 13) mod 1024;
				y := (y * 5 + 3) mod 512;
				cycle;
			end loop;
			x := lx; y := ly;
			dly := ly = lines - 1 and lx > y_step and lx < y_step + 8;
			if lx >= 397 and lx <= 496 then hb := '1'; else hb := '0'; end if;
			resume(hold, what);
			loads := loads + 1;
			settle;
		end;
	begin
		for standard in 0 to 1 loop
			if standard = 0 then geometry('0'); else geometry('1'); end if;
			armed <= false;
			run_clocks(3 * dots * lines * 4);   -- the counters align on the VIC syncs
			armed <= true;
			plain_pause(1000, "a short pause");
			plain_pause(dots * lines * 6, "a pause of 1.5 frames");
			load(406, 100, "a load in the middle of the frame");
			load(398, 100, "a load at X 398 (the dot counter has stepped, the raster line not)");
			load(398, y_sync, "a load at X 398 of the vsync line");
			load(y_step + 2, lines - 1, "a load in the cycle of the delayed last line");
			load(dots - 2, lines - 1, "a load at the last stop of the VIC frame");
			load(6, 0, "a load at the first stop of the VIC frame");
			stop;
			load(x, y, "a load of the stop position");
			load(430, 150, "a load followed by a pause", dots * lines * 6);
			run_to_line(lines - 2);
			load(102, 2, "a load across the VIC frame wrap, forward");
			run_to_line(2);
			load(470, lines - 2, "a load across the VIC frame wrap, backward");
			run_to_line(y_sync - 2);
			load(102, y_sync + 2, "a load across the counter frame wrap (vsync), forward");
			run_to_line(y_sync + 2);
			load(470, y_sync - 2, "a load across the counter frame wrap (vsync), backward");
			if standard = 1 then
				load(406, 50, "an NTSC load at X 406 (raster line steps at 420)");
				load(414, 50, "an NTSC load at X 414");
				load(422, 50, "an NTSC load at X 422, right after the raster line step");
			end if;
			plain_pause(1000, "a pause after the loads");
		end loop;

		-- running standard switches leave the VIC outside the new frame
		armed <= false;
		geometry('0');
		run_clocks(3 * dots * lines * 4);
		run_to_line(300);
		geometry('1');
		run_clocks(4);
		stop;
		resume(1000, "a running PAL to NTSC switch above the new last line");
		run_clocks(3 * dots * lines * 4);
		while x /= 510 loop cycle; end loop;
		geometry('0');
		stop;
		resume(1000, "a running NTSC to PAL switch beyond the new last dot");
		report "tb_video_sync: PASS; PAL/NTSC output periods constant across " & integer'image(pauses) & " pauses (whole frames) and " &
			integer'image(loads) & " loads (resume within a frame), resume after running standard switches";
		finish;
	end process;
end;
