//============================================================================
//  Oric Telestrat
//  rampa@encomix.org
//
//============================================================================
`default_nettype none

module guest_top
  #
  (
   parameter  TOT_DISKS = 1
   )
(
	input         CLOCK_27,
`ifdef USE_CLOCK_50
	input         CLOCK_50,
`endif

	output        LED,
	output [VGA_BITS-1:0] VGA_R,
	output [VGA_BITS-1:0] VGA_G,
	output [VGA_BITS-1:0] VGA_B,
	output        VGA_HS,
	output        VGA_VS,

`ifdef USE_HDMI
	output        HDMI_RST,
	output  [7:0] HDMI_R,
	output  [7:0] HDMI_G,
	output  [7:0] HDMI_B,
	output        HDMI_HS,
	output        HDMI_VS,
	output        HDMI_PCLK,
	output        HDMI_DE,
	inout         HDMI_SDA,
	inout         HDMI_SCL,
	input         HDMI_INT,
`endif

	input         SPI_SCK,
	inout         SPI_DO,
	input         SPI_DI,
	input         SPI_SS2,    // data_io
	input         SPI_SS3,    // OSD
	input         CONF_DATA0, // SPI_SS for user_io

`ifdef USE_QSPI
	input         QSCK,
	input         QCSn,
	inout   [3:0] QDAT,
`endif
`ifndef NO_DIRECT_UPLOAD
	input         SPI_SS4,
`endif

	output [12:0] SDRAM_A,
	inout  [15:0] SDRAM_DQ,
	output        SDRAM_DQML,
	output        SDRAM_DQMH,
	output        SDRAM_nWE,
	output        SDRAM_nCAS,
	output        SDRAM_nRAS,
	output        SDRAM_nCS,
	output  [1:0] SDRAM_BA,
	output        SDRAM_CLK,
	output        SDRAM_CKE,

`ifdef DUAL_SDRAM
	output [12:0] SDRAM2_A,
	inout  [15:0] SDRAM2_DQ,
	output        SDRAM2_DQML,
	output        SDRAM2_DQMH,
	output        SDRAM2_nWE,
	output        SDRAM2_nCAS,
	output        SDRAM2_nRAS,
	output        SDRAM2_nCS,
	output  [1:0] SDRAM2_BA,
	output        SDRAM2_CLK,
	output        SDRAM2_CKE,
`endif

`ifdef USE_EXTBUS
  inout  [7:0]  CH_D ,
  output        CH_RD,
  output        CH_WR,
  output        CH_A0,
  output        CH_CS,
`endif



	output        AUDIO_L,
	output        AUDIO_R,
`ifdef I2S_AUDIO
	output        I2S_BCK,
	output        I2S_LRCK,
	output        I2S_DATA,
`endif
`ifdef I2S_AUDIO_HDMI
	output        HDMI_MCLK,
	output        HDMI_BCK,
	output        HDMI_LRCK,
	output        HDMI_SDATA,
`endif
`ifdef SPDIF_AUDIO
	output        SPDIF,
`endif
`ifdef USE_AUDIO_IN
	input         AUDIO_IN,
`endif
	input         UART_RX,
	output        UART_TX

);

`ifdef NO_DIRECT_UPLOAD
localparam bit DIRECT_UPLOAD = 0;
wire SPI_SS4 = 1;
`else
localparam bit DIRECT_UPLOAD = 1;
`endif

`ifdef USE_QSPI
localparam bit QSPI = 1;
assign QDAT = 4'hZ;
`else
localparam bit QSPI = 0;
`endif

`ifdef VGA_8BIT
localparam VGA_BITS = 8;
`else
localparam VGA_BITS = 6;
`endif

`ifdef USE_HDMI
localparam bit HDMI = 1;
assign HDMI_RST = 1'b1;
`else
localparam bit HDMI = 0;
`endif

`ifdef BIG_OSD
localparam bit BIG_OSD = 1;
`define SEP "-;",
`else
localparam bit BIG_OSD = 0;
`define SEP
`endif

