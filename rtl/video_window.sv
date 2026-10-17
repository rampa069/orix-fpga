// video_window
// Output timing for the scandoubled VGA and HDMI paths.
// Copyright 2026 rampa
//
// This is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License,
// or any later version.
//
// The HCS10017 ULA only marks the 240 x 224 paper area as active and places
// its vertical sync for a PAL television. That is right for 15 kHz RGB, but
// after the scandoubler:
//  - an HDMI sink takes the DE area as the whole picture and scales it to the
//    panel (the television reported 960 x 448), so the picture is stretched
//    and cropped at the sides by overscan;
//  - a VGA monitor treats the 31 kHz signal as a 480 line mode that starts
//    about 35 lines after vertical sync, so the paper sits too low and its
//    bottom is cut.
//
// This module leaves the ULA untouched and derives a display window with a
// black border around the paper:
//  - vertically 240 source lines (480 output lines), the paper plus 8 lines
//    above and below, with a two line output vertical sync (as long as the
//    ULA one, a one line pulse lost sync on a VGA monitor) so that the window
//    starts 17 source lines (34 output lines) after the start of vertical
//    sync, close to the 2 + 33 lines of 640 x 480;
//  - VGA keeps the ULA horizontal sync and uses the paper plus 10 pixels on
//    each side;
//  - HDMI uses a window of 348 pixels (16:9 with the PAL pixel aspect of
//    about 1.229) or 260 pixels (4:3), and a horizontal sync of its own placed
//    in the gap left by the wide window.
// Outside the paper the colour is forced to black, since the ULA keeps
// sending the last paper colour of the line during the border.
//
// Coordinates: x is the pixel (6 MHz) index from the first paper pixel of
// the line, y the line index from the first paper line of the frame. All
// outputs are registered on the pixel enable, one pixel after the inputs.

module video_window
(
	input            clk,        // clk_sys, 24 MHz
	input            ce,         // ULA pixel enable, 6 MHz
	input            hblank,     // ULA paper blanking (registered on ce)
	input            vblank,
	input            r_in,
	input            g_in,
	input            b_in,
	input            hdmi_wide,  // 1 = 16:9 HDMI window, 0 = 4:3

	output reg       r,          // colour, black outside the paper
	output reg       g,
	output reg       b,

	output reg       vga_hs_n,
	output reg       vga_vs_n,
	output reg       vga_hb,
	output reg       vga_vb,

	output reg       hdmi_hs_n,
	output reg       hdmi_vs_n,
	output reg       hdmi_hb,
	output reg       hdmi_vb
);

localparam [8:0] LINE_PIXELS  = 9'd384;  // 64 us at 6 MHz
localparam [8:0] PAPER_W      = 9'd240;
localparam [8:0] PAPER_H      = 9'd224;

localparam [8:0] VGA_BORDER   = 9'd10;   // pixels each side
localparam [8:0] WIDE_BORDER  = 9'd54;   // pixels each side, 16:9
localparam [8:0] V_BORDER     = 9'd8;    // lines above and below
localparam [8:0] VS_LEAD      = 9'd18;   // gives 17 full lines between the vertical sync line and the window

// ULA horizontal sync starts at character 49, the paper at character 1:
// 48 characters of 6 pixels after the paper start, 5 characters long.
// The VGA sync is generated here with the same width, starting 2 characters
// later than the ULA one, which centred the picture on a VGA monitor on the
// SiDi128 (the ULA position left the picture too far right). It stays out of
// the VGA window (x 250 to 373).
localparam [8:0] VGA_HS_X     = 9'd300;
localparam [8:0] VGA_HS_W     = 9'd30;
// HDMI horizontal sync, inside the gap of the 16:9 window (x 294 to 329)
localparam [8:0] HDMI_HS_X    = 9'd296;
localparam [8:0] HDMI_HS_W    = 9'd16;

reg  [8:0] x;
reg  [8:0] y;
reg  [8:0] y_last = 9'd311;              // last line of the frame (311 at 50 Hz, 259 at 60 Hz)
reg        hblank_d;
reg        vblank_at_line;               // vblank at the previous paper start

wire       line_start = hblank_d & ~hblank;
wire [8:0] xn = line_start ? 9'd0 : x + 9'd1;
wire       frame_start = line_start & vblank_at_line & ~vblank;
wire [8:0] yn = frame_start ? 9'd0 : line_start ? y + 9'd1 : y;

// Display row: a window row starts at its left edge (x = 330 for the widest
// window), before the paper start where y advances, so the pixels from there
// to the end of the line already belong to the next row. Without this the
// first and last window rows would be split across two output lines.
localparam [8:0] ROW_X = LINE_PIXELS - WIDE_BORDER;
wire [8:0] yd = (xn < ROW_X) ? yn : (yn == y_last) ? 9'd0 : yn + 9'd1;

wire       v_win = (yd < PAPER_H + V_BORDER) || (yd >= y_last + 9'd1 - V_BORDER);
wire [8:0] vs_line = y_last + 9'd1 - V_BORDER - VS_LEAD;

wire       vga_h_win  = (xn < PAPER_W + VGA_BORDER)  || (xn >= LINE_PIXELS - VGA_BORDER);
wire       wide_h_win = (xn < PAPER_W + WIDE_BORDER) || (xn >= LINE_PIXELS - WIDE_BORDER);
wire       hdmi_h_win = hdmi_wide ? wide_h_win : vga_h_win;

always @(posedge clk) begin
	if (ce) begin
		hblank_d <= hblank;
		x <= xn;
		y <= yn;
		if (line_start) vblank_at_line <= vblank;
		if (frame_start) y_last <= y;

		r <= (hblank | vblank) ? 1'b0 : r_in;
		g <= (hblank | vblank) ? 1'b0 : g_in;
		b <= (hblank | vblank) ? 1'b0 : b_in;

		vga_hs_n <= ~((xn >= VGA_HS_X) && (xn < VGA_HS_X + VGA_HS_W));
		vga_hb   <= ~vga_h_win;
		vga_vb   <= ~v_win;
		// vertical sync edges aligned with the start of horizontal sync
		if (xn == VGA_HS_X) vga_vs_n <= (yd != vs_line) && (yd != vs_line + 9'd1);

		hdmi_hs_n <= ~((xn >= HDMI_HS_X) && (xn < HDMI_HS_X + HDMI_HS_W));
		hdmi_hb   <= ~hdmi_h_win;
		hdmi_vb   <= ~v_win;
		if (xn == HDMI_HS_X) hdmi_vs_n <= (yd != vs_line);
	end
end

endmodule
