# Timing constraints for the Orix core on the SiDi (CLOCK_27, no HDMI).
#
# PLL outputs (pll.v):
#   clk[0] clk_sys  24 MHz  machine (ULA, CPUs, VIAs, CH376 softcore)
#   clk[1] clk_acia  1 MHz  6551 baud rate generator (XTLI)
#   clk[2] clk_hdmi 48 MHz  unused on the SiDi (no HDMI)
#   clk[3] clk_ram  96 MHz  SDRAM controller, 4 x clk_sys, same PLL
# clk_sys, clk_hdmi and clk_ram are related and their crossings are timed.

create_clock -name {CLOCK_27} -period 37.037 [get_ports {CLOCK_27}]
create_clock -name {SPI_SCK}  -period 41.666 -waveform { 20.8 41.666 } [get_ports {SPI_SCK}]

derive_pll_clocks
derive_clock_uncertainty

set clk_sys  {pll|altpll_component|auto_generated|pll1|clk[0]}
set clk_acia {pll|altpll_component|auto_generated|pll1|clk[1]}

# The HCS10017 ULA divides clk_sys with a 24 state one hot ring (c) and a
# 3 state phase ring (ph), and two of those registers are used as clocks:
#  - c[15], high for one clk_sys cycle in 24, clocks the 6551 ACIA (PHI2 =>
#    ENA_1MHZ in telestrat.vhd), on both edges;
#  - ph[2], high for 8 clk_sys cycles in 24 (the 1 MHz PHI2), samples the
#    HCS3119 reset.
create_generated_clock -name ula_c15 -source [get_pins -compatibility_mode {*pll1|clk[0]}] \
	-edges {1 3 49} [get_registers {telestrat:telestrat|HCS10017:HCS10017|c[15]}]
create_generated_clock -name ula_ph2 -source [get_pins -compatibility_mode {*pll1|clk[0]}] \
	-edges {1 17 49} [get_registers {telestrat:telestrat|HCS10017:HCS10017|ph[2]}]

# SPI from the ARM (user_io, data_io, OSD) is asynchronous to the core
set_clock_groups -asynchronous -group [get_clocks {SPI_SCK}] \
	-group [get_clocks {pll|altpll_component|auto_generated|pll1|clk[*] ula_c15 ula_ph2}]

# The baud rate clock only feeds the ACIA divider, whose outputs are sampled
# by the transmitter and receiver many PHI2 cycles later
set_clock_groups -asynchronous -group [get_clocks $clk_acia] \
	-group [get_clocks [list $clk_sys ula_c15 ula_ph2]]

# clk_sys <-> clk_ram (sdram.sv). The controller detects the rising edge of
# rd or we (old_rd, old_we) and only then uses addr, din and wtbt, at least
# one clk_ram later. The CPUs update address, data and R/W on their enable
# (HCS10017 c[23]), 16 clk_sys before PHI2 rises (rom_rd and rom_wr are gated
# by PHI2), and so does the main RAM select (ram_sel); the HCS3119 reset only
# changes them while the machine is being reset. The read data goes back to
# the CPU, which only latches it on its 1 MHz enable at the end of PHI2. One
# clk_sys period is therefore safe in both directions, except:
#  - the edge detectors, which must see rd and we within one clk_ram;
#  - the strobe sources (PHI2 = ULA ph[2], the RAM clear write and the ioctl
#    write) and the ioctl address and data, which change on the same clk_sys
#    edge as ioctl_wr. These keep the default single cycle requirement (node
#    exceptions take precedence over clock exceptions).
set clk_ram {pll|altpll_component|auto_generated|pll1|clk[3]}
set sdram_regs [remove_from_collection [get_registers {sdram:sdram|*}] [get_registers {sdram:sdram|old_rd sdram:sdram|old_we}]]
set strobes [get_registers {*HCS10017|ph[2] *ram_clear_we data_io:data_io|ioctl_wr data_io:data_io|ioctl_addr[*] data_io:data_io|ioctl_dout[*]}]

set_multicycle_path -from [get_clocks $clk_ram] -to [get_clocks $clk_sys] -setup -start 4
set_multicycle_path -from [get_clocks $clk_ram] -to [get_clocks $clk_sys] -hold  -start 3
set_multicycle_path -from [get_clocks [list $clk_sys ula_ph2]] -to $sdram_regs -setup -end 4
set_multicycle_path -from [get_clocks [list $clk_sys ula_ph2]] -to $sdram_regs -hold  -end 3
set_multicycle_path -from $strobes -to $sdram_regs -setup -end 1
set_multicycle_path -from $strobes -to $sdram_regs -hold  -end 0
