-- ch376_core
-- Emulated CH376 for the Twilighte board: host interface plus a T65 softcore
-- running the file system firmware (firmware/ch376) on the user_io SD image.
-- Copyright 2026 rampa
--
-- This is free software: you can redistribute it and/or modify
-- it under the terms of the GNU General Public License as published by
-- the Free Software Foundation, either version 3 of the License,
-- or any later version.
--
-- Softcore memory map (see firmware/ch376/hw.h):
--   0x0000-0x0FFF  RAM, 4 KB
--   0x2000-0x21FF  ch376_host firmware port (buffer and registers)
--   0x2200-0x23FF  SD sector buffer, shared with user_io
--   0x2400-0x240F  SD control
--   0x8000-0xFFFF  ROM, 32 KB (rtl/ch376_fw_rom.vhd)
-- Both are sized to fit the EP4CE22 of the SiDi (66 M9K blocks in all).
--
-- The T65 runs on CLK with an enable every second clock. All memories and
-- registers are read synchronously on the clock between two enables, so the
-- data is ready at the next enable; writes happen on the enable itself.
--
-- SD control registers:
--   0x2400-0x2403  R/W  LBA, little endian
--   0x2404  W  bit 0 start a read, bit 1 start a write, bit 7 clear "changed"
--           R  bit 0 busy, bit 1 image mounted, bit 7 a new image was mounted
--   0x2408-0x240B  R  image size in bytes, little endian (low 32 bits)
--
-- user_io protocol: sd_rd or sd_wr is held with sd_lba stable until the MiST
-- firmware starts the transfer (sd_ack high); the transfer ends when sd_ack
-- falls. Read data arrives with sd_buff_wr at sd_buff_addr; for writes
-- user_io fetches sd_buff_din at sd_buff_addr.

LIBRARY IEEE;
USE IEEE.STD_LOGIC_1164.ALL;
USE IEEE.NUMERIC_STD.ALL;
USE work.ch376_fw_rom.ALL;

ENTITY ch376_core IS
	PORT (
		CLK          : IN  STD_LOGIC;
		RESETn       : IN  STD_LOGIC;

		-- 6502 side, 0x340-0x341
		ENA          : IN  STD_LOGIC;
		CSn          : IN  STD_LOGIC;
		A0           : IN  STD_LOGIC;
		RnW          : IN  STD_LOGIC;
		DIN          : IN  STD_LOGIC_VECTOR(7 DOWNTO 0);
		DOUT         : OUT STD_LOGIC_VECTOR(7 DOWNTO 0);

		-- user_io SD image slot
		SD_LBA       : OUT STD_LOGIC_VECTOR(31 DOWNTO 0);
		SD_RD        : OUT STD_LOGIC;
		SD_WR        : OUT STD_LOGIC;
		SD_ACK       : IN  STD_LOGIC;
		SD_BUFF_ADDR : IN  STD_LOGIC_VECTOR(8 DOWNTO 0);
		SD_BUFF_DOUT : IN  STD_LOGIC_VECTOR(7 DOWNTO 0);
		SD_BUFF_WR   : IN  STD_LOGIC;
		SD_BUFF_DIN  : OUT STD_LOGIC_VECTOR(7 DOWNTO 0);
		IMG_MOUNTED  : IN  STD_LOGIC;
		IMG_SIZE     : IN  STD_LOGIC_VECTOR(31 DOWNTO 0)
	);
END ch376_core;

