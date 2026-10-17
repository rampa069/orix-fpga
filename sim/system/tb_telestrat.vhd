-- tb_telestrat
-- Whole machine simulation of rtl/telestrat.vhd: the main 64 KB RAM as in
-- TeleStrat.sv, the cartridge/Twilighte memory (SDRAM in the core) as a 1 MB
-- array loaded with a cartridge image, no keys, no sound, no SD image.
-- Every instruction fetch is written to TRACE as "count pc opcode bank irq",
-- which allows comparing the 6502 (MODE "00") and the 65C816 (MODE "10")
-- running the same code.
LIBRARY IEEE;
USE IEEE.STD_LOGIC_1164.ALL;
USE IEEE.NUMERIC_STD.ALL;
USE STD.TEXTIO.ALL;
USE STD.ENV.ALL;

ENTITY tb_telestrat IS
	GENERIC (
		CART         : STRING  := "ORIX.ROM";
		CART_SIZE    : INTEGER := 114688;
		TRACE        : STRING  := "trace.txt";
		MODE         : STRING  := "00";       -- "00" 6502, "01" 65C02, "10" 65C816
		MAX_FETCHES  : INTEGER := 2000000;
		SIM_TIME_MS  : INTEGER := 2000
	);
END tb_telestrat;

ARCHITECTURE sim OF tb_telestrat IS
	SIGNAL clk      : STD_LOGIC := '0';
	SIGNAL clk_acia : STD_LOGIC := '0';
	SIGNAL reset    : STD_LOGIC := '0';
	SIGNAL locked   : STD_LOGIC := '0';
	SIGNAL cpu_mode : STD_LOGIC_VECTOR(1 DOWNTO 0);

	SIGNAL ram_ad   : STD_LOGIC_VECTOR(15 DOWNTO 0);
	SIGNAL ram_d    : STD_LOGIC_VECTOR(7 DOWNTO 0);
	SIGNAL ram_q    : STD_LOGIC_VECTOR(7 DOWNTO 0) := (OTHERS => '0');
	SIGNAL ram_cs, ram_oe, ram_we : STD_LOGIC;
	SIGNAL rom_ad   : STD_LOGIC_VECTOR(19 DOWNTO 0);
	SIGNAL rom_d    : STD_LOGIC_VECTOR(7 DOWNTO 0) := (OTHERS => '0');
	SIGNAL rom_q    : STD_LOGIC_VECTOR(7 DOWNTO 0);
	SIGNAL rom_rd, rom_wr, ram_sel : STD_LOGIC;
	SIGNAL cpu_ad   : STD_LOGIC_VECTOR(23 DOWNTO 0);
	SIGNAL cpu_do   : STD_LOGIC_VECTOR(7 DOWNTO 0);
	SIGNAL ch_d     : STD_LOGIC_VECTOR(7 DOWNTO 0);
	SIGNAL vr, vg, vb, vhs, vvs, vvb, vhb, vclk : STD_LOGIC;
