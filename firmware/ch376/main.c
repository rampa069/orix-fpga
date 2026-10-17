/*
 * main.c - firmware of the emulated CH376 (Twilighte board)
 * Copyright 2026 rampa
 *
 * This is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License,
 * or any later version.
 *
 * rtl/ch376_host.vhd answers the 6502 directly for everything that needs no
 * file system and raises a request for the rest. This firmware serves those
 * requests with FatFs on the image mounted on user_io slot 0, following the
 * protocol layer of the Oricutron CH376 emulation (plugins/ch376/ch376.c):
 * same commands, results, status codes and quirks. The Oricutron system_*
 * host functions are replaced by FatFs calls.
 *
 * Deviations from Oricutron, all towards the real CH376:
 *  - a file that cannot be opened for writing is opened read only;
 *  - BYTE_LOCATE clamps the position to the file size (0xFFFFFFFF moves to
 *    the end), so seeking never extends the file;
 *  - the write time of the file is returned in the creation fields too
 *    (FatFs does not keep the creation time).
 */

#include <string.h>
#include "fatfs/ff.h"
#include "fatfs/diskio.h"
#include "hw.h"

/* Commands */
#define CMD_DISK_MOUNT      0x31
#define CMD_FILE_OPEN       0x32
#define CMD_FILE_ENUM_GO    0x33
#define CMD_FILE_CREATE     0x34
#define CMD_FILE_ERASE      0x35
#define CMD_FILE_CLOSE      0x36
#define CMD_BYTE_LOCATE     0x39
#define CMD_BYTE_READ       0x3A
#define CMD_BYTE_RD_GO      0x3B
#define CMD_BYTE_WRITE      0x3C
#define CMD_BYTE_WR_GO      0x3D
#define CMD_DISK_CAPACITY   0x3E
#define CMD_DISK_QUERY      0x3F
#define CMD_DIR_CREATE      0x40

#define USB_MODE_SD_HOST    0x03
#define USB_MODE_USB_HOST   0x06

/* Results */
#define ERR_OPEN_DIR        0x41
#define ERR_MISS_FILE       0x42
#define ERR_FOUND_NAME      0x43
#define RET_ABORT           0x5F
#define INT_SUCCESS         0x14
#define INT_DISK_READ       0x1D
#define INT_DISK_WRITE      0x1E
#define MOUNT_FAILED        0x1F    /* as Oricutron, which is not sure of it */

#define IF_FOUND            127
#define IF_NONE             0

#define IO_BUFFER_SIZE      255

/* FAT directory entry attributes, as returned by FILE_ENUM_GO */
#define DIR_ATTR_READ_ONLY  0x01
#define DIR_ATTR_DIRECTORY  0x10

static FATFS fs;
static FIL   file;
static DIR   dir;
static FILINFO fno;

static BYTE  mounted;               /* root directory available */
static BYTE  file_open;
static BYTE  dir_browsing;
static BYTE  current_is_directory;  /* last FILE_OPEN entered a directory */
static char  current_dir_name[13];  /* name of that directory, for FILE_ERASE */
static WORD  bytes_to_read_write;

static char  name[15];              /* file name sent with SET_FILE_NAME */
static char  fixed_name[13];
static char  dir_pattern[12];
static char  normalized[12];

/*--------------------------------------------------------------------------*/
/* Host interface helpers                                                    */
/*--------------------------------------------------------------------------*/

static void set_result(BYTE if_status, BYTE status)
{
	H_IFSTAT = if_status;
	H_STATUS = status;
}

static void put32(volatile unsigned char *dst, DWORD v)
{
	dst[0] = (BYTE)(v);
	dst[1] = (BYTE)(v >> 8);
	dst[2] = (BYTE)(v >> 16);
	dst[3] = (BYTE)(v >> 24);
}

/* READ_VAR32 is answered by the hardware from these registers */
static void update_file_registers(void)
{
	if (file_open) {
		put32(H_SIZE, f_size(&file));
		put32(H_OFFSET, f_tell(&file));
	} else {
		put32(H_SIZE, 0xFFFFFFFFUL);
		put32(H_OFFSET, 0xFFFFFFFFUL);
	}
}

