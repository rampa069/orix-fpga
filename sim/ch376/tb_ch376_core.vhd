-- tb_ch376_core
-- Testbench of the emulated CH376 with its real firmware: the T65 runs
-- rtl/ch376_fw_rom.vhd, FatFs works on a FAT image served by a user_io model,
-- and the 6502 side replays the sequences of the Orix kernel CH376 library
-- (src/libs/ch376-lib/src/ch376.s). The image is written back at the end so
-- it can be checked with mtools.
--
-- Generics: IMAGE_IN (built by mkimage.sh), IMAGE_OUT, IMAGE_SIZE in bytes.
LIBRARY IEEE;
USE IEEE.STD_LOGIC_1164.ALL;
USE IEEE.NUMERIC_STD.ALL;
USE STD.ENV.ALL;

ENTITY tb_ch376_core IS
	GENERIC (
		IMAGE_IN   : STRING  := "fat.img";
		IMAGE_OUT  : STRING  := "fat_out.img";
		IMAGE_SIZE : INTEGER := 2097152
	);
END tb_ch376_core;

ARCHITECTURE sim OF tb_ch376_core IS
	SIGNAL clk    : STD_LOGIC := '0';
	SIGNAL resetn : STD_LOGIC := '0';
	SIGNAL ena    : STD_LOGIC := '0';
	SIGNAL csn    : STD_LOGIC := '1';
	SIGNAL a0     : STD_LOGIC := '0';
	SIGNAL rnw    : STD_LOGIC := '1';
	SIGNAL din    : STD_LOGIC_VECTOR(7 DOWNTO 0) := (OTHERS => '0');
	SIGNAL dout   : STD_LOGIC_VECTOR(7 DOWNTO 0);

	SIGNAL sd_lba       : STD_LOGIC_VECTOR(31 DOWNTO 0);
	SIGNAL sd_rd, sd_wr : STD_LOGIC;
	SIGNAL sd_ack       : STD_LOGIC := '0';
	SIGNAL sd_buff_addr : STD_LOGIC_VECTOR(8 DOWNTO 0) := (OTHERS => '0');
	SIGNAL sd_buff_dout : STD_LOGIC_VECTOR(7 DOWNTO 0) := (OTHERS => '0');
	SIGNAL sd_buff_wr   : STD_LOGIC := '0';
	SIGNAL sd_buff_din  : STD_LOGIC_VECTOR(7 DOWNTO 0);
	SIGNAL img_mounted  : STD_LOGIC := '0';
	SIGNAL img_size     : STD_LOGIC_VECTOR(31 DOWNTO 0) := (OTHERS => '0');

	SIGNAL errors   : INTEGER := 0;
	SIGNAL sd_reads, sd_writes : INTEGER := 0;
	SIGNAL dump_req : BOOLEAN := FALSE;
	SIGNAL dump_done: BOOLEAN := FALSE;

	CONSTANT DATA_PORT : STD_LOGIC := '0';
	CONSTANT CMD_PORT  : STD_LOGIC := '1';

	FUNCTION hex(v : STD_LOGIC_VECTOR(7 DOWNTO 0)) RETURN STRING IS
		CONSTANT d : STRING(1 TO 16) := "0123456789ABCDEF";
		VARIABLE r : STRING(1 TO 2);
	BEGIN
		r(1) := d(to_integer(unsigned(v(7 DOWNTO 4))) + 1);
		r(2) := d(to_integer(unsigned(v(3 DOWNTO 0))) + 1);
		RETURN r;
	END FUNCTION;
