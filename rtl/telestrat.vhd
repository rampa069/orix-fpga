--
-- A simulation model of ORIC TELESTRAT hardware
-- Based on the ORIC ATMOS Core (initial  Copyright (c) SEILEBOST - March 2006)
--
--

LIBRARY ieee;
USE ieee.std_logic_1164.ALL;
USE ieee.std_logic_arith.ALL;
USE ieee.std_logic_unsigned.ALL;
ENTITY telestrat IS
	GENERIC (
		-- 0: bridge to a physical CH376 on the CH_* pins only,
		-- 1: emulated CH376 (rtl/ch376_core.vhd) on the user_io SD image only,
		-- 2: both, chosen at run time with CH376_VIRTUAL
		CH376_BACKEND : INTEGER := 1
	);
	PORT (
		CLK_IN : IN STD_LOGIC;
		CLK_ACIA : IN STD_LOGIC;
		RESET : IN STD_LOGIC;
		key_pressed : IN STD_LOGIC;
		key_extended : IN STD_LOGIC;
		key_code : IN STD_LOGIC_VECTOR(7 DOWNTO 0);
		key_strobe : IN STD_LOGIC;
		K7_TAPEIN : IN STD_LOGIC;
		K7_TAPEOUT : OUT STD_LOGIC;
		K7_REMOTE : OUT STD_LOGIC;
		RTC : IN STD_LOGIC_VECTOR(63 DOWNTO 0);
		PSG_OUT : OUT unsigned(13 DOWNTO 0);
		PSG_OUT_A : OUT unsigned(11 DOWNTO 0);
		PSG_OUT_B : OUT unsigned(11 DOWNTO 0);
		PSG_OUT_C : OUT unsigned(11 DOWNTO 0);
		VIDEO_R : OUT STD_LOGIC;
		VIDEO_G : OUT STD_LOGIC;
		VIDEO_B : OUT STD_LOGIC;
		VIDEO_HSYNC : OUT STD_LOGIC;
		VIDEO_VSYNC : OUT STD_LOGIC;
		VIDEO_VBLANK : OUT STD_LOGIC;
		VIDEO_HBLANK : OUT STD_LOGIC;
		VIDEO_CLK : OUT STD_LOGIC;
		ram_ad : OUT STD_LOGIC_VECTOR(15 DOWNTO 0);
		ram_d : OUT STD_LOGIC_VECTOR(7 DOWNTO 0);
		ram_q : IN STD_LOGIC_VECTOR(7 DOWNTO 0);
		ram_cs : OUT STD_LOGIC;
		ram_oe : OUT STD_LOGIC;
		ram_we : OUT STD_LOGIC;

		rom_ad : OUT STD_LOGIC_VECTOR(19 DOWNTO 0);
		rom_d : IN STD_LOGIC_VECTOR(7 DOWNTO 0);
		rom_q : OUT STD_LOGIC_VECTOR(7 DOWNTO 0);
		rom_rd : OUT STD_LOGIC;
		rom_wr : OUT STD_LOGIC;
		-- '1' while the CPU address selects main RAM: the rom_* port then
		-- serves the 64 KB main RAM (SDRAM) instead of the banked area. The
		-- ram_* port only feeds the ULA video reads (shadow in block RAM).
		ram_sel : OUT STD_LOGIC;

		mode : IN STD_LOGIC_VECTOR(1 DOWNTO 0);
		debug : OUT STD_LOGIC;

		cpu_ad : BUFFER STD_LOGIC_VECTOR(23 DOWNTO 0);
		cpu_do : BUFFER STD_LOGIC_VECTOR(7 DOWNTO 0);

		WD_REn : BUFFER STD_LOGIC;
		WD_WEn : BUFFER STD_LOGIC;
		WD_DRQ : IN STD_LOGIC;
		WD_IRQ : IN STD_LOGIC;
		WD_HLD : IN STD_LOGIC;
		WD_CLK : BUFFER STD_LOGIC;
		FDC_DAL_OUT : IN STD_LOGIC_VECTOR(7 DOWNTO 0);
		CS1793n : BUFFER STD_LOGIC;
		SSEL : OUT STD_LOGIC;
		DS0 : OUT STD_LOGIC;
		DS1 : OUT STD_LOGIC;
		DS2 : OUT STD_LOGIC;
		DS3 : OUT STD_LOGIC;
		FDC_DRIVE : OUT STD_LOGIC_VECTOR(1 DOWNTO 0);
		WD_RESET : OUT STD_LOGIC;
		
		CH_D  : INOUT STD_LOGIC_VECTOR(7 DOWNTO 0);
		CH_A0 : OUT STD_LOGIC;
		CH_RD : OUT STD_LOGIC;
		CH_WR : OUT STD_LOGIC;
		CH_CS : OUT STD_LOGIC;
		-- with CH376_BACKEND = 2: '1' selects the emulated CH376, '0' the physical one
		CH376_VIRTUAL : IN STD_LOGIC := '1';
		-- PSG personality: '0' GI AY-3-8912 (as fitted), '1' Yamaha YM2149
		PSG_YM : IN STD_LOGIC := '0';

		-- user_io SD image slot for the emulated CH376
		SD_LBA       : OUT STD_LOGIC_VECTOR(31 DOWNTO 0);
		SD_RD        : OUT STD_LOGIC;
		SD_WR        : OUT STD_LOGIC;
		SD_ACK       : IN  STD_LOGIC;
		SD_BUFF_ADDR : IN  STD_LOGIC_VECTOR(8 DOWNTO 0);
		SD_BUFF_DOUT : IN  STD_LOGIC_VECTOR(7 DOWNTO 0);
		SD_BUFF_WR   : IN  STD_LOGIC;
		SD_BUFF_DIN  : OUT STD_LOGIC_VECTOR(7 DOWNTO 0);
		IMG_MOUNTED  : IN  STD_LOGIC;
		IMG_SIZE     : IN  STD_LOGIC_VECTOR(31 DOWNTO 0);

		phi2 : OUT STD_LOGIC;
		fdd_ready : IN STD_LOGIC;
		joystick_0 : IN STD_LOGIC_VECTOR(4 DOWNTO 0);
		joystick_1 : IN STD_LOGIC_VECTOR(4 DOWNTO 0);
		fire2_t1 : IN STD_LOGIC;
		fire3_t1 : IN STD_LOGIC;
		pll_locked : IN STD_LOGIC;
		disk_enable : IN STD_LOGIC;
		uart_txd : OUT STD_LOGIC;
		uart_rxd : IN STD_LOGIC;
		uart_rts : OUT STD_LOGIC;
		uart_cts : IN STD_LOGIC
	);