/* Name sent by SET_FILE_NAME: H_POS bytes, ends at the first NUL */
static void fetch_name(void)
{
	BYTE i, n;

	n = H_POS;
	if (n > sizeof(name) - 1)
		n = sizeof(name) - 1;
	for (i = 0; i < n; ++i) {
		name[i] = H_BUF[i];
		if (name[i] == '\0')
			return;
	}
	name[i] = '\0';
}

/*--------------------------------------------------------------------------*/
/* Names, as in Oricutron                                                    */
/*--------------------------------------------------------------------------*/

static int normalize_char(char c)
{
	if ((unsigned char)c > 127)
		return -1;
	if (c >= 'a' && c <= 'z')
		return c - ('a' - 'A');
	return c;
}

/* 8.3 name to the 11 character directory form, NULL if not possible */
static const char *normalize_file_name(const char *file_name, char *out)
{
	BYTE i = 0, j = 0;
	int c;

	if (file_name[0] == '.') {
		if (file_name[1] == '\0' || (file_name[1] == '.' && file_name[2] == '\0'))
			return NULL;
	}

	while (file_name[i] != '\0' && file_name[i] != '.' && j < 8) {
		c = normalize_char(file_name[i++]);
		if (c == -1)
			return NULL;
		out[j++] = (char)c;
	}

	if (file_name[i] == '\0' || file_name[i] == '.') {
		if (file_name[i] == '.')
			++i;
		for (; j < 8; ++j)
			out[j] = ' ';
	} else {
		return NULL;
	}

	while (file_name[i] != '\0' && file_name[i] != '.' && j < 11) {
		c = normalize_char(file_name[i++]);
		if (c == -1)
			return NULL;
		out[j++] = (char)c;
	}

	if (file_name[i] != '\0')
		return NULL;

	for (; j < 11; ++j)
		out[j] = ' ';
	out[j] = '\0';
	return out;
}

/* Remove the padding of an 8.3 name and a trailing '.' */
static const char *trim_file_name(const char *file_name, char *out)
{
	BYTE i = 0, j = 0;

	while (file_name[i] != ' ' && file_name[i] != '\0' && j < 12)
		out[j++] = file_name[i++];
	while (file_name[i] == ' ')
		++i;
	while (file_name[i] != ' ' && file_name[i] != '\0' && j < 12)
		out[j++] = file_name[i++];
	if (j > 0 && out[j - 1] == '.')
		--j;
	out[j] = '\0';
	return out;
}

/* '*' matches any character up to the end of the name, extension included */
static void normalize_pattern(const char *pattern, char *out)
{
	BYTE i;

	if (pattern[0] == '*' && pattern[1] == '\0')
		normalize_file_name("*.*", out);
	else if (!normalize_file_name(pattern, out)) {
		out[0] = '\0';
		return;
	}

	for (i = 0; i < 11; ++i) {
		if (out[i] == '*') {
			while (i < 11)
				out[i++] = '*';
			break;
		}
	}
}

static BYTE pattern_match(const char *pattern, const char *file_name)
{
	BYTE i = 0;

	for (;;) {
		if (pattern[i] != '*') {
			if (pattern[i] != file_name[i])
				return 0;
			if (pattern[i] == '\0')
				return 1;
		} else if (file_name[i] == '\0') {
			return 1;
		}
		++i;
	}
}

/*--------------------------------------------------------------------------*/
/* Sessions                                                                  */
/*--------------------------------------------------------------------------*/

static void close_file(void)
{
	if (file_open) {
		f_close(&file);
		file_open = 0;
	}
}

static void close_dir(void)
{
	if (dir_browsing) {
		f_closedir(&dir);
		dir_browsing = 0;
	}
}

/* SET_USB_MODE, a new image or start up */
static void cancel_all_io(void)
{
	bytes_to_read_write = 0;
	close_dir();
	close_file();
	if (mounted) {
		f_unmount("");
		mounted = 0;
	}
	current_is_directory = 0;
	update_file_registers();
}

/* Leading '/' goes back to the root directory; returns the index after it */
static BYTE handle_root(void)
{
	if (name[0] == '/') {
		f_chdir("/");
		return 1;
	}
	return 0;
}