ARCHITECTURE rtl OF ch376_core IS

	SIGNAL cpu_en    : STD_LOGIC := '0';
	SIGNAL cpu_a     : STD_LOGIC_VECTOR(23 DOWNTO 0);
	SIGNAL cpu_di    : STD_LOGIC_VECTOR(7 DOWNTO 0);
	SIGNAL cpu_do    : STD_LOGIC_VECTOR(7 DOWNTO 0);
	SIGNAL cpu_rw    : STD_LOGIC;
	SIGNAL cpu_wr    : STD_LOGIC;
	SIGNAL a         : UNSIGNED(15 DOWNTO 0);

	SIGNAL sel_ram   : STD_LOGIC;
	SIGNAL sel_host  : STD_LOGIC;
	SIGNAL sel_sdbuf : STD_LOGIC;
	SIGNAL sel_sdreg : STD_LOGIC;
	SIGNAL sel_rom   : STD_LOGIC;
	SIGNAL rd_sel    : STD_LOGIC_VECTOR(2 DOWNTO 0);       -- device of the pending read

	TYPE ram_t IS ARRAY(0 TO 4095) OF STD_LOGIC_VECTOR(7 DOWNTO 0);
	SIGNAL ram       : ram_t;
	SIGNAL ram_q     : STD_LOGIC_VECTOR(7 DOWNTO 0);

	SIGNAL rom       : ch376_rom_t := CH376_FW;
	SIGNAL rom_q     : STD_LOGIC_VECTOR(7 DOWNTO 0);

	TYPE sdbuf_t IS ARRAY(0 TO 511) OF STD_LOGIC_VECTOR(7 DOWNTO 0);
	SIGNAL sdbuf     : sdbuf_t;
	SIGNAL sdbuf_q   : STD_LOGIC_VECTOR(7 DOWNTO 0);

	SIGNAL host_q    : STD_LOGIC_VECTOR(7 DOWNTO 0);
	SIGNAL host_we   : STD_LOGIC;

	SIGNAL lba       : STD_LOGIC_VECTOR(31 DOWNTO 0) := (OTHERS => '0');
	SIGNAL sd_rd_r   : STD_LOGIC := '0';
	SIGNAL sd_wr_r   : STD_LOGIC := '0';
	SIGNAL sd_busy   : STD_LOGIC := '0';
	SIGNAL ack_seen  : STD_LOGIC := '0';
	SIGNAL mounted   : STD_LOGIC := '0';
	SIGNAL changed   : STD_LOGIC := '0';
	SIGNAL img_sz    : STD_LOGIC_VECTOR(31 DOWNTO 0) := (OTHERS => '0');
	SIGNAL sdreg_q   : STD_LOGIC_VECTOR(7 DOWNTO 0);

