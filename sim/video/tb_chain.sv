`timescale 1ns/1ps
// Full output chain simulation: HCS10017 timing model -> video_window ->
// mist_video (VGA at 24 MHz, HDMI at 48 MHz), plus the previous chain
// (mist_dual_video at 48 MHz fed with the raw ULA signals) for comparison.
// Measures what reaches the VGA and HDMI pins.
module tb;
reg clk48 = 0;
always #10.4167 clk48 = ~clk48;
reg clk24 = 0;
always @(posedge clk48) clk24 <= ~clk24;

// ULA model on clk24
reg [23:0] c = 24'd1;
reg [5:0]  h = 0;
reg [8:0]  v = 0;
wire ce     = c[1] | c[5] | c[9] | c[13] | c[17] | c[21];
wire ce_chr = c[15];
wire hs_n   = !((h >= 49) && (h <= 53));
wire vs_n   = !((v >= 258) && (v <= 259));
reg  hblank = 1, vblank = 1;
wire pix    = 1'b1;
always @(posedge clk24) begin
	c <= {c[22:0], c[23]};
	if (ce_chr) begin
		h <= h + 1'd1;
		if (h == 63) v <= (v < 312) ? v + 1'd1 : 9'd0;
	end
	if (ce) begin
		hblank <= !((h >= 1) && (h <= 40));
		vblank <= !(v < 224);
	end
end

wire vw_r, vw_g, vw_b, vga_hs, vga_vs, vga_hb, vga_vb, hd_hs, hd_vs, hd_hb, hd_vb;
video_window vw (
	.clk(clk24), .ce(ce), .hblank(hblank), .vblank(vblank),
	.r_in(pix), .g_in(pix), .b_in(pix), .hdmi_wide(1'b1),
	.r(vw_r), .g(vw_g), .b(vw_b),
	.vga_hs_n(vga_hs), .vga_vs_n(vga_vs), .vga_hb(vga_hb), .vga_vb(vga_vb),
	.hdmi_hs_n(hd_hs), .hdmi_vs_n(hd_vs), .hdmi_hb(hd_hb), .hdmi_vb(hd_vb));

wire [5:0] VGA_R, VGA_G, VGA_B; wire VGA_HS, VGA_VS;
mist_video #(.COLOR_DEPTH(1), .SD_HCNT_WIDTH(11), .OUT_COLOR_DEPTH(6), .USE_BLANKS(1'b1), .BIG_OSD(1'b1)) vga_video (
	.clk_sys(clk24), .SPI_SCK(1'b0), .SPI_SS3(1'b1), .SPI_DI(1'b0),
	.R(vw_r), .G(vw_g), .B(vw_b), .HBlank(vga_hb), .VBlank(vga_vb), .HSync(vga_hs), .VSync(vga_vs),
	.VGA_R(VGA_R), .VGA_G(VGA_G), .VGA_B(VGA_B), .VGA_VS(VGA_VS), .VGA_HS(VGA_HS),
	.ce_divider(3'd3), .rotate(2'b00), .blend(1'b0), .scandoubler_disable(1'b0),
	.scanlines(2'b00), .ypbpr(1'b0), .no_csync(1'b0));

wire [7:0] HD_R, HD_G, HD_B; wire HD_HS, HD_VS, HD_DE;
mist_video #(.COLOR_DEPTH(1), .SD_HCNT_WIDTH(11), .OUT_COLOR_DEPTH(8), .USE_BLANKS(1'b1), .BIG_OSD(1'b1), .VIDEO_CLEANER(1'b1)) hdmi_video (
	.clk_sys(clk48), .SPI_SCK(1'b0), .SPI_SS3(1'b1), .SPI_DI(1'b0),
	.R(vw_r), .G(vw_g), .B(vw_b), .HBlank(hd_hb), .VBlank(hd_vb), .HSync(hd_hs), .VSync(hd_vs),
	.VGA_R(HD_R), .VGA_G(HD_G), .VGA_B(HD_B), .VGA_VS(HD_VS), .VGA_HS(HD_HS), .VGA_DE(HD_DE),
	.ce_divider(3'd7), .rotate(2'b00), .blend(1'b0), .scandoubler_disable(1'b0),
	.scanlines(2'b00), .ypbpr(1'b0), .no_csync(1'b1));

// Previous VGA chain: raw ULA signals through mist_video at 48 MHz, divider 7
wire [5:0] OV_R, OV_G, OV_B; wire OV_HS, OV_VS;
mist_video #(.COLOR_DEPTH(1), .SD_HCNT_WIDTH(11), .OUT_COLOR_DEPTH(6), .USE_BLANKS(1'b1), .BIG_OSD(1'b1)) old_video (
	.clk_sys(clk48), .SPI_SCK(1'b0), .SPI_SS3(1'b1), .SPI_DI(1'b0),
	.R(pix), .G(pix), .B(pix), .HBlank(hblank), .VBlank(vblank), .HSync(hs_n), .VSync(vs_n),
	.VGA_R(OV_R), .VGA_G(OV_G), .VGA_B(OV_B), .VGA_VS(OV_VS), .VGA_HS(OV_HS),
	.ce_divider(3'd7), .rotate(2'b00), .blend(1'b0), .scandoubler_disable(1'b0),
	.scanlines(2'b00), .ypbpr(1'b0), .no_csync(1'b0));

// Generic sync meter: hsync period/width (ns), vsync period/width (in hsync lines), levels
task automatic dummy; endtask
`define METER(NAME, HS, VS) \
	real NAME``_hs_fall = 0, NAME``_hs_per = 0, NAME``_hs_w = 0; \
	integer NAME``_lines = 0, NAME``_vs_lines = 0, NAME``_frame_lines = 0, NAME``_vs_w = 0, NAME``_frames = 0; \
	integer NAME``_hs_lo = 0, NAME``_hs_hi = 0, NAME``_vs_lo = 0, NAME``_vs_hi = 0; \
	always @(negedge HS) begin \
		if (NAME``_hs_fall > 0) NAME``_hs_per = $realtime - NAME``_hs_fall; \
		NAME``_hs_fall = $realtime; NAME``_lines = NAME``_lines + 1; \
		if (!VS) NAME``_vs_lines = NAME``_vs_lines + 1; \
	end \
	always @(posedge HS) NAME``_hs_w = $realtime - NAME``_hs_fall; \
	always @(negedge VS) begin \
		NAME``_frame_lines = NAME``_lines; NAME``_lines = 0; NAME``_frames = NAME``_frames + 1; \
	end \
	always @(posedge VS) begin NAME``_vs_w = NAME``_vs_lines; NAME``_vs_lines = 0; end \
	always @(posedge clk48) begin \
		if (HS) NAME``_hs_hi = NAME``_hs_hi + 1; else NAME``_hs_lo = NAME``_hs_lo + 1; \
		if (VS) NAME``_vs_hi = NAME``_vs_hi + 1; else NAME``_vs_lo = NAME``_vs_lo + 1; \
	end

