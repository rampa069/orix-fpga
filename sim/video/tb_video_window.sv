`timescale 1ns/1ps
// Testbench for video_window: a model of the HCS10017 video timing
// (same equations as rtl/HCS10017.vhd) feeding the module, and measurements
// of the resulting VGA and HDMI geometry.
module tb;
reg clk = 0;
always #20.833 clk = ~clk;   // 24 MHz

// ULA model
reg [23:0] c = 24'd1;
reg [5:0]  h = 0;
reg [8:0]  v = 0;
wire ce     = c[1] | c[5] | c[9] | c[13] | c[17] | c[21];
wire ce_chr = c[15];
wire hs_n   = !((h >= 49) && (h <= 53));
wire vs_n   = !((v >= 258) && (v <= 259));
wire hbl_n  = (h >= 1) && (h <= 40);
wire vbl_n  = (v < 224);
reg  hblank = 1, vblank = 1;
// pattern: white everywhere the ULA would show it, paper or not
wire rgb_in = 1'b1;

always @(posedge clk) begin
	c <= {c[22:0], c[23]};
	if (ce_chr) begin
		h <= h + 1'd1;
		if (h == 63) v <= (v < 312) ? v + 1'd1 : 9'd0;   // as in the VHDL: 313 lines?
	end
	if (ce) begin
		hblank <= !hbl_n;
		vblank <= !vbl_n;
	end
end

wire r, g, b, vga_hs_n, vga_vs_n, vga_hb, vga_vb, hdmi_hs_n, hdmi_vs_n, hdmi_hb, hdmi_vb;
reg  wide = 1;

video_window dut (
	.clk(clk), .ce(ce), .hblank(hblank), .vblank(vblank),
	.r_in(rgb_in), .g_in(rgb_in), .b_in(rgb_in), .hdmi_wide(wide),
	.r(r), .g(g), .b(b),
	.vga_hs_n(vga_hs_n), .vga_vs_n(vga_vs_n), .vga_hb(vga_hb), .vga_vb(vga_vb),
	.hdmi_hs_n(hdmi_hs_n), .hdmi_vs_n(hdmi_vs_n), .hdmi_hb(hdmi_hb), .hdmi_vb(hdmi_vb)
);

// Measurements on the pixel enable, per output set
integer px;                    // pixel index within the line, from output hsync start
integer line_px, lines;
integer vga_win_w, vga_win_l, vga_paper_w, vga_paper_l;
integer hd_win_w, hd_win_l, hd_hs_w, hd_hs_l, vga_hs_w;
integer vga_vs_to_win, hd_vs_to_win, win_lines, paper_lines, frame_lines;
integer vga_white_out_of_win, hd_white_out_of_win;
reg     vga_hs_d = 1, hd_hs_d = 1, vga_vs_d = 1, hd_vs_d = 1;
integer vga_x, hd_x, vga_y, hd_y;
integer vga_first_win_x, hd_first_win_x, vga_first_paper_x, hd_first_paper_x;
integer vga_vs_y, hd_vs_y, vga_first_win_y, hd_first_win_y, first_paper_y;
integer cnt_win, cnt_paper, cnt_hdwin;
integer frames = 0;
integer line_has_win, line_has_paper;

initial begin
	vga_x = 0; hd_x = 0; vga_y = 0; hd_y = 0;
	vga_vs_y = -1; hd_vs_y = -1; vga_first_win_y = -1; hd_first_win_y = -1; first_paper_y = -1;
	vga_white_out_of_win = 0; hd_white_out_of_win = 0; win_lines = 0; paper_lines = 0;
end

// Per line accumulators (VGA reference: line starts at output hsync fall)
integer l_win, l_paper, l_hdwin, l_hdhs, l_vgahs, l_win_first, l_paper_first, l_hdwin_first, l_hdhs_first;
integer report_frame = 3;

always @(posedge clk) if (ce) begin
	// VGA line
	if (vga_hs_d & ~vga_hs_n) begin
		if (frames == report_frame && l_win > 0 && vga_y == 100) begin
			$display("VGA  line: hsync %0d px, window %0d px from x=%0d, paper %0d px from x=%0d (relative to hsync start)",
				l_vgahs, l_win, l_win_first, l_paper, l_paper_first);
			$display("HDMI line: hsync %0d px at x=%0d, window %0d px from x=%0d (relative to VGA hsync start)",
				l_hdhs, l_hdhs_first, l_hdwin, l_hdwin_first);
		end
		if (frames == report_frame) begin
			if (l_win   > 0) win_lines   = win_lines + 1;
			if (l_paper > 0) paper_lines = paper_lines + 1;
			if (l_win > 0 && vga_first_win_y < 0) vga_first_win_y = vga_y;
			if (l_paper > 0 && first_paper_y < 0) first_paper_y = vga_y;
		end
		vga_x = 0; vga_y = vga_y + 1;
		l_win = 0; l_paper = 0; l_hdwin = 0; l_hdhs = 0; l_vgahs = 0;
		l_win_first = -1; l_paper_first = -1; l_hdwin_first = -1; l_hdhs_first = -1;
	end else vga_x = vga_x + 1;
	if (vga_vs_d & ~vga_vs_n) begin $display("t=%0t VGA vsync, frames=%0d vga_y=%0d", $time, frames, vga_y);
		if (frames == report_frame) begin
			$display("frame: %0d lines from VGA vsync to VGA vsync", vga_y);
			$display("VGA: window starts %0d lines after vsync, %0d window lines, %0d paper lines, paper starts %0d lines after vsync",
				vga_first_win_y, win_lines, paper_lines, first_paper_y);
			$display("white pixels outside VGA window: %0d, outside HDMI window: %0d", vga_white_out_of_win, hd_white_out_of_win);
		end
		frames = frames + 1;
		vga_y = 0; win_lines = 0; paper_lines = 0; vga_first_win_y = -1; first_paper_y = -1;
		vga_white_out_of_win = 0; hd_white_out_of_win = 0;
	end
	if (hd_vs_d & ~hdmi_vs_n && frames == report_frame) $display("HDMI vsync at VGA line %0d", vga_y);
	vga_hs_d = vga_hs_n; vga_vs_d = vga_vs_n; hd_hs_d = hdmi_hs_n; hd_vs_d = hdmi_vs_n;

	if (!vga_hs_n) l_vgahs = l_vgahs + 1;
	if (!hdmi_hs_n) begin if (l_hdhs_first < 0) l_hdhs_first = vga_x; l_hdhs = l_hdhs + 1; end
	if (!vga_hb && !vga_vb) begin if (l_win_first < 0) l_win_first = vga_x; l_win = l_win + 1; end
	if (!hdmi_hb && !hdmi_vb) begin if (l_hdwin_first < 0) l_hdwin_first = vga_x; l_hdwin = l_hdwin + 1; end
	if (r) begin if (l_paper_first < 0) l_paper_first = vga_x; l_paper = l_paper + 1; end
	if (r && (vga_hb || vga_vb))  vga_white_out_of_win = vga_white_out_of_win + 1;
	if (r && (hdmi_hb || hdmi_vb)) hd_white_out_of_win = hd_white_out_of_win + 1;
	if (!hdmi_hs_n && !(hdmi_hb || hdmi_vb)) $display("ERROR: HDMI hsync inside DE at line %0d x %0d", vga_y, vga_x);
end

initial begin
	#125000000;
	wide = 0; report_frame = 6;
	#80000000;
	$finish;
end
initial begin
	#125000000;
	$display("--- 4:3 HDMI window ---");
end
endmodule
