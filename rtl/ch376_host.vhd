-- ch376_host
-- CH376 host interface for the emulated CH376 of the Twilighte board.
-- Copyright 2026 rampa
--
-- This is free software: you can redistribute it and/or modify
-- it under the terms of the GNU General Public License as published by
-- the Free Software Foundation, either version 3 of the License,
-- or any later version.
--
-- The 6502 sees the CH376 parallel interface at 0x340 (data) and 0x341
-- (command). This module answers every 6502 access by itself, so the timing
-- the Orix routines rely on is met:
--  - reading 0x341 returns the interface status with bit 7 standing for the
--    INT# pin: 1 while the firmware is working, 0 once the result is ready
--    (_ch376_wait_response in the Orix kernel polls this bit);
--  - the byte level behaviour of 0x340 (file name, buffer reads and writes,
--    command arguments) and the commands that need no file system
--    (CHECK_EXIST, GET_IC_VER, SET_USB_MODE, GET_STATUS, READ_VAR32) are
--    handled here, since some routines read the answer one instruction after
--    sending the command.
-- Commands that need the file system raise a request to the firmware of the
-- CH376 softcore through the second port, keep INT# high until the firmware
-- signals completion, and exchange data through a shared 256 byte buffer.
--
-- The behaviour follows the protocol layer of the Oricutron CH376 emulation
-- (plugins/ch376/ch376.c), including the quirks it reproduces from the real
-- chip: the check byte of CHECK_EXIST is also taken from the command port,
-- and a data read during an unexpected command returns the first buffer byte.
-- Deviation: the READ_VAR32 result is held in its own registers instead of
-- overlapping the start of the buffer, which only changes what such an
-- unexpected read returns right after READ_VAR32.
--
-- Firmware port map (f_addr):
--   0x000-0x0FF  shared buffer
--   0x100  R    command
--   0x101  R    flags: bit 0 request pending, bit 1 cancel I/O pending,
--               bit 7 busy (INT# high)
--   0x102  R/W  buffer position (pos)
--   0x103  R/W  bytes in buffer (count)
--   0x104  R/W  command status (returned by GET_STATUS)
--   0x105  R/W  interface status (returned on 0x341, bits 6..0)
--   0x106  R    USB mode
--   0x107  W    control: bit 0 done (clears request and busy),
--               bit 1 clear cancel I/O
--   0x108-0x10B R/W file size, little endian (READ_VAR32 0x68)
--   0x10C-0x10F R/W file offset, little endian (READ_VAR32 0x6C)

LIBRARY IEEE;
USE IEEE.STD_LOGIC_1164.ALL;
USE IEEE.NUMERIC_STD.ALL;

ENTITY ch376_host IS
	PORT (
		CLK      : IN  STD_LOGIC;
		RESETn   : IN  STD_LOGIC;

		-- 6502 side
		ENA      : IN  STD_LOGIC;                      -- end of the CPU cycle (ENA_1MHZ_N)
		CSn      : IN  STD_LOGIC;                      -- 0x340-0x341
		A0       : IN  STD_LOGIC;                      -- 0 = data, 1 = command
		RnW      : IN  STD_LOGIC;
		DIN      : IN  STD_LOGIC_VECTOR(7 DOWNTO 0);
		DOUT     : OUT STD_LOGIC_VECTOR(7 DOWNTO 0);

		-- firmware side
		F_ADDR   : IN  STD_LOGIC_VECTOR(8 DOWNTO 0);
		F_WE     : IN  STD_LOGIC;
		F_DIN    : IN  STD_LOGIC_VECTOR(7 DOWNTO 0);
		F_DOUT   : OUT STD_LOGIC_VECTOR(7 DOWNTO 0)
	);
END ch376_host;

ARCHITECTURE rtl OF ch376_host IS

	-- Commands (Oricutron ch376.c)
	CONSTANT CMD_NONE          : STD_LOGIC_VECTOR(7 DOWNTO 0) := x"00";
	CONSTANT CMD_GET_IC_VER    : STD_LOGIC_VECTOR(7 DOWNTO 0) := x"01";
	CONSTANT CMD_CHECK_EXIST   : STD_LOGIC_VECTOR(7 DOWNTO 0) := x"06";
	CONSTANT CMD_READ_VAR32    : STD_LOGIC_VECTOR(7 DOWNTO 0) := x"0C";
	CONSTANT CMD_SET_USB_MODE  : STD_LOGIC_VECTOR(7 DOWNTO 0) := x"15";
	CONSTANT CMD_GET_STATUS    : STD_LOGIC_VECTOR(7 DOWNTO 0) := x"22";
	CONSTANT CMD_RD_USB_DATA0  : STD_LOGIC_VECTOR(7 DOWNTO 0) := x"27";
	CONSTANT CMD_WR_REQ_DATA   : STD_LOGIC_VECTOR(7 DOWNTO 0) := x"2D";
	CONSTANT CMD_SET_FILE_NAME : STD_LOGIC_VECTOR(7 DOWNTO 0) := x"2F";
	CONSTANT CMD_DISK_MOUNT    : STD_LOGIC_VECTOR(7 DOWNTO 0) := x"31";
	CONSTANT CMD_FILE_OPEN     : STD_LOGIC_VECTOR(7 DOWNTO 0) := x"32";
	CONSTANT CMD_FILE_ENUM_GO  : STD_LOGIC_VECTOR(7 DOWNTO 0) := x"33";
	CONSTANT CMD_FILE_CREATE   : STD_LOGIC_VECTOR(7 DOWNTO 0) := x"34";
	CONSTANT CMD_FILE_ERASE    : STD_LOGIC_VECTOR(7 DOWNTO 0) := x"35";
	CONSTANT CMD_FILE_CLOSE    : STD_LOGIC_VECTOR(7 DOWNTO 0) := x"36";
	CONSTANT CMD_BYTE_LOCATE   : STD_LOGIC_VECTOR(7 DOWNTO 0) := x"39";
	CONSTANT CMD_BYTE_READ     : STD_LOGIC_VECTOR(7 DOWNTO 0) := x"3A";
	CONSTANT CMD_BYTE_RD_GO    : STD_LOGIC_VECTOR(7 DOWNTO 0) := x"3B";
	CONSTANT CMD_BYTE_WRITE    : STD_LOGIC_VECTOR(7 DOWNTO 0) := x"3C";
	CONSTANT CMD_BYTE_WR_GO    : STD_LOGIC_VECTOR(7 DOWNTO 0) := x"3D";
	CONSTANT CMD_DISK_CAPACITY : STD_LOGIC_VECTOR(7 DOWNTO 0) := x"3E";
	CONSTANT CMD_DISK_QUERY    : STD_LOGIC_VECTOR(7 DOWNTO 0) := x"3F";
	CONSTANT CMD_DIR_CREATE    : STD_LOGIC_VECTOR(7 DOWNTO 0) := x"40";

	CONSTANT IC_VER            : STD_LOGIC_VECTOR(7 DOWNTO 0) := x"43"; -- (0x40 | 3) & 0x7F
	CONSTANT USB_MODE_INVALID  : STD_LOGIC_VECTOR(7 DOWNTO 0) := x"00";
	CONSTANT USB_MODE_SD_HOST  : STD_LOGIC_VECTOR(7 DOWNTO 0) := x"03";
	CONSTANT USB_MODE_USB_HOST : STD_LOGIC_VECTOR(7 DOWNTO 0) := x"06";
	CONSTANT VAR_FILE_SIZE     : STD_LOGIC_VECTOR(7 DOWNTO 0) := x"68";
	CONSTANT VAR_CURRENT_OFFSET: STD_LOGIC_VECTOR(7 DOWNTO 0) := x"6C";
	CONSTANT RET_SUCCESS       : STD_LOGIC_VECTOR(7 DOWNTO 0) := x"51";
	CONSTANT RET_ABORT         : STD_LOGIC_VECTOR(7 DOWNTO 0) := x"5F";
	CONSTANT INT_SUCCESS       : STD_LOGIC_VECTOR(7 DOWNTO 0) := x"14";
	CONSTANT REQ_SIZE          : UNSIGNED(7 DOWNTO 0) := x"FF";         -- pos value before the size byte is read

	TYPE buffer_t IS ARRAY(0 TO 255) OF STD_LOGIC_VECTOR(7 DOWNTO 0);
	SIGNAL buf : buffer_t;

	SIGNAL command     : STD_LOGIC_VECTOR(7 DOWNTO 0) := CMD_NONE;
	SIGNAL cmd_status  : STD_LOGIC_VECTOR(7 DOWNTO 0) := (OTHERS => '0');
	SIGNAL if_status   : STD_LOGIC_VECTOR(6 DOWNTO 0) := (OTHERS => '0');
	SIGNAL usb_mode    : STD_LOGIC_VECTOR(7 DOWNTO 0) := USB_MODE_INVALID;
	SIGNAL count       : UNSIGNED(7 DOWNTO 0) := (OTHERS => '0');
	SIGNAL pos         : UNSIGNED(7 DOWNTO 0) := (OTHERS => '0');
	SIGNAL check_byte  : STD_LOGIC_VECTOR(7 DOWNTO 0) := (OTHERS => '0');
	SIGNAL busy        : STD_LOGIC := '0';
	SIGNAL request     : STD_LOGIC := '0';
	SIGNAL cancel_io   : STD_LOGIC := '0';
	SIGNAL var32       : STD_LOGIC_VECTOR(31 DOWNTO 0) := (OTHERS => '0');
	SIGNAL file_size   : STD_LOGIC_VECTOR(31 DOWNTO 0) := (OTHERS => '0');
	SIGNAL file_offset : STD_LOGIC_VECTOR(31 DOWNTO 0) := (OTHERS => '0');

	-- buffer port A (6502 side): reads at pos, writes at pos
	SIGNAL a_we        : STD_LOGIC;
	SIGNAL a_q         : STD_LOGIC_VECTOR(7 DOWNTO 0);
	SIGNAL buf0        : STD_LOGIC_VECTOR(7 DOWNTO 0);          -- copy of buffer byte 0
	-- buffer port B (firmware side)
	SIGNAL b_we        : STD_LOGIC;
	SIGNAL b_q         : STD_LOGIC_VECTOR(7 DOWNTO 0);
	SIGNAL f_reg_q     : STD_LOGIC_VECTOR(7 DOWNTO 0);
	SIGNAL f_sel_q     : STD_LOGIC;                             -- F_ADDR(8) of the pending read

	SIGNAL host_rd     : STD_LOGIC;
	SIGNAL host_wr     : STD_LOGIC;

BEGIN

	host_rd <= ENA AND NOT CSn AND RnW;
	host_wr <= ENA AND NOT CSn AND NOT RnW;

	----------------------------------------------------------------------------
	-- Shared buffer, true dual port
	----------------------------------------------------------------------------
	-- The 6502 side writes the byte at pos only when the data port protocol
	-- stores one (see the main process); it always reads at pos.
	a_we <= '1' WHEN host_wr = '1' AND A0 = '0' AND (
	            (command = CMD_SET_FILE_NAME AND pos < 14) OR
	            (command = CMD_BYTE_LOCATE   AND pos < 4)  OR
	            ((command = CMD_BYTE_READ OR command = CMD_BYTE_WRITE) AND pos < 2) OR
	            (command = CMD_WR_REQ_DATA AND count /= 0 AND pos /= REQ_SIZE AND pos /= count))
	        ELSE '0';

	-- One write port shared by both sides: by protocol the firmware only
	-- writes while busy and the 6502 only while not busy. Should both write in
	-- the same clock the 6502 wins. Two read ports, one at pos for the 6502 and
	-- one at F_ADDR for the firmware.
	b_we <= F_WE WHEN F_ADDR(8) = '0' ELSE '0';

	PROCESS (CLK)
	BEGIN
		IF rising_edge(CLK) THEN
			IF a_we = '1' THEN
				buf(to_integer(pos)) <= DIN;
			ELSIF b_we = '1' THEN
				buf(to_integer(unsigned(F_ADDR(7 DOWNTO 0)))) <= F_DIN;
			END IF;
			a_q <= buf(to_integer(pos));
			b_q <= buf(to_integer(unsigned(F_ADDR(7 DOWNTO 0))));
		END IF;
	END PROCESS;

	-- Byte 0 is also returned by unexpected data reads; keep a copy so it is
	-- available without a third read port.
	PROCESS (CLK)
	BEGIN
		IF rising_edge(CLK) THEN
			IF a_we = '1' THEN
				IF pos = 0 THEN
					buf0 <= DIN;
				END IF;
			ELSIF b_we = '1' AND F_ADDR(7 DOWNTO 0) = x"00" THEN
				buf0 <= F_DIN;
			END IF;
		END IF;
	END PROCESS;

	----------------------------------------------------------------------------
	-- 6502 read data
	----------------------------------------------------------------------------
	PROCESS (A0, busy, if_status, command, check_byte, count, pos, var32, usb_mode, cmd_status, a_q, buf0)
	BEGIN
		IF A0 = '1' THEN
			DOUT <= busy & if_status;
		ELSE
			CASE command IS
				WHEN CMD_CHECK_EXIST =>
					DOUT <= check_byte;
				WHEN CMD_READ_VAR32 =>
					IF count = 0 THEN
						DOUT <= x"00";
					ELSIF count /= pos THEN
						CASE to_integer(pos(1 DOWNTO 0)) IS
							WHEN 0      => DOUT <= var32(7 DOWNTO 0);
							WHEN 1      => DOUT <= var32(15 DOWNTO 8);
							WHEN 2      => DOUT <= var32(23 DOWNTO 16);
							WHEN OTHERS => DOUT <= var32(31 DOWNTO 24);
						END CASE;
					ELSE
						DOUT <= x"FF";
					END IF;
				WHEN CMD_GET_IC_VER =>
					DOUT <= IC_VER;
				WHEN CMD_SET_USB_MODE =>
					IF usb_mode = USB_MODE_INVALID THEN
						DOUT <= RET_ABORT;
					ELSE
						DOUT <= RET_SUCCESS;
					END IF;
				WHEN CMD_GET_STATUS =>
					DOUT <= cmd_status;
				WHEN CMD_RD_USB_DATA0 =>
					IF count = 0 THEN
						DOUT <= x"00";
					ELSIF pos = REQ_SIZE THEN
						DOUT <= std_logic_vector(count);
					ELSIF count /= pos THEN
						DOUT <= a_q;
					ELSE
						DOUT <= x"FF";
					END IF;
				WHEN CMD_WR_REQ_DATA =>
					IF count = 0 THEN
						DOUT <= x"00";
					ELSIF pos = REQ_SIZE THEN
						DOUT <= std_logic_vector(count);
					ELSE
						DOUT <= x"FF";
					END IF;
				WHEN OTHERS =>
					DOUT <= buf0;
			END CASE;
		END IF;
	END PROCESS;

	----------------------------------------------------------------------------
	-- Protocol state
	----------------------------------------------------------------------------
	PROCESS (CLK)
		VARIABLE fa : INTEGER RANGE 0 TO 15;
	BEGIN
		IF rising_edge(CLK) THEN
			IF RESETn = '0' THEN
				command    <= CMD_NONE;
				cmd_status <= (OTHERS => '0');
				if_status  <= (OTHERS => '0');
				usb_mode   <= USB_MODE_INVALID;
				count      <= (OTHERS => '0');
				pos        <= (OTHERS => '0');
				check_byte <= (OTHERS => '0');
				busy       <= '0';
				request    <= '0';
				cancel_io  <= '1';               -- let the firmware start from a clean state
				var32      <= (OTHERS => '0');
			ELSE
				------------------------------------------------------------
				-- firmware writes
				------------------------------------------------------------
				IF F_WE = '1' AND F_ADDR(8) = '1' THEN
					fa := to_integer(unsigned(F_ADDR(3 DOWNTO 0)));
					CASE fa IS
						WHEN 2  => pos        <= unsigned(F_DIN);
						WHEN 3  => count      <= unsigned(F_DIN);
						WHEN 4  => cmd_status <= F_DIN;
						WHEN 5  => if_status  <= F_DIN(6 DOWNTO 0);
						WHEN 7  =>
							IF F_DIN(0) = '1' THEN
								busy    <= '0';
								request <= '0';
							END IF;
							IF F_DIN(1) = '1' THEN
								cancel_io <= '0';
							END IF;
						WHEN 8  => file_size(7 DOWNTO 0)     <= F_DIN;
						WHEN 9  => file_size(15 DOWNTO 8)    <= F_DIN;
						WHEN 10 => file_size(23 DOWNTO 16)   <= F_DIN;
						WHEN 11 => file_size(31 DOWNTO 24)   <= F_DIN;
						WHEN 12 => file_offset(7 DOWNTO 0)   <= F_DIN;
						WHEN 13 => file_offset(15 DOWNTO 8)  <= F_DIN;
						WHEN 14 => file_offset(23 DOWNTO 16) <= F_DIN;
						WHEN 15 => file_offset(31 DOWNTO 24) <= F_DIN;
						WHEN OTHERS => NULL;
					END CASE;
				END IF;

				------------------------------------------------------------
				-- 6502 command port write
				------------------------------------------------------------
				IF host_wr = '1' AND A0 = '1' THEN
					if_status <= (OTHERS => '0');
					-- quirk: the check byte can come from the command port
					IF command = CMD_CHECK_EXIST THEN
						check_byte <= NOT DIN;
					END IF;

					CASE DIN IS
						WHEN CMD_CHECK_EXIST | CMD_READ_VAR32 | CMD_GET_IC_VER |
						     CMD_SET_USB_MODE | CMD_GET_STATUS | CMD_FILE_CLOSE =>
							command <= DIN;

						WHEN CMD_SET_FILE_NAME | CMD_BYTE_LOCATE | CMD_BYTE_READ | CMD_BYTE_WRITE =>
							command <= DIN;
							pos     <= (OTHERS => '0');

						WHEN CMD_RD_USB_DATA0 | CMD_WR_REQ_DATA =>
							command <= DIN;
							pos     <= REQ_SIZE;

						-- file system commands: the firmware does the work
						WHEN CMD_DISK_MOUNT | CMD_FILE_OPEN | CMD_FILE_CREATE | CMD_DIR_CREATE |
						     CMD_FILE_ERASE | CMD_FILE_ENUM_GO | CMD_DISK_CAPACITY | CMD_DISK_QUERY |
						     CMD_BYTE_RD_GO | CMD_BYTE_WR_GO =>
							command <= DIN;
							busy    <= '1';
							request <= '1';

						WHEN OTHERS =>
							-- unsupported: the previous command stays, as in Oricutron
							cmd_status <= RET_ABORT;
					END CASE;
				END IF;

				------------------------------------------------------------
				-- 6502 data port write
				------------------------------------------------------------
				IF host_wr = '1' AND A0 = '0' THEN
					CASE command IS
						WHEN CMD_CHECK_EXIST =>
							check_byte <= NOT DIN;

						WHEN CMD_READ_VAR32 =>
							IF DIN = VAR_FILE_SIZE OR DIN = VAR_CURRENT_OFFSET THEN
								IF DIN = VAR_FILE_SIZE THEN
									var32 <= file_size;
								ELSE
									var32 <= file_offset;
								END IF;
								count      <= to_unsigned(4, 8);
								pos        <= (OTHERS => '0');
								if_status  <= "1111111";
								cmd_status <= INT_SUCCESS;
							ELSE
								if_status  <= (OTHERS => '0');
								cmd_status <= RET_ABORT;
							END IF;

						WHEN CMD_SET_USB_MODE =>
							cancel_io <= '1';
							IF DIN = USB_MODE_SD_HOST OR DIN = USB_MODE_USB_HOST THEN
								usb_mode <= DIN;
							ELSE
								usb_mode <= USB_MODE_INVALID;
							END IF;

						WHEN CMD_SET_FILE_NAME =>
							IF pos < 14 THEN
								pos <= pos + 1;
							END IF;

						WHEN CMD_BYTE_LOCATE =>
							IF pos < 4 THEN
								pos <= pos + 1;
								IF pos = 3 THEN
									busy    <= '1';
									request <= '1';
								END IF;
							END IF;

						WHEN CMD_BYTE_READ | CMD_BYTE_WRITE =>
							IF pos < 2 THEN
								pos <= pos + 1;
								IF pos = 1 THEN
									busy    <= '1';
									request <= '1';
								END IF;
							END IF;

						WHEN CMD_WR_REQ_DATA =>
							IF count /= 0 AND pos /= REQ_SIZE THEN
								IF pos /= count THEN
									pos <= pos + 1;
									IF pos + 1 = count THEN
										if_status  <= (OTHERS => '0');
										cmd_status <= RET_SUCCESS;
									END IF;
								END IF;
							ELSE
								if_status  <= (OTHERS => '0');
								cmd_status <= RET_ABORT;
							END IF;

						WHEN CMD_FILE_CLOSE =>
							busy    <= '1';
							request <= '1';

						WHEN OTHERS =>
							NULL;
					END CASE;
				END IF;

				------------------------------------------------------------
				-- 6502 data port read side effects
				------------------------------------------------------------
				IF host_rd = '1' AND A0 = '0' THEN
					CASE command IS
						WHEN CMD_READ_VAR32 =>
							IF count /= 0 AND count /= pos THEN
								pos <= pos + 1;
								IF pos + 1 = count THEN
									count <= (OTHERS => '0');
								END IF;
							END IF;
						WHEN CMD_RD_USB_DATA0 =>
							IF count /= 0 THEN
								IF pos = REQ_SIZE THEN
									pos <= (OTHERS => '0');
								ELSIF count /= pos THEN
									pos <= pos + 1;
									IF pos + 1 = count THEN
										count <= (OTHERS => '0');
									END IF;
								END IF;
							END IF;
						WHEN CMD_WR_REQ_DATA =>
							IF count /= 0 AND pos = REQ_SIZE THEN
								pos <= (OTHERS => '0');
							END IF;
						WHEN OTHERS =>
							NULL;
					END CASE;
				END IF;
			END IF;
		END IF;
	END PROCESS;

	----------------------------------------------------------------------------
	-- Firmware read data
	----------------------------------------------------------------------------
	PROCESS (CLK)
		VARIABLE fa : INTEGER RANGE 0 TO 15;
	BEGIN
		IF rising_edge(CLK) THEN
			f_sel_q <= F_ADDR(8);
			fa := to_integer(unsigned(F_ADDR(3 DOWNTO 0)));
			CASE fa IS
				WHEN 0      => f_reg_q <= command;
				WHEN 1      => f_reg_q <= busy & "00000" & cancel_io & request;
				WHEN 2      => f_reg_q <= std_logic_vector(pos);
				WHEN 3      => f_reg_q <= std_logic_vector(count);
				WHEN 4      => f_reg_q <= cmd_status;
				WHEN 5      => f_reg_q <= '0' & if_status;
				WHEN 6      => f_reg_q <= usb_mode;
				WHEN 8      => f_reg_q <= file_size(7 DOWNTO 0);
				WHEN 9      => f_reg_q <= file_size(15 DOWNTO 8);
				WHEN 10     => f_reg_q <= file_size(23 DOWNTO 16);
				WHEN 11     => f_reg_q <= file_size(31 DOWNTO 24);
				WHEN 12     => f_reg_q <= file_offset(7 DOWNTO 0);
				WHEN 13     => f_reg_q <= file_offset(15 DOWNTO 8);
				WHEN 14     => f_reg_q <= file_offset(23 DOWNTO 16);
				WHEN 15     => f_reg_q <= file_offset(31 DOWNTO 24);
				WHEN OTHERS => f_reg_q <= x"00";
			END CASE;
		END IF;
	END PROCESS;

	-- one clock latency for both the buffer and the registers
	F_DOUT <= b_q WHEN f_sel_q = '0' ELSE f_reg_q;

END rtl;