END;

ARCHITECTURE RTL OF telestrat IS

	-- Gestion des resets
	SIGNAL RESETn : STD_LOGIC;
	SIGNAL reset_dll_h : STD_LOGIC;
	SIGNAL delay_count : STD_LOGIC_VECTOR(7 DOWNTO 0) := (OTHERS => '0');
	SIGNAL clk_cnt : STD_LOGIC_VECTOR(2 DOWNTO 0) := "000";

	-- cpu
	--signal cpu_ad             : std_logic_vector(23 downto 0);
	SIGNAL cpu_di : STD_LOGIC_VECTOR(7 DOWNTO 0);
	SIGNAL cpu_di_last : STD_LOGIC_VECTOR(7 DOWNTO 0);
	--signal cpu_do             : std_logic_vector(7 downto 0);
	SIGNAL cpu_rw : STD_LOGIC;
	SIGNAL via1_irq : STD_LOGIC;
	SIGNAL via2_irq : STD_LOGIC;
	SIGNAL via1_irq_n : STD_LOGIC;
	SIGNAL via2_irq_n : STD_LOGIC;

	SIGNAL cpu_irq : STD_LOGIC;

	-- VIA 1
	SIGNAL via1_pa_out_oe : STD_LOGIC_VECTOR(7 DOWNTO 0);
	SIGNAL via1_pa_out_oe_l : STD_LOGIC_VECTOR(7 DOWNTO 0);

	SIGNAL via1_pa_in : STD_LOGIC_VECTOR(7 DOWNTO 0);
	SIGNAL via1_pa_out : STD_LOGIC_VECTOR(7 DOWNTO 0);
	SIGNAL via1_pa_in_from_psg : STD_LOGIC_VECTOR(7 DOWNTO 0);
	SIGNAL via1_ca2_out : STD_LOGIC;
	SIGNAL via1_cb1_out : STD_LOGIC;
	SIGNAL via1_cb1_oe_l : STD_LOGIC;
	SIGNAL via1_cb2_out : STD_LOGIC;
	SIGNAL via1_cb2_oe_l : STD_LOGIC;
	SIGNAL via1_pb_in : STD_LOGIC_VECTOR(7 DOWNTO 0);
	SIGNAL via1_pb_out : STD_LOGIC_VECTOR(7 DOWNTO 0);
	SIGNAL via1_pb_oe_l : STD_LOGIC_VECTOR(7 DOWNTO 0);
	SIGNAL VIA1_DO : STD_LOGIC_VECTOR(7 DOWNTO 0);

	-- VIA 2

	SIGNAL via2_pa_out_oe : STD_LOGIC_VECTOR(7 DOWNTO 0);
	SIGNAL via2_pa_in : STD_LOGIC_VECTOR(7 DOWNTO 0);
	SIGNAL via2_pa_out : STD_LOGIC_VECTOR(7 DOWNTO 0);
	SIGNAL via2_pa_in_from_psg : STD_LOGIC_VECTOR(7 DOWNTO 0);
	SIGNAL via2_cb1_out : STD_LOGIC;
	SIGNAL via2_cb1_in : STD_LOGIC;
	SIGNAL via2_cb1_oe_l : STD_LOGIC;
	SIGNAL via2_cb2_out : STD_LOGIC;
	SIGNAL via2_cb2_oe_l : STD_LOGIC;
	SIGNAL via2_pb_in : STD_LOGIC_VECTOR(7 DOWNTO 0);
	SIGNAL via2_pb_out : STD_LOGIC_VECTOR(7 DOWNTO 0);
	SIGNAL via2_pb_out_oe : STD_LOGIC_VECTOR(7 DOWNTO 0);
	SIGNAL VIA2_DO : STD_LOGIC_VECTOR(7 DOWNTO 0);
	SIGNAL VIA2_DO_OE : STD_LOGIC;
	-- CS 
	SIGNAL CS300n : STD_LOGIC;
	SIGNAL CS314n : STD_LOGIC;
	SIGNAL CS318n : STD_LOGIC;
	SIGNAL CS31Cn : STD_LOGIC;
	SIGNAL CS320n : STD_LOGIC;
	SIGNAL CS340n : STD_LOGIC;
	SIGNAL CS342n : STD_LOGIC;
	SIGNAL CS343n : STD_LOGIC;
	SIGNAL CS360n : STD_LOGIC;
	SIGNAL CS0n : STD_LOGIC;
	SIGNAL CS1n : STD_LOGIC;
	SIGNAL CS2n : STD_LOGIC;
	SIGNAL CS3n : STD_LOGIC;
	SIGNAL CS4n : STD_LOGIC;
	SIGNAL CS5n : STD_LOGIC;
	SIGNAL CS6n : STD_LOGIC;
	SIGNAL ROM_CSn : STD_LOGIC;
	SIGNAL MAIN_RAM_SEL : STD_LOGIC;
	SIGNAL BANK_SEL : STD_LOGIC; -- CPU access to the banked area (C000-FFFF, not mapped to overlay RAM)
	-- ACIA
	SIGNAL ACIA_DO : STD_LOGIC_VECTOR(7 DOWNTO 0);
	SIGNAL acia_irq : STD_LOGIC;
	SIGNAL XTLI : STD_LOGIC;
	SIGNAL RXD : STD_LOGIC;
	SIGNAL TXD : STD_LOGIC;
	SIGNAL CTS : STD_LOGIC;
	SIGNAL RTS : STD_LOGIC;
	SIGNAL DTR : STD_LOGIC;

	-- Controller
	SIGNAL cont_D_OUT : STD_LOGIC_VECTOR(7 DOWNTO 0);
	SIGNAL cont_irq : STD_LOGIC;

	-- Keyboard PS2
	SIGNAL KEY_HIT : STD_LOGIC;
	SIGNAL KEYB_RESETn : STD_LOGIC;
	SIGNAL KEYB_NMIn : STD_LOGIC;
	SIGNAL KEY_ROW : STD_LOGIC_VECTOR(7 DOWNTO 0);

	-- PSG
	SIGNAL ym_ioa_out : STD_LOGIC_VECTOR (7 DOWNTO 0);
	SIGNAL psg_do : STD_LOGIC_VECTOR (7 DOWNTO 0);
	SIGNAL psg_mix : UNSIGNED (14 DOWNTO 0);
	SIGNAL psg_bidir : STD_LOGIC;
	SIGNAL ym_o_ioa : STD_LOGIC_VECTOR (7 DOWNTO 0);

	-- Twilighte board
	SIGNAL BANK0_ROMRAM : STD_LOGIC;
	SIGNAL BANK1_ROMRAM : STD_LOGIC;
	SIGNAL BANK2_ROMRAM : STD_LOGIC;
	SIGNAL BANK3_ROMRAM : STD_LOGIC;
	SIGNAL BANK4_ROMRAM : STD_LOGIC;
	SIGNAL TWL_NMI : STD_LOGIC;
	SIGNAL TWL_DO   : STD_LOGIC_VECTOR(7 DOWNTO 0);
	SIGNAL CH376_DO : STD_LOGIC_VECTOR(7 DOWNTO 0);
	SIGNAL CH376_EMU_DO : STD_LOGIC_VECTOR(7 DOWNTO 0);
	SIGNAL CH376_PHY_DO : STD_LOGIC_VECTOR(7 DOWNTO 0);
	SIGNAL CH376_EMU_SEL : STD_LOGIC;  -- the emulated CH376 answers at 0x340
	SIGNAL CH376_EMU_CSn : STD_LOGIC;
	SIGNAL CH376_PHY_ENA : STD_LOGIC;
	SIGNAL BANK : STD_LOGIC_VECTOR(4 DOWNTO 0);

	-- RTC
	SIGNAL RTC_DO : STD_LOGIC_VECTOR(7 DOWNTO 0);

	-- ULA 1
	SIGNAL ula_phi2 : STD_LOGIC;
	SIGNAL ula_CSIOn : STD_LOGIC;
	--signal ula_CSROMn         : std_logic;
	SIGNAL ula_CSRAMn : STD_LOGIC;
	SIGNAL ula_AD_SRAM : STD_LOGIC_VECTOR(15 DOWNTO 0);
	SIGNAL ula_CE_SRAM : STD_LOGIC;
	SIGNAL ula_OE_SRAM : STD_LOGIC;
	SIGNAL ula_WE_SRAM : STD_LOGIC;
	SIGNAL ula_LATCH_SRAM : STD_LOGIC;
	SIGNAL ula_MAPn : STD_LOGIC;
	-- port A bank bits as HCS3119 sees them: VIA2, or the bank forced by the
	-- Twilighte firmware 2 mirror of 0x314 (000 overlay RAM, 110 ROM bank 6)
	SIGNAL mirror_on, mirror_rom : STD_LOGIC;
	SIGNAL hcs_pa : STD_LOGIC_VECTOR(2 DOWNTO 0);
	SIGNAL ula_CLK_4 : STD_LOGIC;
	SIGNAL ula_CLK_4_en : STD_LOGIC;
	SIGNAL ENA_1MHZ : STD_LOGIC;
	SIGNAL ENA_1MHZ_N : STD_LOGIC;

	-- RAM
	SIGNAL RAM_BANK0_DO : STD_LOGIC_VECTOR(7 DOWNTO 0);
	SIGNAL RAM_BANK1_DO : STD_LOGIC_VECTOR(7 DOWNTO 0);
	SIGNAL RAM_BANK2_DO : STD_LOGIC_VECTOR(7 DOWNTO 0);
	SIGNAL RAM_BANK3_DO : STD_LOGIC_VECTOR(7 DOWNTO 0);
	SIGNAL RAM_BANK4_DO : STD_LOGIC_VECTOR(7 DOWNTO 0);
	--- Printer port
	SIGNAL PRN_STROBE : STD_LOGIC;
	SIGNAL PRN_DATA : STD_LOGIC_VECTOR(7 DOWNTO 0);
	SIGNAL SRAM_DO : STD_LOGIC_VECTOR(7 DOWNTO 0);

	SIGNAL swnmi : STD_LOGIC;
	SIGNAL swrst : STD_LOGIC;
	SIGNAL joy_mux : STD_LOGIC_VECTOR(4 DOWNTO 0);
	SIGNAL joy_sel0, joy_sel1 : STD_LOGIC_VECTOR(4 DOWNTO 0);

	SIGNAL CPU1_DO : STD_LOGIC_VECTOR(7 DOWNTO 0);
	SIGNAL CPU2_DO : STD_LOGIC_VECTOR(7 DOWNTO 0);
	SIGNAL CPU1_RW : STD_LOGIC;
	SIGNAL CPU2_RW : STD_LOGIC;
	SIGNAL CPU1_AD : STD_LOGIC_VECTOR(23 DOWNTO 0);
	SIGNAL CPU2_AD : STD_LOGIC_VECTOR(23 DOWNTO 0);
	SIGNAL phi2_ref : STD_LOGIC;
	COMPONENT keyboard
		PORT (
			clk_sys : IN STD_LOGIC;
			key_pressed : IN STD_LOGIC;
			key_extended : IN STD_LOGIC;
			key_strobe : IN STD_LOGIC;
			key_code : IN STD_LOGIC_VECTOR(7 DOWNTO 0);
			row : IN STD_LOGIC_VECTOR(2 DOWNTO 0);
			col : IN STD_LOGIC_VECTOR(7 DOWNTO 0);
			key_hit : OUT STD_LOGIC;
			swnmi : OUT STD_LOGIC;
			swrst : OUT STD_LOGIC
		);
	END COMPONENT;

	COMPONENT ay_ym_psg
		PORT (
			ym : IN STD_LOGIC;
			clock : IN STD_LOGIC;
			sel : IN STD_LOGIC;
			ce : IN STD_LOGIC;
			reset : IN STD_LOGIC;
			bdir : IN STD_LOGIC;
			bc1 : IN STD_LOGIC;
			d : IN STD_LOGIC_VECTOR(7 DOWNTO 0);
			q : OUT STD_LOGIC_VECTOR(7 DOWNTO 0);
			a : OUT UNSIGNED(11 DOWNTO 0);
			b : OUT UNSIGNED(11 DOWNTO 0);
			c : OUT UNSIGNED(11 DOWNTO 0);
			mix : OUT UNSIGNED(14 DOWNTO 0);
			ioad : IN STD_LOGIC_VECTOR(7 DOWNTO 0);
			ioaq : OUT STD_LOGIC_VECTOR(7 DOWNTO 0);
			iobd : IN STD_LOGIC_VECTOR(7 DOWNTO 0);
			iobq : OUT STD_LOGIC_VECTOR(7 DOWNTO 0)
		);
	END COMPONENT;
	COMPONENT oric_ula IS
		PORT (
			CLK_24 : IN STD_LOGIC; -- 12 MHz clock
			nRESET : IN STD_LOGIC; -- Asynchronous reset
			AH : IN STD_LOGIC_VECTOR(15 DOWNTO 0); -- Address bits 15:8 from 6502
			D : IN STD_LOGIC_VECTOR(7 DOWNTO 0); -- Data bus
			RnW : IN STD_LOGIC; -- 6502 read signal indicator
			nMAP : IN STD_LOGIC; -- From expansion bus
			RC : OUT STD_LOGIC_VECTOR(15 DOWNTO 0); -- Row/column address to 4164 RAMs
			MXSEL : OUT STD_LOGIC; -- DRAM mux select
			nROM : OUT STD_LOGIC; -- ROM chip select
			nRAM : OUT STD_LOGIC; -- RAM chip select
			SRAM_CE : OUT STD_LOGIC; -- RAM chip select
			PHI : OUT STD_LOGIC; -- Output clock
			PHI_EN : OUT STD_LOGIC;
			PHI_EN_N : OUT STD_LOGIC;
			CAS : OUT STD_LOGIC; -- DRAM Column Access Strobe, active high
			RAS : OUT STD_LOGIC; -- DRAM Row Access Strobe, active high
			WE : OUT STD_LOGIC; -- DRAM Write Enable, active high
			nIO : OUT STD_LOGIC; -- 6522 chip select
			SYNC : OUT STD_LOGIC; -- Composite sync signal
			HSYNC : OUT STD_LOGIC;
			VSYNC : OUT STD_LOGIC;
			HBLANK : OUT STD_LOGIC;
			VBLANK : OUT STD_LOGIC;
			RED : OUT STD_LOGIC; -- Red video output
			GREEN : OUT STD_LOGIC; -- Green video output
			BLUE : OUT STD_LOGIC -- Blue video output
		);
	END COMPONENT;