/*--------------------------------------------------------------------------*/
/* Commands                                                                  */
/*--------------------------------------------------------------------------*/

static void disk_mount(void)
{
	static const char vendor[8]   = { 'J','E','D','E','+','O','F','T' };
	static const char product[16] = { 'C','H','3','7','6',' ','E','M','U','L','A','T','O','R',' ',' ' };
	static const char revision[4] = { 'F','A','M','E' };
	BYTE i;
	BYTE mode = H_USB_MODE;

	cancel_all_io();

	if ((mode == USB_MODE_SD_HOST || mode == USB_MODE_USB_HOST) &&
	    f_mount(&fs, "", 1) == FR_OK) {
		mounted = 1;
		f_chdir("/");
		for (i = 0; i < 8; ++i)
			H_BUF[i] = 0;
		for (i = 0; i < 8; ++i)
			H_BUF[8 + i] = vendor[i];
		for (i = 0; i < 16; ++i)
			H_BUF[16 + i] = product[i];
		for (i = 0; i < 4; ++i)
			H_BUF[32 + i] = revision[i];
		H_COUNT = 36;
		set_result(IF_FOUND, INT_SUCCESS);
	} else {
		H_STATUS = MOUNT_FAILED;
	}
}

/* Fill the 32 byte FAT directory entry of fno, if it matches the pattern */
static BYTE dir_entry_from_fno(void)
{
	BYTE i;

	if (!normalize_file_name(fno.fname, normalized) || !pattern_match(dir_pattern, normalized))
		return 0;

	for (i = 0; i < 11; ++i)
		H_BUF[i] = normalized[i];
	H_BUF[11] = ((fno.fattrib & AM_DIR) ? DIR_ATTR_DIRECTORY : 0) |
	            ((fno.fattrib & AM_RDO) ? DIR_ATTR_READ_ONLY : 0);
	H_BUF[12] = 0;                              /* DIR_NTRes */
	H_BUF[13] = 0;                              /* DIR_CrtTimeTenth */
	H_BUF[14] = (BYTE)fno.ftime;                /* DIR_CrtTime */
	H_BUF[15] = (BYTE)(fno.ftime >> 8);
	H_BUF[16] = (BYTE)fno.fdate;                /* DIR_CrtDate */
	H_BUF[17] = (BYTE)(fno.fdate >> 8);
	H_BUF[18] = (BYTE)fno.fdate;                /* DIR_LstAccDate */
	H_BUF[19] = (BYTE)(fno.fdate >> 8);
	H_BUF[20] = 0;                              /* DIR_FstClusHI */
	H_BUF[21] = 0;
	H_BUF[22] = (BYTE)fno.ftime;                /* DIR_WrtTime */
	H_BUF[23] = (BYTE)(fno.ftime >> 8);
	H_BUF[24] = (BYTE)fno.fdate;                /* DIR_WrtDate */
	H_BUF[25] = (BYTE)(fno.fdate >> 8);
	H_BUF[26] = 0;                              /* DIR_FstClusLO */
	H_BUF[27] = 0;
	put32(&H_BUF[28], fno.fsize);               /* DIR_FileSize */
	return 1;
}

static void file_enum_go(void)
{
	if (dir_browsing) {
		for (;;) {
			if (f_readdir(&dir, &fno) != FR_OK || fno.fname[0] == '\0')
				break;
			if (dir_entry_from_fno()) {
				H_COUNT = 32;
				set_result(IF_FOUND, INT_DISK_READ);
				return;
			}
		}
	}
	close_dir();
	set_result(IF_NONE, ERR_OPEN_DIR);
}

