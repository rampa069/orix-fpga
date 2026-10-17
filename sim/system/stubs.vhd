-- stubs.vhd
-- VHDL stand-ins for the Verilog parts of telestrat.vhd (ay_ym_psg.v and
-- keyboard.sv), so the whole machine can be simulated with a VHDL simulator.
-- No sound and no key pressed.

LIBRARY IEEE;
USE IEEE.STD_LOGIC_1164.ALL;
USE IEEE.NUMERIC_STD.ALL;

ENTITY keyboard IS
	PORT (
		clk_sys      : IN  STD_LOGIC;
		key_pressed  : IN  STD_LOGIC;
		key_extended : IN  STD_LOGIC;
		key_strobe   : IN  STD_LOGIC;
		key_code     : IN  STD_LOGIC_VECTOR(7 DOWNTO 0);
		row          : IN  STD_LOGIC_VECTOR(2 DOWNTO 0);
		col          : IN  STD_LOGIC_VECTOR(7 DOWNTO 0);
		key_hit      : OUT STD_LOGIC;
		swnmi        : OUT STD_LOGIC;
		swrst        : OUT STD_LOGIC
	);
END keyboard;

ARCHITECTURE stub OF keyboard IS
BEGIN
	key_hit <= '0';
	swnmi   <= '0';
	swrst   <= '0';
END stub;

LIBRARY IEEE;
USE IEEE.STD_LOGIC_1164.ALL;
USE IEEE.STD_LOGIC_ARITH.ALL;   -- telestrat.vhd declares the component with this UNSIGNED

ENTITY ay_ym_psg IS
	PORT (
		ym    : IN  STD_LOGIC;
		clock : IN  STD_LOGIC;
		ce    : IN  STD_LOGIC;
		reset : IN  STD_LOGIC;
		bdir  : IN  STD_LOGIC;
		bc1   : IN  STD_LOGIC;
		sel   : IN  STD_LOGIC;
		d     : IN  STD_LOGIC_VECTOR(7 DOWNTO 0);
		q     : OUT STD_LOGIC_VECTOR(7 DOWNTO 0);
		ioad  : IN  STD_LOGIC_VECTOR(7 DOWNTO 0);
		ioaq  : OUT STD_LOGIC_VECTOR(7 DOWNTO 0);
		iobd  : IN  STD_LOGIC_VECTOR(7 DOWNTO 0);
		iobq  : OUT STD_LOGIC_VECTOR(7 DOWNTO 0);
		MIX   : OUT UNSIGNED(14 DOWNTO 0);
		A     : OUT UNSIGNED(11 DOWNTO 0);
		B     : OUT UNSIGNED(11 DOWNTO 0);
		C     : OUT UNSIGNED(11 DOWNTO 0)
	);
END ay_ym_psg;

ARCHITECTURE stub OF ay_ym_psg IS
BEGIN
	q    <= x"FF";
	ioaq <= x"FF";
	iobq <= x"FF";
	MIX  <= (OTHERS => '0');
	A    <= (OTHERS => '0');
	B    <= (OTHERS => '0');
	C    <= (OTHERS => '0');
END stub;
