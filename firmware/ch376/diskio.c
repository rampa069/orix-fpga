/*
 * diskio.c - FatFs disk I/O on the user_io SD image of the CH376 softcore
 * Copyright 2026 rampa
 *
 * This is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License,
 * or any later version.
 *
 * One drive: the image mounted from the OSD on user_io image slot 0.
 * Sectors go through the 512 byte buffer at 0x2200; the transfer itself is
 * done by the hardware (rtl/ch376_core.vhd) and the MiST firmware.
 */

#include <string.h>
#include "fatfs/ff.h"
#include "fatfs/diskio.h"
#include "hw.h"

static void sd_set_lba(LBA_t lba)
{
	SD_LBA[0] = (BYTE)(lba);
	SD_LBA[1] = (BYTE)(lba >> 8);
	SD_LBA[2] = (BYTE)(lba >> 16);
	SD_LBA[3] = (BYTE)(lba >> 24);
}

static void sd_wait(void)
{
	while (SD_CTRL & SD_STAT_BUSY)
		;
}

/* Read a sector and leave it in the SD buffer; used by the free cluster scan
   of main.c, which counts straight from the buffer. Returns 0 on error. */
unsigned char sd_read_sector(LBA_t lba)
{
	if (!(SD_CTRL & SD_STAT_MOUNTED))
		return 0;
	sd_set_lba(lba);
	SD_CTRL = SD_CTRL_READ;
	sd_wait();
	return 1;
}

DSTATUS disk_status(BYTE pdrv)
{
	if (pdrv != 0)
		return STA_NOINIT;
	return (SD_CTRL & SD_STAT_MOUNTED) ? 0 : (STA_NOINIT | STA_NODISK);
}

DSTATUS disk_initialize(BYTE pdrv)
{
	return disk_status(pdrv);
}

DRESULT disk_read(BYTE pdrv, BYTE *buff, LBA_t sector, UINT count)
{
	if (disk_status(pdrv))
		return RES_NOTRDY;
	while (count--) {
		sd_set_lba(sector++);
		SD_CTRL = SD_CTRL_READ;
		sd_wait();
		memcpy(buff, (const void *)SD_BUF, 512);
		buff += 512;
	}
	return RES_OK;
}

DRESULT disk_write(BYTE pdrv, const BYTE *buff, LBA_t sector, UINT count)
{
	if (disk_status(pdrv))
		return RES_NOTRDY;
	while (count--) {
		memcpy((void *)SD_BUF, buff, 512);
		sd_set_lba(sector++);
		SD_CTRL = SD_CTRL_WRITE;
		sd_wait();
		buff += 512;
	}
	return RES_OK;
}

DRESULT disk_ioctl(BYTE pdrv, BYTE cmd, void *buff)
{
	if (disk_status(pdrv))
		return RES_NOTRDY;
	switch (cmd) {
	case CTRL_SYNC:
		/* every write is complete when disk_write returns */
		return RES_OK;
	case GET_SECTOR_COUNT:
		*(LBA_t *)buff = ((LBA_t)SD_SIZE[1] >> 1) | ((LBA_t)SD_SIZE[2] << 7) |
		                 ((LBA_t)SD_SIZE[3] << 15);
		return RES_OK;
	case GET_SECTOR_SIZE:
		*(WORD *)buff = 512;
		return RES_OK;
	case GET_BLOCK_SIZE:
		*(DWORD *)buff = 1;
		return RES_OK;
	}
	return RES_PARERR;
}
