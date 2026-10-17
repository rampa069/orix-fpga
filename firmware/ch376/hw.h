/*
 * hw.h - memory map of the CH376 softcore (T65)
 * Copyright 2026 rampa
 *
 * This is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License,
 * or any later version.
 *
 *   0x0000-0x0FFF  RAM (4 KB)
 *   0x2000-0x20FF  CH376 shared buffer (rtl/ch376_host.vhd, firmware port)
 *   0x2100-0x210F  CH376 host interface registers
 *   0x2200-0x23FF  SD sector buffer (512 bytes, shared with user_io)
 *   0x2400-0x240F  SD control registers
 *   0x8000-0xFFFF  ROM (firmware, 32 KB)
 */

#ifndef HW_H
#define HW_H

#define REG8(a)       (*(volatile unsigned char *)(a))

/* CH376 host interface */
#define H_BUF         ((volatile unsigned char *)0x2000)
#define H_CMD         REG8(0x2100)
#define H_FLAGS       REG8(0x2101)  /* bit 0 request, bit 1 cancel I/O, bit 7 busy */
#define H_POS         REG8(0x2102)
#define H_COUNT       REG8(0x2103)
#define H_STATUS      REG8(0x2104)
#define H_IFSTAT      REG8(0x2105)
#define H_USB_MODE    REG8(0x2106)
#define H_CTRL        REG8(0x2107)  /* write: bit 0 done, bit 1 clear cancel I/O */
#define H_SIZE        ((volatile unsigned char *)0x2108)
#define H_OFFSET      ((volatile unsigned char *)0x210C)

#define H_FLAG_REQUEST  0x01
#define H_FLAG_CANCEL   0x02
#define H_CTRL_DONE     0x01
#define H_CTRL_CANCEL   0x02

/* SD block access through user_io image 0 */
#define SD_BUF        ((volatile unsigned char *)0x2200)
#define SD_LBA        ((volatile unsigned char *)0x2400)
#define SD_CTRL       REG8(0x2404)  /* write: bit 0 read, bit 1 write, bit 7 clear change
                                       read: bit 0 busy, bit 1 image mounted, bit 7 image changed */
#define SD_SIZE       ((volatile unsigned char *)0x2408)

#define SD_CTRL_READ    0x01
#define SD_CTRL_WRITE   0x02
#define SD_CTRL_CHANGE  0x80
#define SD_STAT_BUSY    0x01
#define SD_STAT_MOUNTED 0x02
#define SD_STAT_CHANGED 0x80

#endif