`ifdef USE_AUDIO_IN
localparam bit USE_AUDIO_IN = 1;
wire TAPE_SOUND=AUDIO_IN;
`else
localparam bit USE_AUDIO_IN = 0;
wire TAPE_SOUND=UART_RX;
`endif


`include "build_id.v"
localparam CONF_STR = {
	"ORIX;;",
	"F0,ROMR64,Load Cartridge;",
	"S0U,IMGVHD,Mount CH376 SD;",
	"-;",
	// the pages only group the options, the status bits keep their meaning
	// (saved configurations stay valid)
	"P1,System;",
	"P1O23,CPU,6502,65C02,65C816;",
`ifdef USE_EXTBUS
	"P1O7,CH376,Virtual,Real;",
`endif
	"P2,Video;",
	"P2O45,Scanlines,Off,25%,50%,75%;",
`ifdef USE_HDMI
	"P2O6,HDMI aspect,16:9,4:3;",
`endif
	"P3,Audio;",
	"P3OA,PSG,AY-3-8912,YM2149;",
	"P3O89,Stereo,Off,ABC (West Europe),ACB (East Europe);",
	"P3OC,Tape sound,Off,On;",
	"-;",
	"T0,Reset;",
	"TB,Cold reset (clear board RAM);",
	"V,v",`BUILD_DATE
};


/////////////////////// CLOCKS ////////////////////////////

wire        clk_sys;   // 24 Mhz
wire        clk_acia;  // 1 Mhz
wire        clk_hdmi;  // 48 MHz, exactly 2 x clk_sys so the ULA video is sampled synchronously
wire        clk_ram;   // 96 Mhz
wire        locked;


pll pll
(
`ifdef USE_CLOCK_50
	.inclk0(CLOCK_50),
`else
	.inclk0(CLOCK_27),        // SiDi: 27 MHz, its pll.v gives the same outputs
`endif
	.c0(clk_sys),
	.c1(clk_acia),
	.c2(clk_hdmi),
	.c3(clk_ram),	
	.locked(locked)
);


// Both CPUs run from reset, but only the selected one drives the bus: the
// other executes on data meant for the first and its state is meaningless.
// Changing the CPU type therefore resets the machine. The pulse is stretched
// (1024 clocks, about 43 us) since HCS3119 samples its reset input on PH2.
// Changing the CH376 backend resets it too, since Orix only probes the CH376
// at boot.
reg  [2:0] cpu_mode_d;
reg [10:0] cpu_reset_cnt = 0;
always @(posedge clk_sys) begin
	cpu_mode_d <= {status[7], status[3:2]};
	if (cpu_mode_d != {status[7], status[3:2]})
		cpu_reset_cnt <= 11'd1024;
	else if (cpu_reset_cnt != 0)
		cpu_reset_cnt <= cpu_reset_cnt - 1'd1;
end

wire       ram_clear_busy;     // board RAM clear after power up, see below
wire       reset = status[0] || buttons[1] || ~locked || ioctl_download || (cpu_reset_cnt != 0) || ram_clear_busy;
//assign LED=~rom_address[19];

//////////////////// HPS ///////////////////////////////


wire [15:0] joy0;
wire [15:0] joy1;
wire  [4:0] joy_t0={joy0[3],joy0[2],joy0[4],joy0[1],joy0[0]}; //Up,Down,Fire,Left,Right
wire  [4:0] joy_t1={joy1[3],joy1[2],joy1[4],joy1[1],joy1[0]};
wire        fire2_t1=joy1[5]; 
wire        fire3_t1=joy1[6]; 
wire        forced_scandoubler;
wire [127:0] status;

wire [31:0] sd_lba[TOT_DISKS];
wire  [TOT_DISKS-1:0] sd_rd;
wire  [TOT_DISKS-1:0] sd_wr;
wire  [TOT_DISKS-1:0] sd_ack;
wire  [8:0] sd_buff_addr;
wire  [7:0] sd_buff_dout;
wire  [7:0] sd_buff_din[TOT_DISKS];
wire        sd_buff_wr;
wire        sd_ack_conf;
wire        sd_conf;
wire        sd_sdhc = 1'b1;

wire  [TOT_DISKS-1:0] img_mounted;
wire [31:0] img_size;
wire        img_readonly;

wire        ioctl_wr;
wire [24:0] ioctl_addr;
wire  [7:0] ioctl_dout;
wire        ioctl_download;
wire  [7:0] ioctl_index;

reg         status_set;
reg  [31:0] status_out;

wire [21:0] gamma_bus;
wire        no_csync;
wire [63:0] rtc;



