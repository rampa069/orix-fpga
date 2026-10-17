-- Testbench for ch376_host: the 6502 side replays the sequences of the Orix
-- kernel CH376 library (src/libs/ch376-lib/src/ch376.s), the firmware side is
-- a behavioural model answering requests after a delay.
LIBRARY IEEE;
USE IEEE.STD_LOGIC_1164.ALL;
USE IEEE.NUMERIC_STD.ALL;
USE STD.ENV.ALL;

ENTITY tb_ch376_host IS
END tb_ch376_host;

ARCHITECTURE sim OF tb_ch376_host IS
	SIGNAL clk    : STD_LOGIC := '0';
	SIGNAL resetn : STD_LOGIC := '0';
	SIGNAL ena    : STD_LOGIC := '0';
	SIGNAL csn    : STD_LOGIC := '1';
	SIGNAL a0     : STD_LOGIC := '0';
	SIGNAL rnw    : STD_LOGIC := '1';
	SIGNAL din    : STD_LOGIC_VECTOR(7 DOWNTO 0) := (OTHERS => '0');
	SIGNAL dout   : STD_LOGIC_VECTOR(7 DOWNTO 0);
	SIGNAL f_addr : STD_LOGIC_VECTOR(8 DOWNTO 0) := (OTHERS => '0');
	SIGNAL f_we   : STD_LOGIC := '0';
	SIGNAL f_din  : STD_LOGIC_VECTOR(7 DOWNTO 0) := (OTHERS => '0');
	SIGNAL f_dout : STD_LOGIC_VECTOR(7 DOWNTO 0);
	SIGNAL errors : INTEGER := 0;
	SIGNAL cycle  : INTEGER := 0;

	CONSTANT DATA_PORT : STD_LOGIC := '0';
	CONSTANT CMD_PORT  : STD_LOGIC := '1';

	FUNCTION hex(v : STD_LOGIC_VECTOR) RETURN STRING IS
		CONSTANT d : STRING(1 TO 16) := "0123456789ABCDEF";
		VARIABLE r : STRING(1 TO 2);
	BEGIN
		r(1) := d(to_integer(unsigned(v(7 DOWNTO 4))) + 1);
		r(2) := d(to_integer(unsigned(v(3 DOWNTO 0))) + 1);
		RETURN r;
	END FUNCTION;