BEGIN

	cpu_irq <= via1_irq_n AND via2_irq_n AND cont_irq AND acia_irq;

	cpu_rw <= cpu1_rw WHEN mode /= "10" ELSE
		cpu2_rw;
	cpu_do <= cpu1_do WHEN mode /= "10" ELSE
		cpu2_do;
	cpu_ad <= cpu1_ad WHEN mode /= "10" ELSE
		cpu2_ad;
		
	debug <=  cs340n;

	inst_cpu1 : ENTITY work.T65
		PORT MAP(
			Mode => mode,
			Res_n => RESETn,
			Enable => ENA_1MHZ_N,
			Clk => CLK_IN,
			Rdy => '1',
			Abort_n => '1',
			IRQ_n => cpu_irq,
			NMI_n => '1',
			SO_n => '1',
			R_W_n => cpu1_rw,
			A => cpu1_ad,
			DI => cpu_di,
			DO => cpu1_do
		);

	inst_cpu2 : ENTITY work.P65C816
		PORT MAP(
			CLK => clk_in, -- Mapeo del reloj de entrada
			RST_N => RESETn, -- Mapeo de la señal de reset activa baja
			CE => ENA_1MHZ_N, -- Clock Enable (similar a Enable en T65)
			RDY_IN => '1', -- Ready siempre activo ('1')
			NMI_N => '1', -- NMI deshabilitado ('1')
			IRQ_N => cpu_irq, -- IRQ entrada, mapear con la señal de interrupción
			ABORT_N => '1', -- ABORT no utilizado ('1')
			D_IN => cpu_di, -- Datos de entrada
			D_OUT => cpu2_do, -- Datos de salida
			A_OUT => cpu2_ad, -- Dirección de salida
			WE => cpu2_rw, -- Write Enable (escribir/leer, similar a R_W_n)
			RDY_OUT => OPEN, -- No usamos RDY_OUT, por eso lo dejamos desconectado
			VPA => OPEN, -- Vector Address, no lo usamos, por eso lo desconectamos
			VDA => OPEN, -- Vector Data Address, no lo usamos
			MLB => OPEN, -- Memory Lock Byte, no utilizado
			VPB => OPEN -- Vector Pull, no utilizado
		);

	ram_ad <= ula_AD_SRAM WHEN (ula_PHI2 = '0') ELSE
		cpu_ad(15 DOWNTO 0);
		
	ram_d <= cpu_do;
	SRAM_DO <= ram_q;
	ram_cs <= '0' WHEN RESETn = '0' ELSE
		ula_CE_SRAM;
	
	ram_we <= '0' WHEN RESETn = '0' ELSE
		ula_WE_SRAM;
	
	phi2 <= ula_PHI2;

	WD_RESET <= NOT RESETn;

	via1_pa_out_oe_l <= NOT via1_pa_out_oe;
	via1_irq_n <= NOT via1_irq;
	via2_irq_n <= NOT via2_irq;

	inst_via1 : ENTITY work.via6522
		PORT MAP
		(
			clock => CLK_IN,
			rising => ENA_1MHZ,
			falling => ENA_1MHZ_N,
			reset => NOT RESETn,
			phi2_ref => phi2_ref,

			addr => cpu_ad(3 DOWNTO 0),
			wen => NOT cpu_rw AND NOT CS300n,
			ren => cpu_rw AND NOT CS300n,
			data_in => cpu_do,
			data_out => VIA1_DO,

			port_a_i => via1_pa_in,
			port_a_o => via1_pa_out,
			port_a_t => via1_pa_out_oe,

			port_b_i => via1_pb_in,
			port_b_o => via1_pb_out,
			port_b_t => OPEN,

			ca1_i => '1',

			ca2_o => via1_ca2_out,
			ca2_i => '1',
			ca2_t => OPEN,

			cb1_i => K7_TAPEIN,
			cb1_o => via1_cb1_out,
			cb1_t => OPEN,

			cb2_i => '1',
			cb2_o => via1_cb2_out,
			cb2_t => OPEN,

			irq => via1_irq
		);

	inst_via2 : ENTITY work.via6522
		PORT MAP
		(
			clock => CLK_IN,
			rising => ENA_1MHZ,
			falling => ENA_1MHZ_N,
			reset => NOT RESETn,

			addr => cpu_ad(3 DOWNTO 0),
			wen => NOT cpu_rw AND NOT CS320n,
			ren => cpu_rw AND NOT CS320n,
			data_in => cpu_do,
			data_out => VIA2_DO,

			port_a_i => via2_pa_in,
			port_a_o => via2_pa_out,
			port_a_t => via2_pa_out_oe,

			port_b_i => via2_pb_in,
			port_b_o => via2_pb_out,
			port_b_t => OPEN,

			ca1_i => '1',
			ca2_o => OPEN,
			ca2_i => '1',
			ca2_t => OPEN,

			cb1_i => '1',
			cb1_o => OPEN,
			cb1_t => OPEN,

			cb2_i => '1',
			cb2_o => UART_TXD,
			cb2_t => OPEN,

			irq => via2_irq
		);

	-- PSG
	psg_a : ay_ym_psg
	PORT MAP(
		ym => PSG_YM,
		clock => CLK_IN,
		ce => ENA_1MHZ_N,
		reset => RESETn,
		bdir => via1_cb2_out,
		bc1 => via1_ca2_out,
		d => via1_pa_out,
		q => psg_do,
		a => PSG_OUT_A,
		b => PSG_OUT_B,
		c => PSG_OUT_C,
		mix => psg_mix,

		ioad => (OTHERS => 'Z'),
		ioaq => ym_o_ioa,
		iobd => (OTHERS => 'Z'),
		iobq => OPEN,

		sel => '1'
	);
	-- three 12 bit channels add up to 12285 at most, so 14 bits hold the mix
	PSG_OUT <= psg_mix(13 DOWNTO 0);

	inst_key : keyboard
	PORT MAP(
		clk_sys => CLK_IN,
		key_pressed => key_pressed,
		key_extended => key_extended,
		key_strobe => key_strobe,
		key_code => key_code,
		row => via1_pb_out (2 DOWNTO 0),
		col => ym_o_ioa,
		key_hit => KEY_HIT,
		swnmi => swnmi,
		swrst => swrst
	);

	KEYB_NMIn <= NOT swnmi;
	KEYB_RESETn <= NOT swrst;

	HCS3119 : ENTITY work.HCS3119
	PORT MAP(
		CLK_SYS => CLK_IN,
		PH2 => ula_PHI2,
		MAPn => ula_MAPn,
		-- Oric Expansion Port Signa
		A => cpu_ad (15 DOWNTO 0), -- 6502 Address Bus
		RnW => cpu_rw, -- 6502 Read-/Write
		IO => ula_CSIOn,
		PA => hcs_pa, -- VIA2 PA lines, or the 0x314 mirror

		CS300n => CS300n,
		CS314n => CS314n,
		CS318n => CS318n,
		CS31Cn => CS31Cn,
		CS320n => CS320n,
		CS340n => CS340n,
		CS342n => CS342n,
		CS343n => CS343n,
		CS360n => CS360n,
		CS1793n => CS1793n,
		CS0n => CS0n,
		CS1n => CS1n,
		CS2n => CS2n,
		CS3n => CS3n,
		CS4n => CS4n,
		CS5n => CS5n,
		CS6n => CS6n,

		WD_CLK => WD_CLK,
		WD_REn => WD_REn,
		WD_WEn => WD_WEn,
		nRESET => NOT RESET AND KEYB_RESETn,
		nHOSTRST => RESETn -- RESET from MCU
	);

	HCS3120 : ENTITY work.HCS3120
	PORT MAP(
		CLK_SYS => CLK_IN,
		WD_CLK => WD_CLK,
		-- Oric Expansion Port Signals
		DI => cpu_do, -- 6502 Data Bus
		--FDC_DAL_OUT => FDC_DAL_OUT,
		DO => CONT_D_OUT, -- 6502 Data Bus
		A => cpu_ad(15 DOWNTO 0), -- 6502 Address Bus
		RnW => cpu_rw, -- 6502 Read-/Write
		nIRQ => cont_irq, -- 6502 /IRQ
		IO => ula_CSIOn, -- Oric I/O 
		CS314n => CS314n,
		CS318n => CS318n,
		CS1793n => CS1793n,
		--IOCTRL    => IOCONTn,                             -- Oric I/O Control           
		-- Additional MCU Interface Lines
		nRESET => RESETn, -- RESET from MCU

		SS => SSEL,
		DS0 => DS0,
		DS1 => DS1,
		DS2 => DS2,
		DS3 => DS3,
		DRIVE => FDC_DRIVE,
		WD_IRQ => WD_IRQ,
		WD_DRQ => WD_DRQ,
		WD_HLD => WD_HLD,
		WD_REn => WD_REn
	);
	HCS10017 : ENTITY work.HCS10017
		PORT MAP(
			CLK => CLK_IN,
			PHI2 => ula_phi2,
			PHI2_EN => ENA_1MHZ,
			PHI2_EN_N => ENA_1MHZ_N,
			CLK_4 => ula_CLK_4,
			CLK_4_EN => ula_CLK_4_en,
			RW => cpu_rw,
			RESETn => pll_locked,
			MAPn => ula_MAPn,
			DB => SRAM_DO,
			ADDR => cpu_ad(15 DOWNTO 0),
			SRAM_AD => ula_AD_SRAM,
			SRAM_OE => ula_OE_SRAM,
			SRAM_CE => ula_CE_SRAM,
			SRAM_WE => ula_WE_SRAM,
			LATCH_SRAM => ula_LATCH_SRAM,
			CSIOn => ula_CSIOn,
			CSRAMn => ula_CSRAMn,
			R => VIDEO_R,
			G => VIDEO_G,
			B => VIDEO_B,
			HBLANK => VIDEO_HBLANK,
			VBLANK => VIDEO_VBLANK,
			CLK_PIX => VIDEO_CLK,
			HSYNC => VIDEO_HSYNC,
			VSYNC => VIDEO_VSYNC
		);

	inst_ACIA : ENTITY work.ACIA
	PORT MAP(
		RESET => RESETn,
		PHI2 => ENA_1MHZ,
		CS => CS31Cn,
		RWN => cpu_rw,
		RS => cpu_ad(1 DOWNTO 0),
		DATAIN => cpu_do,
		DATAOUT => ACIA_DO,
		XTLI => CLK_ACIA,
		RTSB => RTS, --UART_RTS,
		CTSB => RTS, --UART_CTS,
		DTRB => DTR,
		RXD => RXD, --UART_RXD,
		TXD => RXD, --UART_TXD,
		IRQn => acia_irq

	);
	
	Twilighte_inst : ENTITY work.Twilighte
		PORT MAP(
			CLK => CLK_IN,
			R_W => cpu_rw,
			nRESET => RESETn,
			nMAP => ula_MAPn,

			CS314n => CS314n,
			CS340n => CS340n, -- CH376 activation
			CS342n => CS342n, -- Twilighte register
			CS343n => CS343n, -- Twilighte Banking

			PA => via2_pa_out,
			DB_IN => CPU_DO,
			DB_OUT => TWL_DO,

			BANK => BANK,
			ISRAM => ROM_CSn,
			MIRROR_ON => mirror_on,
			MIRROR_ROM => mirror_rom
		);

	DS1501 : ENTITY work.DS1501
		PORT MAP(
			CLK => CLK_IN,
			RESETn => RESETn,
			ADDR => cpu_ad(2 DOWNTO 0),
			RTC => RTC,
			DATA_OUT => RTC_DO
		);
		
	-- Backend selection. With both backends present the one not selected
	-- sees no accesses: the emulated core gets no chip select and the bridge
	-- keeps the CH_* bus idle.
	CH376_EMU_SEL <= '1' WHEN CH376_BACKEND = 1 ELSE
	                 CH376_VIRTUAL WHEN CH376_BACKEND = 2 ELSE
	                 '0';
	CH376_EMU_CSn <= CS340n OR NOT CH376_EMU_SEL;
	CH376_PHY_ENA <= NOT CH376_EMU_SEL;
	CH376_DO <= CH376_EMU_DO WHEN CH376_EMU_SEL = '1' ELSE CH376_PHY_DO;

	gen_ch376_emulated : IF CH376_BACKEND /= 0 GENERATE
		-- The 6502 commits its accesses on ENA_1MHZ_N (T65 Enable), so the
		-- CH376 side effects happen once per access on the same enable.
		ch376_core_inst : ENTITY work.ch376_core
			PORT MAP (
				CLK          => CLK_IN,
				RESETn       => RESETn,
				ENA          => ENA_1MHZ_N,
				CSn          => CH376_EMU_CSn,
				A0           => cpu_ad(0),
				RnW          => cpu_rw,
				DIN          => cpu_do,
				DOUT         => CH376_EMU_DO,
				SD_LBA       => SD_LBA,
				SD_RD        => SD_RD,
				SD_WR        => SD_WR,
				SD_ACK       => SD_ACK,
				SD_BUFF_ADDR => SD_BUFF_ADDR,
				SD_BUFF_DOUT => SD_BUFF_DOUT,
				SD_BUFF_WR   => SD_BUFF_WR,
				SD_BUFF_DIN  => SD_BUFF_DIN,
				IMG_MOUNTED  => IMG_MOUNTED,
				IMG_SIZE     => IMG_SIZE
			);
	END GENERATE;

	gen_ch376_no_emulated : IF CH376_BACKEND = 0 GENERATE
		CH376_EMU_DO <= (OTHERS => '1');
		SD_LBA       <= (OTHERS => '0');
		SD_RD        <= '0';
		SD_WR        <= '0';
		SD_BUFF_DIN  <= (OTHERS => '0');
	END GENERATE;

	gen_ch376_bridge : IF CH376_BACKEND /= 1 GENERATE
		ch376_inst : ENTITY work.ch376_interface
			PORT MAP (
				clk      => CLK_IN,
				PH2      => ula_phi2,
				reset_n  => RESETn,
				ena      => CH376_PHY_ENA,
				addr     => cpu_ad(15 DOWNTO 0),
				data_in  => cpu_do,
				data_out => CH376_PHY_DO,
				data     => CH_D,
				RnW      => cpu_rw,
				cs340n   => CS340n,
				cs       => CH_CS,
				wr       => CH_WR,
				rd       => CH_RD,
				a0       => CH_A0
			);
	END GENERATE;

	gen_ch376_no_bridge : IF CH376_BACKEND = 1 GENERATE
		CH376_PHY_DO <= (OTHERS => '1');
		CH_D  <= (OTHERS => 'Z');
		CH_A0 <= '0';
		CH_RD <= '1';
		CH_WR <= '1';
		CH_CS <= '1';
	END GENERATE;
		  
		  
	via1_pa_in <= (via1_pa_out AND NOT via1_pa_out_oe_l) OR (psg_do AND via1_pa_out_oe_l);
	via1_pb_in(2 DOWNTO 0) <= via1_pb_out(2 DOWNTO 0);
	via1_pb_in(3) <= KEY_HIT;
	via1_pb_in(4) <= via1_pb_out(4);
	via1_pb_in(5) <= 'Z';
	via1_pb_in(6) <= via1_pb_out(6);
	via1_pb_in(7) <= via1_pb_out(7);

	K7_TAPEOUT <= via1_pb_out(7);
	K7_REMOTE <= via1_pb_out(6);
	PRN_STROBE <= via1_pb_out(4);
	PRN_DATA <= via1_pa_out;

	-- Joystick ports on VIA2 (as Oricutron joystick.c): PB7 selects the right
	-- port (joystick_0), PB6 the left one (joystick_1), both may be selected
	-- and are then combined; PB0-PB4 read right, left, fire, down and up,
	-- active low. Fire 2 and fire 3 of the right port go to PA7 and PA5.
	joy_sel0 <= (OTHERS => via2_pb_out(7));
	joy_sel1 <= (OTHERS => via2_pb_out(6));
	joy_mux  <= NOT (joystick_0 AND joy_sel0) AND NOT (joystick_1 AND joy_sel1);

	via2_pb_in <= NOT via2_pb_out(7) & via2_pb_out(6) & via2_pb_out(5) & joy_mux;
	via2_pa_in <= NOT (fire2_t1 AND via2_pb_out(7)) & UART_RXD & NOT (fire3_t1 AND via2_pb_out(7)) & via2_pa_out(4) & '1' & via2_pa_out(2 DOWNTO 0);

	rom_ad <= ROM_CSn & bank & cpu_ad (13 DOWNTO 0);
	-- Only CPU writes to the banked area may reach the board SDRAM. Without this
	-- qualification any write (zero page, stack, screen) made while a board RAM
	-- bank was selected was mirrored into that bank using A13:0.
	hcs_pa <= via2_pa_out(2 DOWNTO 0) WHEN mirror_on = '0' ELSE
	          "110" WHEN mirror_rom = '1' ELSE
	          "000";

	BANK_SEL <= '1' WHEN cpu_ad(15 DOWNTO 14) = "11" AND ula_MAPn = '1' ELSE '0';

	-- Main RAM as decoded by the HCS10017 (CSRAMn) but without its PHI2
	-- gating, so that the SDRAM address is settled before rom_rd and rom_wr
	-- rise with PHI2: 0x0000-0xBFFF except page 3 with MAPn high, and the
	-- overlay RAM at 0xC000-0xFFFF with MAPn low.
	MAIN_RAM_SEL <= '1' WHEN (cpu_ad(15 DOWNTO 14) = "11" AND ula_MAPn = '0') OR
	                         (cpu_ad(15 DOWNTO 14) /= "11" AND cpu_ad(15 DOWNTO 8) /= x"03" AND ula_MAPn = '1')
	                ELSE '0';
	ram_sel <= MAIN_RAM_SEL;

	rom_rd <= cpu_rw AND ula_phi2;
	rom_wr <= NOT cpu_rw AND ula_phi2 AND (BANK_SEL OR MAIN_RAM_SEL);
	rom_q <= cpu_do;

