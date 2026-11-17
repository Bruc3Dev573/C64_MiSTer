---------------------------------------------------------------------------------
-- composite_sync by Dar (darfpga@aol.fr)
-- http://darfpga.blogspot.fr
--
-- Generate composite sync and blank for tv mode from h/v syncs
--
-- Pause: the VIC stops with the machine, so its h/v syncs stop. The dot and
-- line counters then run on their own with the selected VIC geometry, and
-- the outputs keep a regular sync/blank for the analog output and the pause
-- frame buffer. While stopped, the position the counters must have when the
-- machine runs again comes from the VIC raster position on every dot, so
-- after a savestate load it is the one of the loaded VIC. The machine resumes
-- when the free-running position is back on it (resume_ok, at most one frame
-- later), so the sync is continuous across pauses, saves and loads.
--
---------------------------------------------------------------------------------

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.std_logic_unsigned.all;
use IEEE.numeric_std.all;

entity video_sync is
generic(
	-- resume_ok fires this many dots before the free-running position is back
	-- on the stopped one. With 0 the release (resume_ok -> c64.sv -> pause
	-- input) still reaches fpga64 before the pause sample of that C64 cycle,
	-- so the VIC restarts exactly where the output is (checked by the sim
	-- pausetest and ssdiff: hsync/vsync periods constant across pauses and loads)
	LEAD : integer := 0
);
port(
	clk32 : in std_logic;
	pause : in std_logic;
	hsync : in std_logic;
	vsync : in std_logic;
	-- VIC raster position (fpga64 vic_x, vic_y): X, and the raster line with
	-- the delayed step of the last line to line 0 already applied
	vic_x : in std_logic_vector(9 downto 0);
	vic_y : in std_logic_vector(8 downto 0);
	ntsc  : in std_logic;
	wide  : in std_logic;
	hsync_out : out std_logic;
	vsync_out : out std_logic;
	hblank : out std_logic;
	vblank : out std_logic;
	-- one clk32 pulse each dot (the outputs above change with it)
	tick : out std_logic;
	-- while paused: the free-running position is LEAD dots before the
	-- position of the stopped VIC (one pulse per frame)
	resume_ok : out std_logic
);
end;

architecture struct of video_sync is

	signal clk_cnt : std_logic_vector(1 downto 0);
	signal vsync_r : std_logic;
	signal hsync_r : std_logic;
	signal hsync_r0 : std_logic;

begin