`ifdef USE_HDMI
wire        i2c_start;
wire        i2c_read;
wire  [6:0] i2c_addr;
wire  [7:0] i2c_subaddr;
wire  [7:0] i2c_dout;
wire  [7:0] i2c_din;
wire        i2c_ack;
wire        i2c_end;
`endif

wire  [1:0] buttons, switches;
wire			ypbpr;
wire        scandoubler_disable;
wire        key_pressed;
wire [7:0]  key_code;
wire        key_strobe;
wire        key_extended;


user_io #(.STRLEN($size(CONF_STR)>>3), .SD_IMAGES(TOT_DISKS), .FEATURES(32'h0 | (BIG_OSD << 13) | (HDMI << 14))) user_io
(	
	.clk_sys        	(clk_sys         	),
	.clk_sd           (clk_sys           ),
	.conf_str       	(CONF_STR       	),
	.SPI_CLK        	(SPI_SCK        	),
	.SPI_SS_IO      	(CONF_DATA0     	),
	.SPI_MISO       	(SPI_DO        	),
	.SPI_MOSI       	(SPI_DI         	),

`ifdef USE_HDMI
	.i2c_start      (i2c_start      ),
	.i2c_read       (i2c_read       ),
	.i2c_addr       (i2c_addr       ),
	.i2c_subaddr    (i2c_subaddr    ),
	.i2c_dout       (i2c_dout       ),
	.i2c_din        (i2c_din        ),
	.i2c_ack        (i2c_ack        ),
	.i2c_end        (i2c_end        ),
`endif

	.buttons        	(buttons        	),
	.switches       	(switches      	),
	.scandoubler_disable (scandoubler_disable	),
	.ypbpr          	(ypbpr          	),
	.key_strobe     	(key_strobe     	),
	.key_pressed    	(key_pressed    	),
	.key_extended   	(key_extended   	),
	.key_code       	(key_code       	),
	.joystick_0       ( joy0      ),
	.joystick_1       ( joy1      ),
	.status         	(status         	),
	
	.rtc              (rtc),
	.no_csync         (no_csync         ),
	// SD CARD
   .sd_lba                      (sd_lba[0]     ),
	.sd_rd                       (sd_rd         ),
	.sd_wr                       (sd_wr         ),
	.sd_ack                      (sd_ack        ),
	.sd_ack_conf                 (sd_ack_conf   ),
	.sd_conf                     (sd_conf       ),
	.sd_sdhc                     (sd_sdhc       ),
	.sd_dout                     (sd_buff_dout  ),
	.sd_dout_strobe              (sd_buff_wr    ),
	.sd_din                      (sd_buff_din[0]),
//	.sd_din_strobe               (sd_din_strobe ),
	.sd_buff_addr                (sd_buff_addr  ),
	.img_mounted                 (img_mounted   ),
	.img_size                    (img_size      )
);

data_io data_io(
	.clk_sys       ( clk_sys      ),
	.SPI_SCK       ( SPI_SCK       ),
	.SPI_SS2       ( SPI_SS2       ),
	.SPI_DI        ( SPI_DI        ),
	.clkref_n      ( 1'b0          ),
	.ioctl_download( ioctl_download),
	.ioctl_index   ( ioctl_index   ),
	.ioctl_wr      ( ioctl_wr      ),
	.ioctl_addr    ( ioctl_addr    ),
	.ioctl_dout    ( ioctl_dout    )
);


//////////////////////// ROM CARTRIDGE ////////////

wire[19:0] rom_address;
wire[7:0]  rom_data;
wire[7:0]  rom_q;
reg        rom_rd;
reg        rom_wr;
wire       isRAM = rom_address[19];
wire       ram_sel;          // CPU access to main RAM, served by the SDRAM
wire[23:0] cpu_ad;
wire [7:0] cpu_do;


altddio_out
#(
        .extend_oe_disable("OFF"),
        .intended_device_family("Cyclone 10 LP"),
        .invert_output("OFF"),
        .lpm_hint("UNUSED"),
        .lpm_type("altddio_out"),
        .oe_reg("UNREGISTERED"),
        .power_up_high("OFF"),
        .width(1)
)