BEGIN
	clk <= NOT clk AFTER 20.833 ns;   -- 24 MHz

	PROCESS (clk)
		VARIABLE n : INTEGER := 0;
	BEGIN
		IF rising_edge(clk) THEN
			n := (n + 1) MOD 24;
			IF n = 23 THEN ena <= '1'; ELSE ena <= '0'; END IF;
		END IF;
	END PROCESS;

	dut : ENTITY work.ch376_core
		PORT MAP (
			CLK => clk, RESETn => resetn,
			ENA => ena, CSn => csn, A0 => a0, RnW => rnw, DIN => din, DOUT => dout,
			SD_LBA => sd_lba, SD_RD => sd_rd, SD_WR => sd_wr, SD_ACK => sd_ack,
			SD_BUFF_ADDR => sd_buff_addr, SD_BUFF_DOUT => sd_buff_dout, SD_BUFF_WR => sd_buff_wr,
			SD_BUFF_DIN => sd_buff_din, IMG_MOUNTED => img_mounted, IMG_SIZE => img_size);

	----------------------------------------------------------------------------
	-- user_io SD model: sectors of an image file held in memory
	----------------------------------------------------------------------------
	sd : PROCESS
		TYPE char_file IS FILE OF CHARACTER;
		TYPE image_t IS ARRAY(NATURAL RANGE <>) OF CHARACTER;
		TYPE image_ptr IS ACCESS image_t;
		VARIABLE image : image_ptr := NEW image_t(0 TO IMAGE_SIZE - 1);
		FILE fin  : char_file;
		FILE fout : char_file;
		VARIABLE c : CHARACTER;
		VARIABLE base : INTEGER;
	BEGIN
		file_open(fin, IMAGE_IN, READ_MODE);
		FOR i IN 0 TO IMAGE_SIZE - 1 LOOP
			read(fin, c);
			image(i) := c;
		END LOOP;
		file_close(fin);
		REPORT "image loaded: " & IMAGE_IN;

		WAIT UNTIL resetn = '1';
		WAIT FOR 5 us;
		-- the MiST firmware sends the size, then the mount strobe
		img_size <= std_logic_vector(to_unsigned(IMAGE_SIZE, 32));
		WAIT UNTIL rising_edge(clk);
		img_mounted <= '1';
		WAIT UNTIL rising_edge(clk);
		img_mounted <= '0';

		LOOP
			WAIT UNTIL rising_edge(clk) AND (sd_rd = '1' OR sd_wr = '1' OR dump_req);
			IF dump_req THEN
				file_open(fout, IMAGE_OUT, WRITE_MODE);
				FOR i IN 0 TO IMAGE_SIZE - 1 LOOP
					write(fout, image(i));
				END LOOP;
				file_close(fout);
				REPORT "image written: " & IMAGE_OUT;
				dump_done <= TRUE;
				WAIT;
			END IF;
			base := to_integer(unsigned(sd_lba)) * 512;
			-- the ARM takes a while to answer
			FOR i IN 1 TO 20 LOOP WAIT UNTIL rising_edge(clk); END LOOP;
			IF sd_rd = '1' THEN
				sd_ack <= '1';
				FOR i IN 0 TO 511 LOOP
					sd_buff_addr <= std_logic_vector(to_unsigned(i, 9));
					sd_buff_dout <= std_logic_vector(to_unsigned(character'pos(image(base + i)), 8));
					sd_buff_wr   <= '1';
					WAIT UNTIL rising_edge(clk);
					sd_buff_wr   <= '0';
					WAIT UNTIL rising_edge(clk);
				END LOOP;
				sd_reads <= sd_reads + 1;
			ELSE
				sd_ack <= '1';
				FOR i IN 0 TO 511 LOOP
					sd_buff_addr <= std_logic_vector(to_unsigned(i, 9));
					WAIT UNTIL rising_edge(clk);
					WAIT UNTIL rising_edge(clk);
					image(base + i) := character'val(to_integer(unsigned(sd_buff_din)));
				END LOOP;
				sd_writes <= sd_writes + 1;
			END IF;
			sd_buff_addr <= (OTHERS => '0');
			WAIT UNTIL rising_edge(clk);
			sd_ack <= '0';
		END LOOP;
	END PROCESS;

	----------------------------------------------------------------------------
	-- 6502 side
	----------------------------------------------------------------------------
	cpu : PROCESS
		PROCEDURE bus_write(port_sel : IN STD_LOGIC; v : IN INTEGER) IS
		BEGIN
			WAIT UNTIL rising_edge(clk) AND ena = '1';
			csn <= '0'; a0 <= port_sel; rnw <= '0'; din <= std_logic_vector(to_unsigned(v, 8));
			WAIT UNTIL rising_edge(clk) AND ena = '1';
			WAIT FOR 1 ns;
			csn <= '1'; rnw <= '1';
		END PROCEDURE;
		PROCEDURE bus_read(port_sel : IN STD_LOGIC; v : OUT STD_LOGIC_VECTOR(7 DOWNTO 0)) IS
		BEGIN
			WAIT UNTIL rising_edge(clk) AND ena = '1';
			csn <= '0'; a0 <= port_sel; rnw <= '1';
			WAIT UNTIL falling_edge(clk) AND ena = '1';
			v := dout;
			WAIT UNTIL rising_edge(clk);
			WAIT FOR 1 ns;
			csn <= '1';
		END PROCEDURE;
		PROCEDURE fail(what : IN STRING) IS
		BEGIN
			REPORT "FAIL " & what SEVERITY ERROR;
			errors <= errors + 1;
		END PROCEDURE;
		PROCEDURE expect(what : IN STRING; got : IN STD_LOGIC_VECTOR(7 DOWNTO 0); want : IN INTEGER) IS
		BEGIN
			IF to_integer(unsigned(got)) /= want THEN
				fail(what & ": got " & hex(got) & " want " & hex(std_logic_vector(to_unsigned(want, 8))));
			ELSE
				REPORT "ok   " & what & " = " & hex(got);
			END IF;
		END PROCEDURE;
		-- _ch376_wait_response gives up after 255 x 255 polls of 16 cycles at
		-- 1 MHz, about 1.04 s; this model polls faster, so the limit is a time
		PROCEDURE wait_response(status : OUT STD_LOGIC_VECTOR(7 DOWNTO 0)) IS
			VARIABLE v : STD_LOGIC_VECTOR(7 DOWNTO 0);
			VARIABLE t_start : TIME;
		BEGIN
			t_start := now;
			LOOP
				bus_read(CMD_PORT, v);
				EXIT WHEN v(7) = '0';
				IF now - t_start > 1040 ms THEN
					fail("wait_response timed out");
					EXIT;
				END IF;
			END LOOP;
			IF now - t_start > 100 ms THEN
				REPORT "slow command: " & time'image(now - t_start);
			END IF;
			bus_write(CMD_PORT, 16#22#);
			bus_read(DATA_PORT, status);
		END PROCEDURE;
		PROCEDURE set_name(s : IN STRING) IS
		BEGIN
			bus_write(CMD_PORT, 16#2F#);
			FOR i IN s'RANGE LOOP bus_write(DATA_PORT, character'pos(s(i))); END LOOP;
			bus_write(DATA_PORT, 0);
		END PROCEDURE;
		PROCEDURE open_file(s : IN STRING; status : OUT STD_LOGIC_VECTOR(7 DOWNTO 0)) IS
		BEGIN
			set_name(s);
			bus_write(CMD_PORT, 16#32#);
			wait_response(status);
		END PROCEDURE;
		PROCEDURE get_file_size(size : OUT INTEGER) IS
			VARIABLE v : STD_LOGIC_VECTOR(7 DOWNTO 0);
			VARIABLE s : INTEGER := 0;
		BEGIN
			bus_write(CMD_PORT, 16#0C#); bus_write(DATA_PORT, 16#68#);
			FOR i IN 0 TO 3 LOOP
				bus_read(DATA_PORT, v);
				IF i < 3 THEN s := s + to_integer(unsigned(v)) * 2 ** (8 * i); END IF;
			END LOOP;
			size := s;
		END PROCEDURE;
		-- reads n bytes as Orix xread does and checks them against byte(i) = (i * mul + add) mod 256
		PROCEDURE read_and_check(n, mul, add : IN INTEGER; what : IN STRING) IS
			VARIABLE v, st : STD_LOGIC_VECTOR(7 DOWNTO 0);
			VARIABLE total, count, bad : INTEGER := 0;
		BEGIN
			bus_write(CMD_PORT, 16#3A#); bus_write(DATA_PORT, n MOD 256); bus_write(DATA_PORT, n / 256);
			wait_response(st);
			WHILE st = x"1D" LOOP
				bus_write(CMD_PORT, 16#27#); bus_read(DATA_PORT, v);
				count := to_integer(unsigned(v));
				FOR i IN 0 TO count - 1 LOOP
					bus_read(DATA_PORT, v);
					IF to_integer(unsigned(v)) /= ((total + i) * mul + add) MOD 256 THEN
						bad := bad + 1;
					END IF;
				END LOOP;
				total := total + count;
				bus_write(CMD_PORT, 16#3B#); wait_response(st);
			END LOOP;
			IF st /= x"14" THEN fail(what & ": end status " & hex(st)); END IF;
			IF total /= n THEN fail(what & ": read " & integer'image(total) & " bytes, want " & integer'image(n)); END IF;
			IF bad /= 0 THEN fail(what & ": " & integer'image(bad) & " wrong bytes"); END IF;
			IF st = x"14" AND total = n AND bad = 0 THEN
				REPORT "ok   " & what & ": " & integer'image(total) & " bytes";
			END IF;
		END PROCEDURE;
		VARIABLE v, st : STD_LOGIC_VECTOR(7 DOWNTO 0);
		VARIABLE size, n, count : INTEGER;
		VARIABLE entry : STRING(1 TO 11);
		VARIABLE listing : STRING(1 TO 200);
		VARIABLE lpos : INTEGER;
		VARIABLE t0 : TIME;
	BEGIN
		WAIT FOR 1 us;
		resetn <= '1';
		WAIT FOR 50 us;

		bus_write(CMD_PORT, 16#06#); bus_write(DATA_PORT, 16#55#); bus_read(DATA_PORT, v);
		expect("CHECK_EXIST", v, 16#AA#);
		bus_write(CMD_PORT, 16#15#); bus_write(DATA_PORT, 16#03#); bus_read(DATA_PORT, v);
		expect("SET_USB_MODE SD", v, 16#51#);

		-- DISK_MOUNT
		t0 := now;
		bus_write(CMD_PORT, 16#31#); wait_response(st);
		expect("DISK_MOUNT", st, 16#14#);
		REPORT "DISK_MOUNT took " & time'image(now - t0);
		bus_write(CMD_PORT, 16#27#); bus_read(DATA_PORT, v);
		expect("mount info size", v, 36);
		FOR i IN 0 TO 15 LOOP bus_read(DATA_PORT, v); END LOOP;
		listing(1 TO 8) := (OTHERS => ' ');
		FOR i IN 1 TO 8 LOOP bus_read(DATA_PORT, v); listing(i) := character'val(to_integer(unsigned(v))); END LOOP;
		IF listing(1 TO 8) /= "CH376 EM" THEN fail("mount info product '" & listing(1 TO 8) & "'"); ELSE REPORT "ok   mount info product"; END IF;

		-- missing file
		open_file("/NOPE.BIN", st);
		expect("FILE_OPEN missing file", st, 16#42#);

		-- read TEST.BIN
		t0 := now;
		open_file("/TEST.BIN", st);
		expect("FILE_OPEN TEST.BIN", st, 16#14#);
		REPORT "FILE_OPEN took " & time'image(now - t0);
		get_file_size(size);
		IF size /= 600 THEN fail("file size " & integer'image(size)); ELSE REPORT "ok   file size 600"; END IF;
		t0 := now;
		read_and_check(600, 1, 0, "read TEST.BIN");
		REPORT "reading 600 bytes took " & time'image(now - t0);
		-- seek back to 300 and read the rest
		bus_write(CMD_PORT, 16#39#);
		bus_write(DATA_PORT, 300 MOD 256); bus_write(DATA_PORT, 300 / 256); bus_write(DATA_PORT, 0); bus_write(DATA_PORT, 0);
		wait_response(st);
		expect("BYTE_LOCATE 300", st, 16#14#);
		read_and_check(300, 1, 300, "read after seek");
		bus_write(CMD_PORT, 16#36#); bus_write(DATA_PORT, 0); wait_response(st);
		expect("FILE_CLOSE", st, 16#14#);

		-- directory listing of the root
		set_name("*"); bus_write(CMD_PORT, 16#32#); wait_response(st);
		lpos := 1;
		WHILE st = x"1D" LOOP
			bus_write(CMD_PORT, 16#27#); bus_read(DATA_PORT, v);
			count := to_integer(unsigned(v));
			FOR i IN 0 TO count - 1 LOOP
				bus_read(DATA_PORT, v);
				IF i < 11 THEN entry(i + 1) := character'val(to_integer(unsigned(v))); END IF;
			END LOOP;
			listing(lpos TO lpos + 11) := entry & "|";
			lpos := lpos + 12;
			bus_write(CMD_PORT, 16#33#); wait_response(st);
		END LOOP;
		expect("end of listing", st, 16#41#);
		REPORT "root listing: " & listing(1 TO lpos - 1);
		IF listing(1 TO lpos - 1) /= "TEST    BIN|README  TXT|ORIX       |" THEN fail("root listing"); END IF;

		-- enter ORIX/ and read INSIDE.TXT
		open_file("/ORIX", st);
		expect("FILE_OPEN directory", st, 16#41#);
		open_file("INSIDE.TXT", st);
		expect("FILE_OPEN INSIDE.TXT in ORIX", st, 16#14#);
		get_file_size(size);
		IF size /= 26 THEN fail("INSIDE.TXT size " & integer'image(size)); ELSE REPORT "ok   INSIDE.TXT size 26"; END IF;
		bus_write(CMD_PORT, 16#36#); bus_write(DATA_PORT, 0); wait_response(st);

		-- create /NEW.BIN with 700 bytes, byte i = (3 i + 7) mod 256, as Orix xwrite does
		open_file("/", st);
		set_name("NEW.BIN"); bus_write(CMD_PORT, 16#34#); wait_response(st);
		expect("FILE_CREATE", st, 16#14#);
		n := 700;
		bus_write(CMD_PORT, 16#3C#); bus_write(DATA_PORT, n MOD 256); bus_write(DATA_PORT, n / 256);
		wait_response(st);
		expect("BYTE_WRITE", st, 16#14#);
		size := 0;
		LOOP
			bus_write(CMD_PORT, 16#2D#); bus_read(DATA_PORT, v);
			count := to_integer(unsigned(v));
			FOR i IN 0 TO count - 1 LOOP
				bus_write(DATA_PORT, ((size + i) * 3 + 7) MOD 256);
			END LOOP;
			size := size + count;
			bus_write(CMD_PORT, 16#3D#); wait_response(st);
			EXIT WHEN st /= x"1E";
		END LOOP;
		expect("end of write", st, 16#14#);
		IF size /= 700 THEN fail("wrote " & integer'image(size) & " bytes"); END IF;
		bus_write(CMD_PORT, 16#36#); bus_write(DATA_PORT, 1); wait_response(st);
		expect("FILE_CLOSE after write", st, 16#14#);

		-- read it back
		open_file("/NEW.BIN", st);
		expect("FILE_OPEN NEW.BIN", st, 16#14#);
		get_file_size(size);
		IF size /= 700 THEN fail("NEW.BIN size " & integer'image(size)); ELSE REPORT "ok   NEW.BIN size 700"; END IF;
		read_and_check(700, 3, 7, "read back NEW.BIN");
		bus_write(CMD_PORT, 16#36#); bus_write(DATA_PORT, 0); wait_response(st);

		-- make a directory and erase README.TXT
		set_name("/NEWDIR"); bus_write(CMD_PORT, 16#40#); wait_response(st);
		expect("DIR_CREATE NEWDIR", st, 16#14#);
		set_name("/README.TXT"); bus_write(CMD_PORT, 16#35#); wait_response(st);
		expect("FILE_ERASE README.TXT", st, 16#14#);

		-- disk query
		t0 := now;
		bus_write(CMD_PORT, 16#3F#); wait_response(st);
		expect("DISK_QUERY", st, 16#14#);
		REPORT "DISK_QUERY took " & time'image(now - t0);
		bus_write(CMD_PORT, 16#27#); bus_read(DATA_PORT, v);
		expect("DISK_QUERY size", v, 9);
		size := 0;
		FOR i IN 0 TO 8 LOOP
			bus_read(DATA_PORT, v);
			IF i >= 4 AND i < 7 THEN size := size + to_integer(unsigned(v)) * 2 ** (8 * (i - 4)); END IF;
		END LOOP;
		REPORT "free sectors: " & integer'image(size);

		REPORT "SD sectors read: " & integer'image(sd_reads) & ", written: " & integer'image(sd_writes);
		dump_req <= TRUE;
		WAIT UNTIL dump_done;
		IF errors = 0 THEN
			REPORT "ALL TESTS PASSED";
		ELSE
			REPORT integer'image(errors) & " ERRORS" SEVERITY ERROR;
		END IF;
		stop;
	END PROCESS;
END sim;