static void file_open_cmd(void)
{
	BYTE i;

	if (!mounted) {
		set_result(IF_NONE, RET_ABORT);
		return;
	}

	fetch_name();
	i = handle_root();

	if (name[i] == '\0') {
		set_result(IF_FOUND, ERR_OPEN_DIR);
		current_is_directory = 1;
		return;
	}

	if (strchr(&name[i], '*') || strchr(&name[i], '?')) {
		close_dir();
		if (f_opendir(&dir, "") == FR_OK)
			dir_browsing = 1;
		normalize_pattern(&name[i], dir_pattern);
		file_enum_go();
		return;
	}

	trim_file_name(&name[i], fixed_name);

	/* a directory is entered */
	if (f_stat(fixed_name, &fno) == FR_OK && (fno.fattrib & AM_DIR)) {
		if (f_chdir(fixed_name) == FR_OK) {
			strcpy(current_dir_name, fixed_name);
			current_is_directory = 1;
			set_result(IF_FOUND, ERR_OPEN_DIR);
			return;
		}
	}

	/* an existing file is opened */
	close_file();
	if (f_open(&file, fixed_name, FA_READ | FA_WRITE | FA_OPEN_EXISTING) == FR_OK ||
	    f_open(&file, fixed_name, FA_READ | FA_OPEN_EXISTING) == FR_OK) {
		file_open = 1;
		current_is_directory = 0;
		set_result(IF_FOUND, INT_SUCCESS);
	} else {
		set_result(IF_NONE, ERR_MISS_FILE);
	}
	update_file_registers();
}

static void file_create_cmd(void)
{
	BYTE i;

	if (!mounted) {
		set_result(IF_NONE, RET_ABORT);
		return;
	}

	fetch_name();
	i = handle_root();

	if (name[i] == '\0') {
		set_result(IF_FOUND, INT_SUCCESS);
		return;
	}

	trim_file_name(&name[i], fixed_name);
	close_file();
	if (f_open(&file, fixed_name, FA_READ | FA_WRITE | FA_CREATE_ALWAYS) == FR_OK) {
		file_open = 1;
		set_result(IF_FOUND, INT_SUCCESS);
	} else {
		set_result(IF_NONE, ERR_MISS_FILE);
	}
	update_file_registers();
}

static void dir_create_cmd(void)
{
	BYTE i;
	FRESULT r;

	if (!mounted) {
		set_result(IF_NONE, RET_ABORT);
		return;
	}

	fetch_name();
	i = handle_root();
	trim_file_name(&name[i], fixed_name);

	r = f_stat(fixed_name, &fno);
	if (r == FR_OK && !(fno.fattrib & AM_DIR)) {
		/* a file with that name */
		set_result(IF_NONE, ERR_FOUND_NAME);
		return;
	}
	if (r != FR_OK)
		r = f_mkdir(fixed_name);
	if (r == FR_OK)
		r = f_chdir(fixed_name);
	if (r == FR_OK) {
		strcpy(current_dir_name, fixed_name);
		set_result(IF_FOUND, INT_SUCCESS);
	} else {
		set_result(IF_NONE, ERR_MISS_FILE);
	}
}

static void file_erase_cmd(void)
{
	BYTE i;
	BYTE erased = 0;

	if (!mounted) {
		set_result(IF_NONE, RET_ABORT);
		return;
	}

	fetch_name();
	i = handle_root();

	if (name[i] != '\0') {
		trim_file_name(&name[i], fixed_name);
		close_file();
		update_file_registers();
		if (current_is_directory) {
			/* Oricutron removes the directory entered by FILE_OPEN */
			if (f_chdir("..") == FR_OK && f_unlink(current_dir_name) == FR_OK) {
				erased = 1;
				current_is_directory = 0;
			}
		} else {
			erased = (f_unlink(fixed_name) == FR_OK);
		}
	}

	if (erased)
		set_result(IF_FOUND, INT_SUCCESS);
	else
		set_result(IF_NONE, ERR_MISS_FILE);
}

/*
 * Free cluster count. f_getfree() scans the FAT with 32 bit arithmetic on
 * every entry, which with cc65 takes about 15 ms per FAT16 sector, so the
 * first DISK_QUERY after mounting a FAT16 volume took several seconds, past
 * the 1 s the Orix kernel waits. This scan keeps 32 bit work per sector and
 * leaves the result in fs.free_clst, where f_getfree() takes it from.
 * FAT32 volumes normally have a valid FSINFO and need no scan at all.
 */
unsigned int __fastcall__ fat_count_zero16(const unsigned char *p, unsigned int n);   /* fatscan.s */
unsigned int __fastcall__ fat_count_zero32(const unsigned char *p, unsigned int n);

