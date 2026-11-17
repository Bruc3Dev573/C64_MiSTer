library ieee; use ieee.std_logic_1164.all;
entity dprom is
	generic (INIT_FILE : string := ""; ADDR_WIDTH : natural := 14; DATA_WIDTH : natural := 8);
	port (wrclock : in std_logic; wraddress : in std_logic_vector(ADDR_WIDTH-1 downto 0) := (others => '0');
	      data : in std_logic_vector(DATA_WIDTH-1 downto 0) := (others => '0'); wren : in std_logic := '0';
	      rdclock : in std_logic; rdaddress : in std_logic_vector(ADDR_WIDTH-1 downto 0);
	      q : out std_logic_vector(DATA_WIDTH-1 downto 0); cs : in std_logic := '1');
end dprom;
architecture bb of dprom is
	attribute syn_black_box : boolean;
	attribute syn_black_box of bb : architecture is true;
begin end bb;