BEGIN
	clk <= NOT clk AFTER 20.833 ns;   -- 24 MHz

	-- ENA every 24 clocks, as ENA_1MHZ_N
	PROCESS (clk)
		VARIABLE n : INTEGER := 0;
	BEGIN
		IF rising_edge(clk) THEN
			n := (n + 1) MOD 24;
			IF n = 23 THEN ena <= '1'; ELSE ena <= '0'; END IF;
			IF n = 23 THEN cycle <= cycle + 1; END IF;
		END IF;
	END PROCESS;

	dut : ENTITY work.ch376_host
		PORT MAP (CLK => clk, RESETn => resetn, ENA => ena, CSn => csn, A0 => a0, RnW => rnw,
		          DIN => din, DOUT => dout, F_ADDR => f_addr, F_WE => f_we, F_DIN => f_din, F_DOUT => f_dout);

	----------------------------------------------------------------------------
	-- Firmware model
	----------------------------------------------------------------------------
	fw : PROCESS
		PROCEDURE fread(a : IN INTEGER; v : OUT STD_LOGIC_VECTOR(7 DOWNTO 0)) IS
		BEGIN
			f_addr <= std_logic_vector(to_unsigned(a, 9)); f_we <= '0';
			WAIT UNTIL rising_edge(clk); WAIT UNTIL rising_edge(clk);
			v := f_dout;
		END PROCEDURE;
		PROCEDURE fwrite(a : IN INTEGER; v : IN INTEGER) IS
		BEGIN
			f_addr <= std_logic_vector(to_unsigned(a, 9)); f_din <= std_logic_vector(to_unsigned(v, 8)); f_we <= '1';
			WAIT UNTIL rising_edge(clk);
			f_we <= '0';
		END PROCEDURE;
		VARIABLE flags, cmd, p, b : STD_LOGIC_VECTOR(7 DOWNTO 0);
		VARIABLE name : STRING(1 TO 14);
		VARIABLE len, remaining : INTEGER;
		VARIABLE file_pos : INTEGER := 0;
		CONSTANT FILE_LEN : INTEGER := 600;
	BEGIN
		WAIT UNTIL resetn = '1';
		LOOP
			fread(16#101#, flags);
			IF flags(1) = '1' THEN
				REPORT "firmware: cancel I/O";
				fwrite(16#107#, 2);
			END IF;
			IF flags(0) = '1' THEN
				fread(16#100#, cmd);
				-- work takes time: INT# must stay high meanwhile
				WAIT FOR 200 us;
				CASE cmd IS
					WHEN x"31" =>               -- DISK_MOUNT
						FOR i IN 0 TO 35 LOOP fwrite(i, 65 + (i MOD 26)); END LOOP;
						fwrite(16#103#, 36); fwrite(16#105#, 127); fwrite(16#104#, 16#14#);
					WHEN x"32" =>               -- FILE_OPEN: the name was left in the buffer
						fread(16#102#, p); len := to_integer(unsigned(p));
						FOR i IN 0 TO len - 1 LOOP
							fread(i, b);
							IF b = x"00" THEN len := i; EXIT; END IF;   -- name ends at the first NUL
							name(i + 1) := character'val(to_integer(unsigned(b)));
						END LOOP;
						REPORT "firmware: FILE_OPEN name '" & name(1 TO len) & "'";
						IF name(1 TO len) = "/TEST.BIN" THEN
							fwrite(16#108#, FILE_LEN MOD 256); fwrite(16#109#, FILE_LEN / 256);
							fwrite(16#10A#, 0); fwrite(16#10B#, 0);
							file_pos := 0;
							fwrite(16#105#, 127); fwrite(16#104#, 16#14#);
						ELSE
							fwrite(16#105#, 0); fwrite(16#104#, 16#42#);
						END IF;
					WHEN x"3A" | x"3B" =>       -- BYTE_READ, BYTE_RD_GO
						IF cmd = x"3A" THEN
							fread(0, b); remaining := to_integer(unsigned(b));
							fread(1, b); remaining := remaining + 256 * to_integer(unsigned(b));
						END IF;
						len := remaining;
						IF len > 255 THEN len := 255; END IF;
						IF len > FILE_LEN - file_pos THEN len := FILE_LEN - file_pos; END IF;
						FOR i IN 0 TO len - 1 LOOP fwrite(i, (file_pos + i) MOD 256); END LOOP;
						file_pos := file_pos + len; remaining := remaining - len;
						fwrite(16#10C#, file_pos MOD 256); fwrite(16#10D#, file_pos / 256);
						fwrite(16#103#, len); fwrite(16#105#, 127);
						IF len = 0 THEN fwrite(16#104#, 16#14#); ELSE fwrite(16#104#, 16#1D#); END IF;
					WHEN x"36" =>               -- FILE_CLOSE
						fwrite(16#105#, 127); fwrite(16#104#, 16#14#);
					WHEN OTHERS =>
						fwrite(16#105#, 0); fwrite(16#104#, 16#5F#);
				END CASE;
				fwrite(16#107#, 1);         -- done
			END IF;
		END LOOP;
	END PROCESS;

	----------------------------------------------------------------------------
	-- 6502 side
	----------------------------------------------------------------------------
	cpu : PROCESS
		PROCEDURE bus_write(port_sel : IN STD_LOGIC; v : IN INTEGER) IS
		BEGIN
			WAIT UNTIL rising_edge(clk) AND ena = '1';     -- previous cycle ends
			csn <= '0'; a0 <= port_sel; rnw <= '0'; din <= std_logic_vector(to_unsigned(v, 8));
			WAIT UNTIL rising_edge(clk) AND ena = '1';     -- this cycle ends, write committed
			WAIT FOR 1 ns;
			csn <= '1'; rnw <= '1';
		END PROCEDURE;
		PROCEDURE bus_read(port_sel : IN STD_LOGIC; v : OUT STD_LOGIC_VECTOR(7 DOWNTO 0)) IS
		BEGIN
			WAIT UNTIL rising_edge(clk) AND ena = '1';
			csn <= '0'; a0 <= port_sel; rnw <= '1';
			WAIT UNTIL falling_edge(clk) AND ena = '1';     -- sampled at the end of the cycle
			v := dout;
			WAIT UNTIL rising_edge(clk);
			WAIT FOR 1 ns;
			csn <= '1';
		END PROCEDURE;
		PROCEDURE expect(what : IN STRING; got : IN STD_LOGIC_VECTOR(7 DOWNTO 0); want : IN INTEGER) IS
		BEGIN
			IF to_integer(unsigned(got)) /= want THEN
				REPORT "FAIL " & what & ": got " & hex(got) & " want " & hex(std_logic_vector(to_unsigned(want, 8))) SEVERITY ERROR;
				errors <= errors + 1;
			ELSE
				REPORT "ok   " & what & " = " & hex(got);
			END IF;
		END PROCEDURE;
		-- _ch376_wait_response: poll bit 7 of the command port, then GET_STATUS
		PROCEDURE wait_response(status : OUT STD_LOGIC_VECTOR(7 DOWNTO 0); polls : OUT INTEGER) IS
			VARIABLE v : STD_LOGIC_VECTOR(7 DOWNTO 0);
			VARIABLE n : INTEGER := 0;
		BEGIN
			LOOP
				bus_read(CMD_PORT, v);
				n := n + 1;
				EXIT WHEN v(7) = '0';
				IF n > 65025 THEN
					REPORT "FAIL wait_response timed out" SEVERITY ERROR;
					EXIT;
				END IF;
			END LOOP;
			bus_write(CMD_PORT, 16#22#);
			bus_read(DATA_PORT, status);
			polls := n;
		END PROCEDURE;
		PROCEDURE set_name(s : IN STRING) IS
		BEGIN
			bus_write(CMD_PORT, 16#2F#);
			FOR i IN s'RANGE LOOP bus_write(DATA_PORT, character'pos(s(i))); END LOOP;
			bus_write(DATA_PORT, 0);
		END PROCEDURE;
		VARIABLE v, st : STD_LOGIC_VECTOR(7 DOWNTO 0);
		VARIABLE polls, n, total, expected : INTEGER;
	BEGIN
		WAIT FOR 1 us;
		resetn <= '1';
		WAIT FOR 2 us;

		-- _ch376_check_exist
		bus_write(CMD_PORT, 16#06#); bus_write(DATA_PORT, 16#55#); bus_read(DATA_PORT, v);
		expect("CHECK_EXIST", v, 16#AA#);
		-- _ch376_ic_get_ver
		bus_write(CMD_PORT, 16#01#); bus_read(DATA_PORT, v);
		expect("GET_IC_VER", v, 16#43#);
		-- _ch376_set_usb_mode (SD card), then read the answer
		bus_write(CMD_PORT, 16#15#); bus_write(DATA_PORT, 16#03#); bus_read(DATA_PORT, v);
		expect("SET_USB_MODE", v, 16#51#);
		-- _ch376_disk_mount
		bus_write(CMD_PORT, 16#31#);
		bus_read(CMD_PORT, v);
		expect("INT# high while busy", v AND x"80", 16#80#);
		wait_response(st, polls);
		expect("DISK_MOUNT status", st, 16#14#);
		REPORT "DISK_MOUNT answered after " & integer'image(polls) & " polls";
		-- read mount info with RD_USB_DATA0: size first
		bus_write(CMD_PORT, 16#27#); bus_read(DATA_PORT, v);
		expect("mount info size", v, 36);
		bus_read(DATA_PORT, v); expect("mount info byte 0", v, 65);
		-- open a missing file
		set_name("/NOPE.BIN");
		bus_write(CMD_PORT, 16#32#); wait_response(st, polls);
		expect("FILE_OPEN missing", st, 16#42#);
		-- open the test file
		set_name("/TEST.BIN");
		bus_write(CMD_PORT, 16#32#); wait_response(st, polls);
		expect("FILE_OPEN", st, 16#14#);
		-- _ch376_get_file_size: no wait between the 0x68 and the reads
		bus_write(CMD_PORT, 16#0C#); bus_write(DATA_PORT, 16#68#);
		bus_read(DATA_PORT, v); expect("file size byte 0", v, 600 MOD 256);
		bus_read(DATA_PORT, v); expect("file size byte 1", v, 600 / 256);
		bus_read(DATA_PORT, v); expect("file size byte 2", v, 0);
		bus_read(DATA_PORT, v); expect("file size byte 3", v, 0);
		-- read the whole file as Orix xread does: BYTE_READ, then RD_USB_DATA0 + BYTE_RD_GO
		bus_write(CMD_PORT, 16#3A#); bus_write(DATA_PORT, 600 MOD 256); bus_write(DATA_PORT, 600 / 256);
		wait_response(st, polls);
		total := 0;
		WHILE st = x"1D" LOOP
			bus_write(CMD_PORT, 16#27#); bus_read(DATA_PORT, v);
			n := to_integer(unsigned(v));
			FOR i IN 0 TO n - 1 LOOP
				bus_read(DATA_PORT, v);
				expected := (total + i) MOD 256;
				IF to_integer(unsigned(v)) /= expected THEN
					REPORT "FAIL data byte " & integer'image(total + i) & " got " & hex(v) SEVERITY ERROR;
					errors <= errors + 1;
				END IF;
			END LOOP;
			total := total + n;
			bus_write(CMD_PORT, 16#3B#); wait_response(st, polls);
		END LOOP;
		expect("end of read status", st, 16#14#);
		REPORT "read " & integer'image(total) & " bytes";
		IF total /= 600 THEN REPORT "FAIL byte count" SEVERITY ERROR; errors <= errors + 1; END IF;
		-- current offset through READ_VAR32 0x6C
		bus_write(CMD_PORT, 16#0C#); bus_write(DATA_PORT, 16#6C#);
		bus_read(DATA_PORT, v); expect("offset byte 0", v, 600 MOD 256);
		bus_read(DATA_PORT, v); expect("offset byte 1", v, 600 / 256);
		-- _ch376_file_close
		bus_write(CMD_PORT, 16#36#); bus_write(DATA_PORT, 1); wait_response(st, polls);
		expect("FILE_CLOSE", st, 16#14#);
		-- check byte through the command port quirk
		bus_write(CMD_PORT, 16#06#); bus_write(CMD_PORT, 16#33#);
		bus_write(CMD_PORT, 16#06#); bus_read(DATA_PORT, v);
		expect("CHECK_EXIST quirk", v, 16#CC#);
		-- unsupported command (RESET_ALL) gives ABORT status
		bus_write(CMD_PORT, 16#05#); bus_write(CMD_PORT, 16#22#); bus_read(DATA_PORT, v);
		expect("unsupported command status", v, 16#5F#);

		WAIT FOR 10 us;
		IF errors = 0 THEN
			REPORT "ALL TESTS PASSED";
		ELSE
			REPORT integer'image(errors) & " ERRORS" SEVERITY ERROR;
		END IF;
		stop;
	END PROCESS;
END sim;