BEGIN

	----------------------------------------------------------------------------
	-- CPU
	----------------------------------------------------------------------------
	PROCESS (CLK)
	BEGIN
		IF rising_edge(CLK) THEN
			IF RESETn = '0' THEN
				cpu_en <= '0';
			ELSE
				cpu_en <= NOT cpu_en;
			END IF;
		END IF;
	END PROCESS;

	cpu : ENTITY work.T65
		PORT MAP (
			Mode    => "00",
			BCD_en  => '1',
			Res_n   => RESETn,
			Enable  => cpu_en,
			Clk     => CLK,
			Rdy     => '1',
			Abort_n => '1',
			IRQ_n   => '1',
			NMI_n   => '1',
			SO_n    => '1',
			R_W_n   => cpu_rw,
			Sync    => OPEN,
			EF      => OPEN,
			MF      => OPEN,
			XF      => OPEN,
			ML_n    => OPEN,
			VP_n    => OPEN,
			VDA     => OPEN,
			VPA     => OPEN,
			A       => cpu_a,
			DI      => cpu_di,
			DO      => cpu_do,
			Regs    => OPEN,
			DEBUG   => OPEN,
			NMI_ack => OPEN
		);

	a      <= unsigned(cpu_a(15 DOWNTO 0));
	cpu_wr <= cpu_en AND NOT cpu_rw;

	sel_ram   <= '1' WHEN a(15 DOWNTO 12) = "0000"           ELSE '0';   -- 0x0000-0x0FFF
	sel_host  <= '1' WHEN a(15 DOWNTO 9)  = "0010000"        ELSE '0';   -- 0x2000-0x21FF
	sel_sdbuf <= '1' WHEN a(15 DOWNTO 9)  = "0010001"        ELSE '0';   -- 0x2200-0x23FF
	sel_sdreg <= '1' WHEN a(15 DOWNTO 4)  = x"240"           ELSE '0';   -- 0x2400-0x240F
	sel_rom   <= a(15);                                                  -- 0x8000-0xFFFF

	PROCESS (CLK)
	BEGIN
		IF rising_edge(CLK) THEN
			IF sel_ram = '1' THEN
				rd_sel <= "000";
			ELSIF sel_host = '1' THEN
				rd_sel <= "001";
			ELSIF sel_sdbuf = '1' THEN
				rd_sel <= "010";
			ELSIF sel_sdreg = '1' THEN
				rd_sel <= "011";
			ELSE
				rd_sel <= "100";
			END IF;
		END IF;
	END PROCESS;

	WITH rd_sel SELECT cpu_di <=
		ram_q   WHEN "000",
		host_q  WHEN "001",
		sdbuf_q WHEN "010",
		sdreg_q WHEN "011",
		rom_q   WHEN OTHERS;

	----------------------------------------------------------------------------
	-- RAM and ROM
	----------------------------------------------------------------------------
	PROCESS (CLK)
	BEGIN
		IF rising_edge(CLK) THEN
			IF cpu_wr = '1' AND sel_ram = '1' THEN
				ram(to_integer(a(11 DOWNTO 0))) <= cpu_do;
			END IF;
			ram_q <= ram(to_integer(a(11 DOWNTO 0)));
		END IF;
	END PROCESS;

	PROCESS (CLK)
	BEGIN
		IF rising_edge(CLK) THEN
			IF sel_rom = '1' THEN
				rom_q <= rom(to_integer(a(14 DOWNTO 0)));
			END IF;
		END IF;
	END PROCESS;

	----------------------------------------------------------------------------
	-- CH376 host interface
	----------------------------------------------------------------------------
	host_we <= cpu_wr AND sel_host;

	host : ENTITY work.ch376_host
		PORT MAP (
			CLK    => CLK,
			RESETn => RESETn,
			ENA    => ENA,
			CSn    => CSn,
			A0     => A0,
			RnW    => RnW,
			DIN    => DIN,
			DOUT   => DOUT,
			F_ADDR => std_logic_vector(a(8 DOWNTO 0)),
			F_WE   => host_we,
			F_DIN  => cpu_do,
			F_DOUT => host_q
		);

	----------------------------------------------------------------------------
	-- SD sector buffer: one write port (user_io first, the CPU only writes
	-- while no transfer runs), a read port for each side
	----------------------------------------------------------------------------
	PROCESS (CLK)
	BEGIN
		IF rising_edge(CLK) THEN
			IF SD_BUFF_WR = '1' THEN
				sdbuf(to_integer(unsigned(SD_BUFF_ADDR))) <= SD_BUFF_DOUT;
			ELSIF cpu_wr = '1' AND sel_sdbuf = '1' THEN
				sdbuf(to_integer(a(8 DOWNTO 0))) <= cpu_do;
			END IF;
			sdbuf_q     <= sdbuf(to_integer(a(8 DOWNTO 0)));
			SD_BUFF_DIN <= sdbuf(to_integer(unsigned(SD_BUFF_ADDR)));
		END IF;
	END PROCESS;

	----------------------------------------------------------------------------
	-- SD control
	----------------------------------------------------------------------------
	SD_LBA <= lba;
	SD_RD  <= sd_rd_r;
	SD_WR  <= sd_wr_r;

	PROCESS (CLK)
		VARIABLE ra : INTEGER RANGE 0 TO 15;
	BEGIN
		IF rising_edge(CLK) THEN
			ra := to_integer(a(3 DOWNTO 0));

			IF RESETn = '0' THEN
				sd_rd_r  <= '0';
				sd_wr_r  <= '0';
				sd_busy  <= '0';
				ack_seen <= '0';
			ELSE
				IF cpu_wr = '1' AND sel_sdreg = '1' THEN
					CASE ra IS
						WHEN 0 => lba(7 DOWNTO 0)   <= cpu_do;
						WHEN 1 => lba(15 DOWNTO 8)  <= cpu_do;
						WHEN 2 => lba(23 DOWNTO 16) <= cpu_do;
						WHEN 3 => lba(31 DOWNTO 24) <= cpu_do;
						WHEN 4 =>
							IF cpu_do(0) = '1' THEN
								sd_rd_r  <= '1';
								sd_busy  <= '1';
								ack_seen <= '0';
							ELSIF cpu_do(1) = '1' THEN
								sd_wr_r  <= '1';
								sd_busy  <= '1';
								ack_seen <= '0';
							END IF;
							IF cpu_do(7) = '1' THEN
								changed <= '0';
							END IF;
						WHEN OTHERS => NULL;
					END CASE;
				END IF;

				IF SD_ACK = '1' THEN
					sd_rd_r  <= '0';
					sd_wr_r  <= '0';
					ack_seen <= '1';
				ELSIF ack_seen = '1' THEN
					sd_busy  <= '0';
					ack_seen <= '0';
				END IF;
			END IF;

			-- a new image (also after reset, so the firmware starts clean)
			IF IMG_MOUNTED = '1' THEN
				img_sz <= IMG_SIZE;
				IF IMG_SIZE /= x"00000000" THEN
					mounted <= '1';
				ELSE
					mounted <= '0';
				END IF;
				changed <= '1';
			END IF;

			CASE ra IS
				WHEN 0      => sdreg_q <= lba(7 DOWNTO 0);
				WHEN 1      => sdreg_q <= lba(15 DOWNTO 8);
				WHEN 2      => sdreg_q <= lba(23 DOWNTO 16);
				WHEN 3      => sdreg_q <= lba(31 DOWNTO 24);
				WHEN 4      => sdreg_q <= changed & "00000" & mounted & sd_busy;
				WHEN 8      => sdreg_q <= img_sz(7 DOWNTO 0);
				WHEN 9      => sdreg_q <= img_sz(15 DOWNTO 8);
				WHEN 10     => sdreg_q <= img_sz(23 DOWNTO 16);
				WHEN 11     => sdreg_q <= img_sz(31 DOWNTO 24);
				WHEN OTHERS => sdreg_q <= x"00";
			END CASE;
		END IF;
	END PROCESS;

END rtl;