`METER(nv, VGA_HS, VGA_VS)
`METER(hd, HD_HS, HD_VS)
`METER(ov, OV_HS, OV_VS)

initial begin
	#150000000;
	$display("              hs period   hs low   lines/frame  vs low lines  frames  hs low%%  vs low%%");
	$display("old VGA   : %8.1f ns %7.1f ns %8d %10d %10d %7.2f %7.2f", ov_hs_per, ov_hs_w, ov_frame_lines, ov_vs_w, ov_frames, 100.0*ov_hs_lo/(ov_hs_lo+ov_hs_hi), 100.0*ov_vs_lo/(ov_vs_lo+ov_vs_hi));
	$display("new VGA   : %8.1f ns %7.1f ns %8d %10d %10d %7.2f %7.2f", nv_hs_per, nv_hs_w, nv_frame_lines, nv_vs_w, nv_frames, 100.0*nv_hs_lo/(nv_hs_lo+nv_hs_hi), 100.0*nv_vs_lo/(nv_vs_lo+nv_vs_hi));
	$display("new HDMI  : %8.1f ns %7.1f ns %8d %10d %10d %7.2f %7.2f", hd_hs_per, hd_hs_w, hd_frame_lines, hd_vs_w, hd_frames, 100.0*hd_hs_lo/(hd_hs_lo+hd_hs_hi), 100.0*hd_vs_lo/(hd_vs_lo+hd_vs_hi));
	$finish;
end
endmodule