unsigned char sd_read_sector(LBA_t lba);                                            /* diskio.c */

static const BYTE *fat_sector;   /* the sector being scanned: FatFs window or SD buffer */
static LBA_t fat_lba;
static WORD  fat_pos;

static BYTE load_fat_sector(LBA_t lba)
{
	if (fs.winsect == lba) {
		/* the FatFs window may hold changes not yet written */
		fat_sector = fs.win;
		return 1;
	}
	fat_sector = (const BYTE *)SD_BUF;
	return sd_read_sector(lba);
}

static int next_fat_byte(void)
{
	if (fat_pos == 512) {
		if (!load_fat_sector(++fat_lba))
			return -1;
		fat_pos = 0;
	}
	return fat_sector[fat_pos++];
}

static BYTE count_free_clusters(DWORD *result)
{
	DWORD entries = fs.n_fatent;     /* clusters + the 2 reserved entries */
	DWORD nfree = 0;
	LBA_t lba = fs.fatbase;
	WORD per_sector, in_sector, i, n16;
	int b0, b1, b2;

	if (fs.fs_type == FS_FAT12) {
		fat_lba = lba;
		fat_pos = 0;
		if (!load_fat_sector(lba))
			return 0;
		n16 = 0;
		for (i = 0; i < (WORD)entries; i += 2) {
			b0 = next_fat_byte();
			b1 = next_fat_byte();
			b2 = next_fat_byte();
			if (b0 < 0 || b1 < 0 || b2 < 0)
				return 0;
			if (b0 == 0 && (b1 & 0x0F) == 0)
				++n16;
			if (i + 1 < (WORD)entries && (b1 & 0xF0) == 0 && b2 == 0)
				++n16;
		}
		*result = n16;
		return 1;
	}

	per_sector = (fs.fs_type == FS_FAT16) ? 256 : 128;
	while (entries) {
		if (!load_fat_sector(lba++))
			return 0;
		in_sector = entries > per_sector ? per_sector : (WORD)entries;
		if (fs.fs_type == FS_FAT16)
			nfree += fat_count_zero16(fat_sector, in_sector);
		else
			nfree += fat_count_zero32(fat_sector, in_sector);
		entries -= in_sector;
	}
	*result = nfree;
	return 1;
}

/* DISK_QUERY (9 bytes) and DISK_CAPACITY (the first 4) */
static void disk_query(BYTE bytes)
{
	DWORD free_clusters, total, free_sectors;
	FATFS *pfs;

	if (mounted && fs.free_clst > fs.n_fatent - 2) {
		if (count_free_clusters(&free_clusters)) {
			fs.free_clst = free_clusters;
			fs.fsi_flag |= 1;
		}
	}

	if (!mounted || f_getfree("", &free_clusters, &pfs) != FR_OK) {
		set_result(IF_NONE, RET_ABORT);
		return;
	}
	total = (pfs->n_fatent - 2) * pfs->csize;
	free_sectors = free_clusters * pfs->csize;
	put32(&H_BUF[0], total);
	put32(&H_BUF[4], free_sectors);
	H_BUF[8] = 0x0C;                            /* as Oricutron */
	H_COUNT = bytes;
	set_result(IF_FOUND, INT_SUCCESS);
}

static void byte_locate(void)
{
	DWORD position;

	position = (DWORD)H_BUF[0] | ((DWORD)H_BUF[1] << 8) |
	           ((DWORD)H_BUF[2] << 16) | ((DWORD)H_BUF[3] << 24);

	if (!file_open) {
		set_result(IF_NONE, RET_ABORT);
		return;
	}
	if (position > f_size(&file))
		position = f_size(&file);
	if (f_lseek(&file, position) == FR_OK) {
		put32(&H_BUF[0], f_tell(&file));
		H_COUNT = 4;
		set_result(IF_FOUND, INT_SUCCESS);
	} else {
		set_result(IF_NONE, RET_ABORT);
	}
	update_file_registers();
}

static BYTE io_buffer[IO_BUFFER_SIZE];