--process (CLK_IN)
--begin
--    if rising_edge(CLK_IN) then
--        -- La señal `ch_cs` siempre se actualiza con el valor de `cs340n`
--        ch_cs <= cs340n;
--
--        if cs340n = '0' and ula_phi2 = '1' then
--            -- Control de datos
--            if cpu_rw = '0' then
--                ch_d <= cpu_do; -- Escritura en el bus de datos
--            else
--                ch_d <= (others => 'Z'); -- Alta impedancia para lectura
--					 ch376_do <=  ch_d;
--            end if;
--
--            -- Control de direcciones y señales de lectura/escritura
--            ch_a0 <= cpu_ad(0); -- Dirección A0
--            ch_wr <= not cpu_rw; -- Señal de escritura
--            ch_rd <= cpu_rw; -- Señal de lectura
--        else
--            -- Estado predeterminado para las señales cuando no está activo
--            ch_d  <= (others => 'Z'); -- Alta impedancia
--            ch_wr <= '1';             -- Escritura desactivada
--            ch_rd <= '1';             -- Lectura desactivada
--        end if;
--    end if;
--end process;

--	ch_d  <= cpu_do when (cpu_rw = '0' and cs340n = '0') else (others => 'Z');
--	ch_a0 <= cpu_ad (0);
--   ch_wr <= cpu_rw;
--   ch_rd <= not cpu_rw;
--   ch_cs <= CS340n;
----	
	cpu_di <= --CPU_DO WHEN cpu_rw = '0' ELSE
		VIA1_DO WHEN cs300n = '0' ELSE
		CONT_D_OUT  WHEN CS314n = '0' ELSE
		CONT_D_OUT  WHEN CS318n = '0' ELSE
		FDC_DAL_OUT WHEN CS1793n = '0' ELSE
		ACIA_DO  WHEN CS31Cn = '0' ELSE
		VIA2_DO  WHEN CS320n = '0' ELSE

      ch376_do     WHEN CS340n = '0' else
		TWL_DO   WHEN CS342n = '0' ELSE
		TWL_DO   WHEN CS343n = '0' ELSE

		RTC_DO WHEN CS360n = '0' ELSE -- placeholder for rtc
		ROM_D WHEN ula_CSRAMn = '0' ELSE  -- main RAM, from the SDRAM
		ROM_D;
	--			 CPU_DI_LAST;

	--process (CLK_IN) begin
	--	if rising_edge(CLK_IN) then
	--		if cpu_rw = '1' and ula_phi2 = '1' then
	--			cpu_di_last <= cpu_di;
	--		end if;
	--	end if;
	--end process;

END RTL;