BEGIN
	clk      <= NOT clk AFTER 20.833 ns;    -- 24 MHz
	clk_acia <= NOT clk_acia AFTER 271 ns;  -- about 1.8432 MHz
	cpu_mode(1) <= '1' WHEN MODE(1) = '1' ELSE '0';
	cpu_mode(0) <= '1' WHEN MODE(2) = '1' ELSE '0';

	-- HCS3119 only asserts the CPU reset on a falling edge of its reset input
	-- sampled on PH2 (in the FPGA its register powers up at 0 instead), so
	-- give it a full low-high-low pulse once the ULA runs
	PROCESS
	BEGIN
		WAIT FOR 200 ns;
		locked <= '1';
		WAIT FOR 5 us;
		reset <= '1';
		WAIT FOR 10 us;
		reset <= '0';
		WAIT;
	END PROCESS;

	dut : ENTITY work.telestrat
		GENERIC MAP (CH376_BACKEND => 1)
		PORT MAP (
			CLK_IN => clk, CLK_ACIA => clk_acia, RESET => reset,
			key_pressed => '0', key_extended => '0', key_code => x"00", key_strobe => '0',
			K7_TAPEIN => '0', K7_TAPEOUT => OPEN, K7_REMOTE => OPEN,
			RTC => (OTHERS => '0'),
			PSG_OUT => OPEN, PSG_OUT_A => OPEN, PSG_OUT_B => OPEN, PSG_OUT_C => OPEN,
			VIDEO_R => vr, VIDEO_G => vg, VIDEO_B => vb, VIDEO_HSYNC => vhs, VIDEO_VSYNC => vvs,
			VIDEO_VBLANK => vvb, VIDEO_HBLANK => vhb, VIDEO_CLK => vclk,
			ram_ad => ram_ad, ram_d => ram_d, ram_q => ram_q, ram_cs => ram_cs, ram_oe => ram_oe, ram_we => ram_we,
			rom_ad => rom_ad, rom_d => rom_d, rom_q => rom_q, rom_rd => rom_rd, rom_wr => rom_wr, ram_sel => ram_sel,
			mode => cpu_mode, debug => OPEN,
			cpu_ad => cpu_ad, cpu_do => cpu_do,
			WD_REn => OPEN, WD_WEn => OPEN, WD_DRQ => '0', WD_IRQ => '0', WD_HLD => '0', WD_CLK => OPEN,
			FDC_DAL_OUT => x"00", CS1793n => OPEN, SSEL => OPEN, DS0 => OPEN, DS1 => OPEN, DS2 => OPEN, DS3 => OPEN,
			WD_RESET => OPEN,
			CH_D => ch_d, CH_A0 => OPEN, CH_RD => OPEN, CH_WR => OPEN, CH_CS => OPEN,
			SD_LBA => OPEN, SD_RD => OPEN, SD_WR => OPEN, SD_ACK => '0',
			SD_BUFF_ADDR => (OTHERS => '0'), SD_BUFF_DOUT => x"00", SD_BUFF_WR => '0', SD_BUFF_DIN => OPEN,
			IMG_MOUNTED => '0', IMG_SIZE => (OTHERS => '0'),
			phi2 => OPEN, fdd_ready => '0',
			joystick_0 => "00000", joystick_1 => "00000", fire2_t1 => '0', fire3_t1 => '0',
			pll_locked => locked, disk_enable => '0',
			uart_txd => OPEN, uart_rxd => '1', uart_rts => OPEN, uart_cts => '0'
		);

	-- ULA view of the main RAM (the video shadow of TeleStrat.sv, here the
	-- whole 64 KB, which reads the same for every address the ULA generates)
	main_ram : PROCESS (clk)
		TYPE ram_t IS ARRAY(0 TO 65535) OF STD_LOGIC_VECTOR(7 DOWNTO 0);
		VARIABLE m : ram_t := (OTHERS => x"00");
	BEGIN
		IF rising_edge(clk) THEN
			IF ram_we = '1' AND ram_cs = '1' THEN
				m(to_integer(unsigned(ram_ad))) := ram_d;
			END IF;
			ram_q <= m(to_integer(unsigned(ram_ad)));
		END IF;
	END PROCESS;

	-- SDRAM as in TeleStrat.sv: cartridge ROM in the low 512 KB, board RAM in
	-- the high 512 KB (rom_ad(19)) and the CPU main RAM at 0x100000 (ram_sel),
	-- written on the rising edge of rom_wr as the controller does. The read
	-- data is delayed by RD_DELAY clk_sys, longer than the worst controller
	-- latency (about 160 ns with a refresh in front), to check that the CPU
	-- only takes it at the end of PHI2.
	cart_mem : PROCESS (clk)
		CONSTANT RD_DELAY : NATURAL := 5;
		TYPE mem_t IS ARRAY(0 TO 16#10FFFF#) OF STD_LOGIC_VECTOR(7 DOWNTO 0);
		TYPE mem_ptr IS ACCESS mem_t;
		TYPE char_file IS FILE OF CHARACTER;
		TYPE pipe_t IS ARRAY(1 TO RD_DELAY) OF STD_LOGIC_VECTOR(7 DOWNTO 0);
		VARIABLE m : mem_ptr := NULL;
		FILE f : char_file;
		VARIABLE c : CHARACTER;
		VARIABLE wr_d : STD_LOGIC := '0';
		VARIABLE a : NATURAL;
		VARIABLE pipe : pipe_t := (OTHERS => x"FF");
	BEGIN
		IF m = NULL THEN
			m := NEW mem_t'(OTHERS => x"FF");
			FOR i IN 16#100000# TO 16#10FFFF# LOOP
				m(i) := x"00";               -- cleared after power up
			END LOOP;
			file_open(f, CART, READ_MODE);
			FOR i IN 0 TO CART_SIZE - 1 LOOP
				read(f, c);
				m(i) := std_logic_vector(to_unsigned(character'pos(c), 8));
			END LOOP;
			file_close(f);
			REPORT "cartridge loaded: " & CART;
		END IF;
		IF rising_edge(clk) THEN
			IF ram_sel = '1' THEN
				a := 16#100000# + to_integer(unsigned(cpu_ad(15 DOWNTO 0)));
			ELSE
				a := to_integer(unsigned(rom_ad));
			END IF;
			IF rom_wr = '1' AND wr_d = '0' AND (rom_ad(19) = '1' OR ram_sel = '1') THEN
				m(a) := rom_q;
			END IF;
			wr_d := rom_wr;
			pipe := m(a) & pipe(1 TO RD_DELAY - 1);
			rom_d <= pipe(RD_DELAY);
		END IF;
	END PROCESS;

	-- every video read of the ULA must hit the block RAM shadow of TeleStrat.sv
	-- (0x9800-0xC3FF): the ULA takes the data on c(2), c(3) and c(10)
	shadow_chk : PROCESS (clk)
		ALIAS c IS <<SIGNAL .tb_telestrat.dut.HCS10017.c : STD_LOGIC_VECTOR(23 DOWNTO 0)>>;
		VARIABLE n : NATURAL := 0;
		VARIABLE a : NATURAL;
	BEGIN
		IF rising_edge(clk) AND (c(2) = '1' OR c(3) = '1' OR c(10) = '1') AND NOT is_x(ram_ad) THEN
			a := to_integer(unsigned(ram_ad));
			IF (a < 16#9800# OR a > 16#C3FF#) AND n < 10 THEN
				n := n + 1;
				REPORT "ULA video read outside the shadow at " & to_hstring(ram_ad) SEVERITY ERROR;
			END IF;
		END IF;
	END PROCESS;

	-- instruction trace
	trace_p : PROCESS (clk)
		ALIAS ena    IS <<SIGNAL .tb_telestrat.dut.ENA_1MHZ_N : STD_LOGIC>>;
		ALIAS cpu_di IS <<SIGNAL .tb_telestrat.dut.cpu_di : STD_LOGIC_VECTOR(7 DOWNTO 0)>>;
		ALIAS bank   IS <<SIGNAL .tb_telestrat.dut.BANK : STD_LOGIC_VECTOR(4 DOWNTO 0)>>;
		ALIAS irq_n  IS <<SIGNAL .tb_telestrat.dut.cpu_irq : STD_LOGIC>>;
		ALIAS t65_mc IS <<SIGNAL .tb_telestrat.dut.inst_cpu1.MCycle : STD_LOGIC_VECTOR(2 DOWNTO 0)>>;
		ALIAS c816_vda IS <<SIGNAL .tb_telestrat.dut.inst_cpu2.VDA : STD_LOGIC>>;
		ALIAS c816_vpa IS <<SIGNAL .tb_telestrat.dut.inst_cpu2.VPA : STD_LOGIC>>;
		FILE tf : TEXT OPEN WRITE_MODE IS TRACE;
		VARIABLE l : LINE;
		VARIABLE n : INTEGER := 0;
		VARIABLE fetch : BOOLEAN;
		FUNCTION hx(v : STD_LOGIC_VECTOR) RETURN STRING IS
			CONSTANT d : STRING(1 TO 16) := "0123456789ABCDEF";
			VARIABLE r : STRING(1 TO v'LENGTH / 4);
			VARIABLE x : STD_LOGIC_VECTOR(v'LENGTH - 1 DOWNTO 0) := v;
		BEGIN
			FOR i IN r'RANGE LOOP
				IF is_x(x(x'LENGTH - 4 * (i - 1) - 1 DOWNTO x'LENGTH - 4 * i)) THEN
					r(i) := 'X';
				ELSE
					r(i) := d(to_integer(unsigned(x(x'LENGTH - 4 * (i - 1) - 1 DOWNTO x'LENGTH - 4 * i))) + 1);
				END IF;
			END LOOP;
			RETURN r;
		END FUNCTION;
	BEGIN
		IF rising_edge(clk) AND ena = '1' AND reset = '0' THEN
			IF cpu_mode = "10" THEN
				fetch := c816_vda = '1' AND c816_vpa = '1';
			ELSE
				fetch := t65_mc = "000";
			END IF;
			IF fetch THEN
				n := n + 1;
				write(l, integer'image(n) & " " & hx(cpu_ad(15 DOWNTO 0)) & " " & hx(cpu_di) & " " &
				         hx("000" & bank) & " " & STD_LOGIC'image(irq_n)(2));
				writeline(tf, l);
				IF n = MAX_FETCHES THEN
					REPORT "trace complete: " & integer'image(n) & " fetches";
					stop;
				END IF;
			END IF;
		END IF;
	END PROCESS;


	-- temporary monitor
	mon_p : PROCESS
		ALIAS rstn   IS <<SIGNAL .tb_telestrat.dut.RESETn : STD_LOGIC>>;
		ALIAS t65_mc IS <<SIGNAL .tb_telestrat.dut.inst_cpu1.MCycle : STD_LOGIC_VECTOR(2 DOWNTO 0)>>;
		ALIAS ena    IS <<SIGNAL .tb_telestrat.dut.ENA_1MHZ_N : STD_LOGIC>>;
		ALIAS phi2   IS <<SIGNAL .tb_telestrat.dut.ula_phi2 : STD_LOGIC>>;
	BEGIN
		FOR i IN 1 TO 5 LOOP
			WAIT FOR 1 ms;
			REPORT "mon: RESETn=" & STD_LOGIC'image(rstn) & " MCycle=" & to_string(t65_mc) &
			       " ena=" & STD_LOGIC'image(ena) & " phi2=" & STD_LOGIC'image(phi2) & " a=" & to_hstring(cpu_ad);
		END LOOP;
		WAIT;
	END PROCESS;

	PROCESS
	BEGIN
		WAIT FOR SIM_TIME_MS * 1 ms;
		REPORT "time limit";
		stop;
	END PROCESS;
END sim;