process(clk32)
	variable  dot_count : integer range 0 to 1023 := 0;
	variable line_count : integer range 0 to 511 := 0;
	variable line_reset : std_logic := '0';
	variable  dot_last  : integer range 0 to 1023;
	variable line_last  : integer range 0 to 511;
	variable  y_step    : integer range 0 to 1023;
	variable  y_sync    : integer range 0 to 511;
	variable  fdot      : integer range 0 to 1023 := 0;
	variable fline      : integer range 0 to 511 := 0;
	variable  tdot      : integer range 0 to 1023;
	variable tline      : integer range 0 to 511;
	variable  vx        : integer range 0 to 1023;
	variable  vy        : integer range 0 to 1023;
	begin
	if falling_edge(clk32) then
		hsync_r0 <= hsync;
		-- the dot phase follows the VIC hsync while the machine runs; while it
		-- is stopped a savestate operation shifts the VIC hsync through the
		-- bits of the chain
		if hsync_r0 = '0' and hsync = '1' and pause = '0' then
			clk_cnt <= "11";
		else
			clk_cnt <= clk_cnt + '1';
		end if;
	end if;

	if rising_edge(clk32) then
		-- fpga64 drives 6569 or 6567R8. y_step: X where the VIC raster line steps
		-- (on vic_y also for the last line), y_sync: the raster line whose VIC
		-- vsync starts line 0 of the counter
		if ntsc = '1' then
			dot_last := 519;
			line_last := 262;
			y_step := 420;
			y_sync := 12;
		else
			dot_last := 503;
			line_last := 311;
			y_step := 404;
			y_sync := 300;
		end if;
		tick <= '0';
		resume_ok <= '0';
		if clk_cnt = "00" then
			tick <= '1';
			-- A running standard change can put the old position outside the new frame.
			if dot_count > dot_last then dot_count := 0; end if;
			if line_count > line_last then line_count := 0; end if;
			if pause = '0' then
				vsync_r <= vsync;
				hsync_r <= hsync;

				if hsync_r = '0' and hsync = '1' then
					dot_count := 0;
					if line_reset = '1' then
						line_count := 0;
						line_reset := '0';
					elsif line_count >= line_last then
						line_count := 0;
					else
						line_count := line_count + 1;
					end if;
				elsif dot_count >= dot_last then
					dot_count := 0;
				else
					dot_count := dot_count + 1;
				end if;

				if vsync_r = '0' and vsync = '1' then
					line_reset := '1';
				end if;

				fdot := dot_count;
				fline := line_count;
			else
				-- The counters as the machine left them, taken from the stopped
				-- VIC: it stops one pixel after the last running dot (X = 8n+6),
				-- the dot counter is 0 at X 397 (VIC hsync), the line counter
				-- steps there and the raster line at y_step: between the two the
				-- counter is on the raster line, elsewhere on the one before;
				-- line 0 of the counter starts on raster line y_sync. A plain
				-- pause gives the position the counters hold, a load the one of
				-- the loaded VIC. While the chain shifts the values pass through
				-- garbage (c64.sv takes no resume_ok during an operation).
				vx := to_integer(unsigned(vic_x));
				vy := to_integer(unsigned(vic_y));
				if vx >= 398 then dot_count := vx - 398; else dot_count := vx + dot_last - 397; end if;
				if dot_count > dot_last then dot_count := 0; end if;
				if vx < 398 or vx > y_step then vy := vy + line_last; end if;   -- the line before (mod)
				if vy >= y_sync then vy := vy - y_sync; else vy := vy + line_last + 1 - y_sync; end if;
				if vy > line_last then vy := vy - line_last - 1; end if;
				if vy > line_last then vy := 0; end if;
				line_count := vy;
				-- with the counters on the VIC their wrap is the vsync reset; the
				-- edge detectors hold the syncs of the stopped VIC (no edge on the
				-- first dot after the resume)
				line_reset := '0';
				hsync_r <= hsync;
				if to_integer(unsigned(vic_y)) = y_sync then vsync_r <= '1'; else vsync_r <= '0'; end if;

				-- free run from the stopped position
				if fdot >= dot_last then
					fdot := 0;
					if fline >= line_last then
						fline := 0;
					else
						fline := fline + 1;
					end if;
				else
					fdot := fdot + 1;
				end if;

				if dot_count >= LEAD then
					tdot := dot_count - LEAD;
					tline := line_count;
				else
					tdot := dot_count + dot_last + 1 - LEAD;
					if line_count = 0 then
						tline := line_last;
					else
						tline := line_count - 1;
					end if;
				end if;
				if fdot = tdot and fline = tline then
					resume_ok <= '1';
				end if;
			end if;
			
			if ntsc = '1' then
				if fdot     = 054 then hsync_out <= '0'; end if;
				if fdot     = 016 then hsync_out <= '1';
					if fline = 000 then vsync_out <= '1'; end if;
					if fline = 004 then vsync_out <= '0'; end if;
				end if;

				if fline = 000 then vblank <= '1'; end if;
				if fline = 013 then vblank <= '0'; end if;

				if wide = '0' then
					if fdot  = 516 then hblank <= '1'; end if;
					if fdot  = 112 then hblank <= '0'; end if;
				else
					if fdot  = 496 then hblank <= '1'; end if;
					if fdot  = 132 then hblank <= '0'; end if;
				end if;
			else
				if fdot     = 048 then hsync_out <= '0'; end if;
				if fdot     = 010 then hsync_out <= '1';
					if fline = 307 then vsync_out <= '1'; end if;
					if fline = 311 then vsync_out <= '0'; end if;
				end if;

				if fline = 298 then vblank <= '1'; end if;
				if fline = 028 then vblank <= '0'; end if;

				if wide = '0' then
					if fdot  = 489 then hblank <= '1'; end if;
					if fdot  = 107 then hblank <= '0'; end if;
				else
					if fdot  = 463 then hblank <= '1'; end if;
					if fdot  = 133 then hblank <= '0'; end if;
				end if;
			end if;

		end if;
	end if;
end process;

end architecture;