static void file_read_chunk(void)
{
	UINT now, actually;
	BYTE i;

	now = bytes_to_read_write > IO_BUFFER_SIZE ? IO_BUFFER_SIZE : bytes_to_read_write;

	if (file_open && f_read(&file, io_buffer, now, &actually) == FR_OK) {
		for (i = 0; i < (BYTE)actually; ++i)
			H_BUF[i] = io_buffer[i];
		bytes_to_read_write -= actually;
		H_COUNT = (BYTE)actually;
		/* like Oricutron and the real chip: an empty buffer comes with
		   INT_SUCCESS, the last data buffer still with INT_DISK_READ */
		if (now == 0 || actually == 0)
			set_result(IF_FOUND, INT_SUCCESS);
		else
			set_result(IF_FOUND, INT_DISK_READ);
	} else {
		H_COUNT = 0;
		set_result(IF_NONE, RET_ABORT);
	}
	update_file_registers();
}

static void byte_write_start(void)
{
	bytes_to_read_write = (WORD)H_BUF[0] | ((WORD)H_BUF[1] << 8);
	H_COUNT = bytes_to_read_write > IO_BUFFER_SIZE ? IO_BUFFER_SIZE : (BYTE)bytes_to_read_write;
	set_result(IF_FOUND, INT_SUCCESS);
}

static void file_write_chunk(void)
{
	UINT now, actually;
	BYTE i;

	now = H_COUNT;
	for (i = 0; i < (BYTE)now; ++i)
		io_buffer[i] = H_BUF[i];

	if (file_open && f_write(&file, io_buffer, now, &actually) == FR_OK && actually == now) {
		bytes_to_read_write -= actually;
		if (bytes_to_read_write == 0) {
			H_COUNT = 0;
			set_result(IF_FOUND, INT_SUCCESS);
		} else {
			H_COUNT = bytes_to_read_write > IO_BUFFER_SIZE ? IO_BUFFER_SIZE : (BYTE)bytes_to_read_write;
			set_result(IF_FOUND, INT_DISK_WRITE);
		}
	} else {
		H_COUNT = 0;
		set_result(IF_NONE, RET_ABORT);
	}
	update_file_registers();
}

static void file_close_cmd(void)
{
	if (file_open) {
		close_file();
		set_result(IF_FOUND, INT_SUCCESS);
	} else {
		set_result(IF_NONE, RET_ABORT);
	}
	update_file_registers();
}

static void handle_request(BYTE command)
{
	switch (command) {
	case CMD_DISK_MOUNT:    disk_mount();          break;
	case CMD_FILE_OPEN:     file_open_cmd();       break;
	case CMD_FILE_ENUM_GO:  file_enum_go();        break;
	case CMD_FILE_CREATE:   file_create_cmd();     break;
	case CMD_DIR_CREATE:    dir_create_cmd();      break;
	case CMD_FILE_ERASE:    file_erase_cmd();      break;
	case CMD_DISK_CAPACITY: disk_query(4);         break;
	case CMD_DISK_QUERY:    disk_query(9);         break;
	case CMD_BYTE_LOCATE:   byte_locate();         break;
	case CMD_BYTE_READ:
		bytes_to_read_write = (WORD)H_BUF[0] | ((WORD)H_BUF[1] << 8);
		file_read_chunk();
		break;
	case CMD_BYTE_RD_GO:    file_read_chunk();     break;
	case CMD_BYTE_WRITE:    byte_write_start();    break;
	case CMD_BYTE_WR_GO:    file_write_chunk();    break;
	case CMD_FILE_CLOSE:    file_close_cmd();      break;
	default:                set_result(IF_NONE, RET_ABORT); break;
	}
}

void main(void)
{
	BYTE flags;

	cancel_all_io();

	for (;;) {
		if (SD_CTRL & SD_STAT_CHANGED) {
			/* a new image: everything open belongs to the old one */
			cancel_all_io();
			SD_CTRL = SD_CTRL_CHANGE;
		}

		flags = H_FLAGS;
		if (flags & H_FLAG_CANCEL) {
			cancel_all_io();
			H_CTRL = H_CTRL_CANCEL;
		}
		if (flags & H_FLAG_REQUEST) {
			handle_request(H_CMD);
			H_CTRL = H_CTRL_DONE;
		}
	}
}