sdramclk_ddr
(
        .datain_h(1'b0),
        .datain_l(1'b1),
        .outclock(clk_ram),
        .dataout(SDRAM_CLK),
        .aclr(1'b0),
        .aset(1'b0),
        .oe(1'b1),
        .outclocken(1'b1),
        .sclr(1'b0),
        .sset(1'b0)
);


// SDRAM map (byte addresses): 0x000000 cartridge ROM banks, 0x080000 board
// RAM banks (rom_address[19] = 1), 0x100000 the 64 KB main RAM.
//
// The Twilighte board RAM (the high 512 KB of the cartridge area in SDRAM,
// rom_address[19] = 1) has no battery: it starts empty on the real board.
// The SDRAM keeps whatever it held (for instance from the previous core), and
// the Orix bank listing shows a RAM bank as used whenever its byte at 0xFFF0
// is not 0. Clear it once after power up, holding the machine in reset. It is
// not cleared on a reset (F11), as the real board RAM survives one, only on
// the OSD cold reset. The main RAM that follows it is cleared too, so that it
// starts at zero like the video shadow in block RAM.
// One byte every 8 clk_sys keeps the address stable for 32 clk_ram after the
// write strobe, enough for the controller to take it even behind a refresh;
// 576 KB take about 200 ms. A cartridge download meanwhile takes priority.
reg [20:0] ram_clear_addr;
reg [14:0] ram_clear_delay;
reg  [2:0] ram_clear_phase;
reg        ram_clear_we;
reg        ram_clear_run = 1'b1;
always @(posedge clk_sys) begin
	if (~locked || status[11]) begin   // power up or OSD cold reset
		ram_clear_run   <= 1'b1;
		ram_clear_delay <= 0;
		ram_clear_addr  <= 21'h080000;
		ram_clear_phase <= 0;
		ram_clear_we    <= 1'b0;
	end else if (ram_clear_run) begin
		if (~&ram_clear_delay) begin
			// let the SDRAM controller finish its initialisation first (about 680 us)
			ram_clear_delay <= ram_clear_delay + 1'd1;
		end else if (ioctl_download) begin
			ram_clear_we <= 1'b0;
		end else begin
			ram_clear_phase <= ram_clear_phase + 1'd1;
			ram_clear_we    <= (ram_clear_phase == 3'd1);
			if (ram_clear_phase == 3'd7) begin
				if (ram_clear_addr == 21'h10FFFF)
					ram_clear_run <= 1'b0;
				else
					ram_clear_addr <= ram_clear_addr + 1'd1;
			end
		end
	end
end
assign ram_clear_busy = ram_clear_run;

sdram sdram
(
   .*,
   .init(~locked),
   .clk(clk_ram),

   .wtbt(0),
   .addr(ioctl_download ? ioctl_addr : ram_clear_run ? {4'd0, ram_clear_addr} :
         ram_sel ? {9'h010, cpu_ad[15:0]} : {5'd0, rom_address}),
   .rd(ram_clear_run ? 1'b0 : rom_rd),
   .dout(rom_data),
   .din (ioctl_download ? ioctl_dout : ram_clear_run ? 8'h00 : rom_q),
   .we  (ioctl_download ? ioctl_wr : ram_clear_run ? ram_clear_we : (ram_sel | isRAM) ? rom_wr : 1'b0),
   .ready()
);


///////////////////////////////////////////////////



wire tape_in;
wire tape_out;
wire cas_relay;

wire  [11:0] psg_a;
wire  [11:0] psg_b;
wire  [11:0] psg_c;
wire  [13:0] psg_out;

wire  [1:0] stereo = status [9:8];

wire        r, g, b; 
wire        hs, vs, HBlank, VBlank;
wire        clk_pix;


wire [15:0] ram_ad;
wire  [7:0] ram_d;
wire        ram_we,ram_cs;

// Video shadow: the ULA reads the video memory on the ram_* port with only
// 2 to 3 clk_sys between address and data, too little for the SDRAM, so its
// reads come from a block RAM copy of 0x9800-0xC3FF, written together with
// the main RAM in SDRAM. That range holds every address the HCS10017 can
// generate: the character sets (0x9800-0x9FFF, 0xB400-0xBBFF), the hires
// screen (0xA000-0xBF57, lines 0 to 199 only, text is forced from line 200)
// and the text screen counter, which reaches 0xC1D7 in the last blanking line.
localparam [15:0] SHADOW_BASE = 16'h9800;
localparam        SHADOW_SIZE = 11264;            // 11 KB, up to 0xC3FF
wire [15:0] shadow_off = ram_ad - SHADOW_BASE;
wire        shadow_hit = (ram_ad >= SHADOW_BASE) && (shadow_off < SHADOW_SIZE);
reg   [7:0] ram[SHADOW_SIZE];
always @(posedge clk_sys) begin
	if(ram_we & ram_cs & shadow_hit) ram[shadow_off[13:0]] <= ram_d;
end

wire  [7:0] ram_q;
always @(posedge clk_sys) ram_q <= ram[shadow_off[13:0]];


//assign CH_CS=0;

// CH376: every board gets the emulated one on user_io image slot 0. Boards
// with the external bus also have the bridge to a physical CH376 on the CH_*
// pins, and the OSD chooses between both.
`ifdef USE_EXTBUS
localparam CH376_BACKEND = 2;
wire       ch376_virtual = ~status[7];
`else
localparam CH376_BACKEND = 1;
wire       ch376_virtual = 1'b1;
`endif

assign sd_conf = 1'b0;

telestrat #(.CH376_BACKEND(CH376_BACKEND)) telestrat
(
	.clk_in           (clk_sys),
	.RESET            (reset),
	.clk_acia         (clk_acia),
	
	.key_pressed      (key_pressed),
	.key_code         (key_code),
	.key_extended     (key_extended),
	.key_strobe       (key_strobe),
	.PSG_OUT_A        (psg_a),
	.PSG_OUT_B        (psg_b),
	.PSG_OUT_C        (psg_c),
	.PSG_OUT          (psg_out),
	.VIDEO_CLK			(clk_pix),
	.VIDEO_R				(r),
	.VIDEO_G				(g),
	.VIDEO_B				(b),
	.VIDEO_HSYNC		(hs),
	.VIDEO_VSYNC		(vs),
	.VIDEO_HBLANK		(HBlank),
	.VIDEO_VBLANK		(VBlank),

	.K7_TAPEIN        (tape_in ),
	.K7_TAPEOUT       (tape_out),
	.K7_REMOTE        (cas_relay),
	
	.RTC              (rtc),

	.ram_ad           (ram_ad),
	.ram_d            (ram_d),
	.ram_q            (ram_q),
	.ram_cs           (ram_cs),
	.ram_oe           (),
	.ram_we           (ram_we),
	
	.rom_ad           (rom_address),
	.rom_q            (rom_q),
	.rom_d            (rom_data),
	.rom_rd           (rom_rd),
	.rom_wr           (rom_wr),
	.ram_sel          (ram_sel),
	
	.mode             (status[3:2]),
	.debug            (LED),

`ifdef USE_EXTBUS
	.ch_d             (CH_D),
   .ch_cs            (CH_CS),	
   .ch_a0            (CH_A0),	
   .ch_rd            (CH_RD),	
   .ch_wr            (CH_WR),	
`endif

	.ch376_virtual    (ch376_virtual),
	.psg_ym           (status[10]),

	.sd_lba           (sd_lba[0]),
	.sd_rd            (sd_rd[0]),
	.sd_wr            (sd_wr[0]),
	.sd_ack           (sd_ack),
	.sd_buff_addr     (sd_buff_addr),
	.sd_buff_dout     (sd_buff_dout),
	.sd_buff_wr       (sd_buff_wr),
	.sd_buff_din      (sd_buff_din[0]),
	.img_mounted      (img_mounted[0]),
	.img_size         (img_size),
	
	.joystick_0       (joy_t0),
	.joystick_1       (joy_t1),
	.fire2_t1         (fire2_t1),
	.fire3_t1         (fire3_t1),
	
	.cpu_ad           (cpu_ad),
	.cpu_do           (cpu_do),
	
//  .WD_REn           (WD_REn),
//	.WD_WEn           (WD_WEn), 
//   .WD_DRQ           (fdd_drq),
//	.WD_IRQ           (fdd_irq),
//	.WD_HLD           (fdd_hld),
//	.WD_CLK           (WD_CLK),
//	.WD_RESET         (WD_RESET),
//	.FDC_DAL_OUT      (fdc_dal_out),
//	.CS1793n          (CS1793n),
//	.SSEL             (SSEL),
//	.DS0              (DS0),
//	.DS1              (DS1),
//	.DS2              (DS2),
//	.DS3              (DS3),
	
	.pll_locked       (locked),
	.UART_TXD         (UART_TX),
	.UART_RXD         (UART_RX),
	.UART_CTS         (),
	.UART_RTS         ()
	
);


/////////////////// VIDEO PROCESSING ////////////////////////////////

// The ULA only marks the paper as active and times its syncs for a PAL
// television. video_window derives the scandoubled VGA and HDMI timing (see
// rtl/video_window.sv), so VGA and HDMI each get their own mist_video. The
// 15 kHz RGB output keeps the ULA signals unchanged.

wire       vw_r, vw_g, vw_b;
wire       vw_vga_hs, vw_vga_vs, vw_vga_hb, vw_vga_vb;
wire       vw_hdmi_hs, vw_hdmi_vs, vw_hdmi_hb, vw_hdmi_vb;

video_window video_window
(
	.clk       ( clk_sys      ),
	.ce        ( clk_pix      ),
	.hblank    ( HBlank       ),
	.vblank    ( VBlank       ),
	.r_in      ( r            ),
	.g_in      ( g            ),
	.b_in      ( b            ),
	.hdmi_wide ( ~status[6]   ),
	.r         ( vw_r         ),
	.g         ( vw_g         ),
	.b         ( vw_b         ),
	.vga_hs_n  ( vw_vga_hs    ),
	.vga_vs_n  ( vw_vga_vs    ),
	.vga_hb    ( vw_vga_hb    ),
	.vga_vb    ( vw_vga_vb    ),
	.hdmi_hs_n ( vw_hdmi_hs   ),
	.hdmi_vs_n ( vw_hdmi_vs   ),
	.hdmi_hb   ( vw_hdmi_hb   ),
	.hdmi_vb   ( vw_hdmi_vb   )
);

// VGA: clk_sys / (3 + 1) = 6 MHz, one sample per ULA pixel, with the
// video_window VGA timing; 15 kHz RGB gets the ULA signals unchanged.
wire vga_native = scandoubler_disable;
wire [VGA_BITS-1:0] vga_r_o, vga_g_o, vga_b_o;
wire                vga_hs_o, vga_vs_o;

mist_video #(
	.COLOR_DEPTH(1),
	.SD_HCNT_WIDTH(11),
	.OUT_COLOR_DEPTH(VGA_BITS),
	.USE_BLANKS(1'b0),          // as the VGA chains of the Atmos and ZEMMIX cores; HDMI keeps them
	.BIG_OSD(BIG_OSD)
) vga_video (
	.clk_sys        ( clk_sys          ),
	.SPI_SCK        ( SPI_SCK          ),
	.SPI_SS3        ( SPI_SS3          ),
	.SPI_DI         ( SPI_DI           ),
	.R              ( vga_native ? r      : vw_r      ),
	.G              ( vga_native ? g      : vw_g      ),
	.B              ( vga_native ? b      : vw_b      ),
	.HBlank         ( vga_native ? HBlank : vw_vga_hb ),
	.VBlank         ( vga_native ? VBlank : vw_vga_vb ),
	.HSync          ( vga_native ? hs     : vw_vga_hs ),
	.VSync          ( vga_native ? vs     : vw_vga_vs ),
	.VGA_R          ( vga_r_o          ),
	.VGA_G          ( vga_g_o          ),
	.VGA_B          ( vga_b_o          ),
	.VGA_VS         ( vga_vs_o         ),
	.VGA_HS         ( vga_hs_o         ),
	.ce_divider     ( 3'd3             ),
	.rotate         ( 2'b00            ),
	.blend          ( 1'b0             ),
	.scandoubler_disable(scandoubler_disable),
	.scanlines      ( status[5:4]      ),
	.ypbpr          ( ypbpr            ),
	.no_csync       ( no_csync         )
);

`ifdef USE_HDMI
// HDMI: always scandoubled. clk_hdmi is 48 MHz, exactly 2 x clk_sys from the
// same PLL, so clk_hdmi / (7 + 1) = 6 MHz samples each ULA pixel once and
// HDMI_PCLK stays above the 25 MHz TMDS minimum.
mist_video #(
	.COLOR_DEPTH(1),
	.SD_HCNT_WIDTH(11),
	.OUT_COLOR_DEPTH(8),
	.USE_BLANKS(1'b1),
	.BIG_OSD(BIG_OSD),
	.VIDEO_CLEANER(1'b1)
) hdmi_video (
	.clk_sys        ( clk_hdmi         ),
	.SPI_SCK        ( SPI_SCK          ),
	.SPI_SS3        ( SPI_SS3          ),
	.SPI_DI         ( SPI_DI           ),
	.R              ( vw_r             ),
	.G              ( vw_g             ),
	.B              ( vw_b             ),
	.HBlank         ( vw_hdmi_hb       ),
	.VBlank         ( vw_hdmi_vb       ),
	.HSync          ( vw_hdmi_hs       ),
	.VSync          ( vw_hdmi_vs       ),
	.VGA_R          ( HDMI_R           ),
	.VGA_G          ( HDMI_G           ),
	.VGA_B          ( HDMI_B           ),
	.VGA_VS         ( HDMI_VS          ),
	.VGA_HS         ( HDMI_HS          ),
	.VGA_DE         ( HDMI_DE          ),
	.ce_divider     ( 3'd7             ),
	.rotate         ( 2'b00            ),
	.blend          ( 1'b0             ),
	.scandoubler_disable( 1'b0         ),
	.scanlines      ( status[5:4]      ),
	.ypbpr          ( 1'b0             ),
	.no_csync       ( 1'b1             )
);
`endif

assign VGA_R  = vga_r_o;
assign VGA_G  = vga_g_o;
assign VGA_B  = vga_b_o;
assign VGA_HS = vga_hs_o;
assign VGA_VS = vga_vs_o;

`ifdef USE_HDMI
i2c_master #(48_000_000) i2c_master (
	.CLK         (clk_hdmi),
	.I2C_START   (i2c_start),
	.I2C_READ    (i2c_read),
	.I2C_ADDR    (i2c_addr),
	.I2C_SUBADDR (i2c_subaddr),
	.I2C_WDATA   (i2c_dout),
	.I2C_RDATA   (i2c_din),
	.I2C_END     (i2c_end),
	.I2C_ACK     (i2c_ack),

	//I2C bus
	.I2C_SCL     (HDMI_SCL),
	.I2C_SDA     (HDMI_SDA)
);	
assign HDMI_PCLK = clk_hdmi;

`endif

//	mist_video #(.COLOR_DEPTH(1), .SD_HCNT_WIDTH(11), .OUT_COLOR_DEPTH(VGA_BITS),.USE_BLANKS(1), .BIG_OSD(BIG_OSD)) mist_video (	
//	.clk_sys      (clk_sys     ),
//	.SPI_SCK      (SPI_SCK    ),
//	.SPI_SS3      (SPI_SS3    ),
//	.SPI_DI       (SPI_DI     ),
//	.R            (r          ),
//	.G            (g          ),
//	.B            (b          ),
//	.HSync        ( hs        ),
//	.VSync        ( vs        ),	
//	.HBlank       ( HBlank    ),
//	.VBlank       ( VBlank    ),	
//	.VGA_R        (VGA_R      ),
//	.VGA_G        (VGA_G      ),
//	.VGA_B        (VGA_B      ),
//	.VGA_VS       (VGA_VS     ),
//	.VGA_HS       (VGA_HS     ),
//	.ce_divider   (1'b0       ),
//	.scandoubler_disable(scandoubler_disable),
//	.scanlines    (status[5:4]),
//	.ypbpr        (ypbpr      )
//	);
//
//`ifdef USE_HDMI
//
//  i2c_master #(28_000_000) i2c_master (
//	.CLK         (clk_hdmi),
//	.I2C_START   (i2c_start),
//	.I2C_READ    (i2c_read),
//	.I2C_ADDR    (i2c_addr),
//	.I2C_SUBADDR (i2c_subaddr),
//	.I2C_WDATA   (i2c_dout),
//	.I2C_RDATA   (i2c_din),
//	.I2C_END     (i2c_end),
//	.I2C_ACK     (i2c_ack),
//
//	//I2C bus
//	.I2C_SCL     (HDMI_SCL),
//	.I2C_SDA     (HDMI_SDA)
//);
//
//mist_video #(.COLOR_DEPTH(1), .SD_HCNT_WIDTH(11), .OUT_COLOR_DEPTH(8), .USE_BLANKS(1), .BIG_OSD(BIG_OSD), .VIDEO_CLEANER(1)) hdmi_video (
//	.clk_sys     ( clk_hdmi   ),
//
//	.SPI_SCK     ( SPI_SCK    ),
//	.SPI_SS3     ( SPI_SS3    ),
//	.SPI_DI      ( SPI_DI     ),
//
//	.scanlines   ( status[5:4]  ),
//
//	.ce_divider  ( 3'd1       ),
//
//	.scandoubler_disable ( scandoubler_disable ),
//	.no_csync    ( 1'b1       ),
//	.ypbpr       ( 1'b0       ),
//	.rotate      ( 2'b00      ),
//	.blend       ( 1'b0       ),
//
//	.R           ( r ),
//	.G           ( g ),
//	.B           ( b ),
//
//	.HBlank      ( HBlank      ),
//	.VBlank      ( VBlank      ),
//	.HSync       ( hs      ),
//	.VSync       ( vs      ),
//
//	.VGA_R       ( HDMI_R      ),
//	.VGA_G       ( HDMI_G      ),
//	.VGA_B       ( HDMI_B      ),
//	.VGA_VS      ( HDMI_VS     ),
//	.VGA_HS      ( HDMI_HS     ),
//	.VGA_DE      ( HDMI_DE     )
//);
//assign HDMI_PCLK = clk_hdmi;
//
//`endif


////////////////////// AUDIO MIXING /////////////////////////////
wire [15:0] psg_l;
wire [15:0] psg_r;
reg [12:0] psg_ab;
reg [12:0] psg_ac;
reg [12:0] psg_bc;


always @ (clk_sys,psg_a,psg_b,psg_c) begin
 psg_ab <= {{1'b0,psg_a} + {1'b0,psg_b}};
 psg_ac <= {{1'b0,psg_a} + {1'b0,psg_c}};
 psg_bc <= {{1'b0,psg_b} + {1'b0,psg_c}};
end

assign psg_l = (stereo == 2'b00) ? {psg_out,2'b0} : (stereo == 2'b01) ? {psg_ab,3'b0}: {psg_ac,3'b0};
assign psg_r = (stereo == 2'b00) ? {psg_out,2'b0} : (stereo == 2'b01) ? {psg_bc,3'b0}: {psg_bc,3'b0};

wire [15:0] dac_in_l,dac_in_r;

// OSD tape sound: the cassette input added to both channels, saturated
wire [15:0] tape_snd = (status[12] & tape_in) ? 16'h0800 : 16'h0000;
wire [16:0] mix_l = psg_l + tape_snd;
wire [16:0] mix_r = psg_r + tape_snd;
assign dac_in_l = mix_l[16] ? 16'hFFFF : mix_l[15:0];
assign dac_in_r = mix_r[16] ? 16'hFFFF : mix_r[15:0];


dac #(
   .c_bits	(16))
audiodac_l(
   .clk_i	(clk_sys	),
   .res_n_i	(1	),
   .dac_i	(dac_in_l),
   .dac_o	(AUDIO_L)
  );

dac #(
   .c_bits	(16))
audiodac_r(
   .clk_i	(clk_sys	),
   .res_n_i	(1	),
   .dac_i	(dac_in_r),
   .dac_o	(AUDIO_R)
  );

wire [31:0] clk_rate =  32'd24_000_000;

`ifdef I2S_AUDIO
i2s i2s (
	.reset(1'b0),
	.clk(clk_sys),
	.clk_rate(clk_rate),

	.sclk(I2S_BCK),
	.lrclk(I2S_LRCK),
	.sdata(I2S_DATA),

	.left_chan ({~dac_in_l[15],dac_in_l[14:0]}),
	.right_chan({~dac_in_r[15],dac_in_r[14:0]})
);
`ifdef I2S_AUDIO_HDMI
assign HDMI_MCLK = 0;
always @(posedge clk_sys) begin
	HDMI_BCK <= I2S_BCK;
	HDMI_LRCK <= I2S_LRCK;
	HDMI_SDATA <= I2S_DATA;
end
`endif
`endif

`ifdef SPDIF_AUDIO
spdif spdif (
	.clk_i(clk_sys),
	.rst_i(1'b0),
	.clk_rate_i(clk_rate),
	.spdif_o(SPDIF),
	.sample_i({dac_in_r, dac_in_l})
);
`endif



assign tape_in = TAPE_SOUND;

endmodule


