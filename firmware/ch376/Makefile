# Firmware of the emulated CH376 (T65 softcore), built with cc65.
#
#   make          build ch376fw.bin and regenerate ../../rtl/ch376_fw_rom.vhd
#   make clean

CC65    ?= cc65
CA65    ?= ca65
LD65    ?= ld65
PYTHON  ?= python3

CFLAGS  = -t none --cpu 6502 -O -Oi -Or -Os -I . -I fatfs
AFLAGS  = --cpu 6502
CC65_LIB = $(shell $(CC65) --print-target-path 2>/dev/null)/../lib/none.lib
ifeq ($(wildcard $(CC65_LIB)),)
CC65_LIB = $(dir $(shell which $(CC65)))../share/cc65/lib/none.lib
endif

BUILD   = build
OBJS    = $(BUILD)/crt0.o $(BUILD)/fatscan.o $(BUILD)/main.o $(BUILD)/diskio.o $(BUILD)/ff.o
ROM_VHD = ../../rtl/ch376_fw_rom.vhd

all: $(ROM_VHD)

$(ROM_VHD): $(BUILD)/ch376fw.bin mkrom.py
	$(PYTHON) mkrom.py $< $@

$(BUILD)/ch376fw.bin: $(OBJS) ch376fw.cfg
	$(LD65) -C ch376fw.cfg -m $(BUILD)/ch376fw.map -o $@ $(OBJS) $(CC65_LIB)

$(BUILD)/%.o: $(BUILD)/%.s
	$(CA65) $(AFLAGS) -o $@ $<

$(BUILD)/crt0.o: crt0.s | $(BUILD)
	$(CA65) $(AFLAGS) -o $@ $<

$(BUILD)/fatscan.o: fatscan.s | $(BUILD)
	$(CA65) $(AFLAGS) -o $@ $<

$(BUILD)/main.s: main.c hw.h fatfs/ff.h fatfs/ffconf.h | $(BUILD)
	$(CC65) $(CFLAGS) -o $@ $<

$(BUILD)/diskio.s: diskio.c hw.h fatfs/ff.h fatfs/diskio.h fatfs/ffconf.h | $(BUILD)
	$(CC65) $(CFLAGS) -o $@ $<

$(BUILD)/ff.s: fatfs/ff.c fatfs/ff.h fatfs/ffconf.h fatfs/diskio.h | $(BUILD)
	$(CC65) $(CFLAGS) -o $@ $<

$(BUILD):
	mkdir -p $@

clean:
	rm -rf $(BUILD)

.PHONY: all clean
.PRECIOUS: $(BUILD)/%.s
