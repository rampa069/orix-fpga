// Verilator testbench for rtl/wd1793.sv with Oricutron MFM_DISK images.
//
// The harness plays the part of user_io (512 byte SD blocks served from the
// image held in memory, writes go back to it) and of a 1 MHz 6502 (register
// accesses of 24 clk_sys). Every sector read through the FDC is compared with
// the image parsed independently here.
//
// Usage: tb_wd1793 <image.dsk> [out.dsk]

#include "Vwd1793.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cstdint>
#include <vector>
#include <string>
#include <algorithm>

static Vwd1793 *top;
static uint64_t cycles;
static int ce_div;
static std::vector<uint8_t> img;
static int failures;

// ---- user_io SD model ----------------------------------------------------
enum { SD_IDLE, SD_DELAY, SD_READ, SD_WRITE, SD_END };
static int sd_state = SD_IDLE, sd_cnt, sd_idx;
static uint32_t sd_lba;
static long sd_blocks_read, sd_blocks_written;

static void sd_model()
{
	switch(sd_state) {
	case SD_IDLE:
		if(top->sd_rd || top->sd_wr) {
			sd_lba = top->sd_lba;
			sd_state = SD_DELAY; sd_cnt = 40;
			sd_idx = top->sd_rd ? 0 : 1;
		}
		break;
	case SD_DELAY:
		if(--sd_cnt == 0) {
			top->sd_ack = 1;
			top->sd_buff_addr = 0;
			sd_cnt = 0;
			sd_state = sd_idx ? SD_WRITE : SD_READ;
		}
		break;
	case SD_READ:  // one byte every 4 clocks
		top->sd_buff_wr = 0;
		if((sd_cnt & 3) == 0) {
			int a = sd_cnt >> 2;
			if(a == 512) { sd_state = SD_END; sd_blocks_read++; break; }
			size_t off = (size_t)sd_lba * 512 + a;
			top->sd_buff_addr = a;
			top->sd_buff_dout = off < img.size() ? img[off] : 0;
			top->sd_buff_wr = 1;
		}
		sd_cnt++;
		break;
	case SD_WRITE: // address, then sample sd_buff_din 3 clocks later
		if((sd_cnt & 3) == 0) {
			int a = sd_cnt >> 2;
			if(a == 512) { sd_state = SD_END; sd_blocks_written++; break; }
			top->sd_buff_addr = a;
		}
		if((sd_cnt & 3) == 3) {
			size_t off = (size_t)sd_lba * 512 + (sd_cnt >> 2);
			if(off < img.size()) img[off] = top->sd_buff_din;
		}
		sd_cnt++;
		break;
	case SD_END:
		top->sd_ack = 0;
		top->sd_buff_wr = 0;
		sd_state = SD_IDLE;
		break;
	}
}

static void tick()
{
	top->ce = (cycles % ce_div) == 0;
	top->clk_sys = 0; top->eval();
	top->clk_sys = 1; top->eval();
	sd_model();
	cycles++;
}
static void ticks(int n) { while(n--) tick(); }

// ---- 6502 bus ------------------------------------------------------------
static void wr(int a, int d)
{
	top->addr = a; top->din = d; top->io_en = 1; top->wr = 1;
	ticks(24);
	top->io_en = 0; top->wr = 0;
	ticks(24);
}
static int rd(int a)
{
	top->addr = a; top->io_en = 1; top->rd = 1;
	ticks(20);
	int v = top->dout;
	ticks(4);
	top->io_en = 0; top->rd = 0;
	ticks(24);
	return v;
}

// wait for INTRQ, collecting the data bytes on DRQ (reads) or feeding them (writes)
static int run_cmd(int cmd, std::vector<uint8_t> *in, const std::vector<uint8_t> *out, uint64_t limit = 400000000ull)
{
	wr(0, cmd);
	size_t n = 0;
	uint64_t start = cycles;
	while(!top->intrq) {
		if(top->drq) {
			if(in) in->push_back(rd(3));
			else if(out) wr(3, n < out->size() ? (*out)[n++] : 0);
			else rd(3);
		} else tick();
		if(cycles - start > limit) { printf("TIMEOUT cmd %02X\n", cmd); failures++; return -1; }
	}
	return rd(0);  // status, clears INTRQ
}

// ---- independent image parser ------------------------------------------
struct sec { int c, h, r, n; size_t data; bool del; };
static uint32_t le32(size_t o) { return img[o] | img[o+1] << 8 | img[o+2] << 16 | (uint32_t)img[o+3] << 24; }
static int sides, tracks;

static std::vector<sec> parse_track(int t, int s)
{
	std::vector<sec> v;
	size_t base = 256 + (size_t)(s * tracks + t) * 6400;
	for(size_t p = 0; p + 3 < 6400 && base + p + 3 < img.size(); p++) {
		const uint8_t *b = &img[base + p];
		if(b[0] == 0xA1 && b[1] == 0xA1 && b[2] == 0xA1 && b[3] == 0xFE) {
			sec x = { b[4], b[5], b[6], b[7] & 3, 0, false };
			for(size_t q = p + 10; q < p + 10 + 43 + 3 && base + q + 3 < img.size(); q++) {
				const uint8_t *d = &img[base + q];
				if(d[0] == 0xA1 && d[1] == 0xA1 && d[2] == 0xA1 && (d[3] == 0xFB || d[3] == 0xF8)) {
					x.data = base + q + 4; x.del = d[3] == 0xF8; break;
				}
			}
			v.push_back(x);
			p += x.data ? (x.data - base - p) + (128 << x.n) + 1 : 9;
		}
	}
	return v;
}

static uint16_t crc16(const uint8_t *p, size_t n, uint16_t c = 0xFFFF)
{
	while(n--) { c ^= *p++ << 8; for(int i = 0; i < 8; i++) c = c & 0x8000 ? (c << 1) ^ 0x1021 : c << 1; }
	return c;
}

static void check(bool ok, const char *what, int t, int s, int r)
{
	if(!ok) { failures++; printf("FAIL %s t%d s%d r%d\n", what, t, s, r); }
}

static void seek(int t)
{
	wr(3, t);
	int st = run_cmd(0x18, nullptr, nullptr);  // seek, head load
	check((st & 0x10) == 0, "seek status", t, 0, 0);
}

static void set_side(int s) { top->side = s; }

int main(int argc, char **argv)
{
	Verilated::commandArgs(argc, argv);
	if(argc < 2) { fprintf(stderr, "usage: %s image.dsk [out.dsk]\n", argv[0]); return 2; }
	FILE *f = fopen(argv[1], "rb");
	if(!f) { perror(argv[1]); return 2; }
	fseek(f, 0, SEEK_END); img.resize(ftell(f)); fseek(f, 0, SEEK_SET);
	if(fread(img.data(), 1, img.size(), f) != img.size()) { perror("read"); return 2; }
	fclose(f);
	sides = le32(8); tracks = le32(12);
	printf("%s: %zu bytes, %d sides, %d tracks, geometry %u\n", argv[1], img.size(), sides, tracks, le32(16));

	top = new Vwd1793;
	ce_div = 6;   // 4 MHz from 24 MHz, as in the core
	top->ready = 1; top->wp = 0; top->side = 0;
	top->reset = 1; ticks(20); top->reset = 0; ticks(20);

	// mount
	top->img_size = img.size();
	top->img_mounted = 1; tick(); top->img_mounted = 0; ticks(10);

	// Replay mode: a command sequence "cmd trackreg sector head side" per
	// line (hex, hex, hex, dec, dec), as logged by sim/system/fdc_model.vhd
	// while the Microdisc ROM boots. Seeks take their target from the head
	// of the next line. Every sector read is compared with the image.
	if(argc > 3 && !strcmp(argv[2], "--replay")) {
		FILE *sf = fopen(argv[3], "r");
		if(!sf) { perror(argv[3]); return 2; }
		struct ent { int cmd, trk, sec, head, side; };
		std::vector<ent> seq;
		ent e;
		while(fscanf(sf, "%x %x %x %d %d", &e.cmd, &e.trk, &e.sec, &e.head, &e.side) == 5) seq.push_back(e);
		fclose(sf);
		uint64_t worst = 0;
		for(size_t i = 0; i < seq.size(); i++) {
			const ent &c = seq[i];
			set_side(c.side);
			uint64_t t0 = cycles;
			if((c.cmd & 0xF0) == 0xD0) { wr(0, c.cmd); ticks(100); continue; }
			wr(1, c.trk);
			wr(2, c.sec);
			if((c.cmd & 0xF0) == 0x10) wr(3, i + 1 < seq.size() ? seq[i + 1].head : c.head);
			std::vector<uint8_t> data;
			int st = run_cmd(c.cmd, (c.cmd & 0xE0) == 0x80 ? &data : nullptr, nullptr);
			uint64_t dt = cycles - t0;
			if(dt > worst) worst = dt;
			bool ok = true;
			if((c.cmd & 0xE0) == 0x80) {
				ok = false;
				for(auto &x : parse_track(c.head, c.side))
					if(x.r == c.sec && x.data && data.size() == (size_t)(128 << x.n) &&
					   !memcmp(data.data(), &img[x.data], data.size())) ok = true;
				ok = ok && (st & 0x1C) == 0;
			}
			if(!ok || st < 0) failures++;
			printf("%3zu cmd %02X trk %02X sec %02X head %2d side %d -> status %02X, %zu bytes, %.2f ms%s\n",
			       i, c.cmd, c.trk, c.sec, c.head, c.side, st & 0xFF, data.size(), dt / 24000.0, ok ? "" : "  FAIL");
		}
		printf("worst command %.2f ms\n%s\n", worst / 24000.0, failures ? "FAILED" : "PASSED");
		delete top;
		return failures != 0;
	}

	int st = run_cmd(0x08, nullptr, nullptr);       // restore
	check((st & 0x04) != 0, "restore track 0 flag", 0, 0, 0);

	// every sector of a set of tracks, single sector reads, then Read Address
	long sectors_ok = 0, sectors_rnf = 0;
	std::vector<int> tlist = { 0, 1, 2, tracks / 2, tracks - 1 };
	for(int t : tlist) {
		seek(t);
		for(int s = 0; s < 2; s++) {
			set_side(s);
			std::vector<sec> ref = s < sides ? parse_track(t, s) : std::vector<sec>();
			for(auto &x : ref) {
				wr(2, x.r);
				std::vector<uint8_t> data;
				st = run_cmd(0x80, &data, nullptr);
				if(!x.data) { check(st & 0x10, "RNF expected", t, s, x.r); continue; }
				size_t len = 128 << x.n;
				bool ok = (st & 0x1C) == 0 && data.size() == len &&
				          (x.data + len > img.size() || !memcmp(data.data(), &img[x.data], len));
				check(ok, "sector data", t, s, x.r);
				check(((st >> 5) & 1) == x.del, "record type", t, s, x.r);
				if(ok) sectors_ok++;
			}
			// a sector that does not exist
			wr(2, 0xEE);
			st = run_cmd(0x80, nullptr, nullptr);
			check(st & 0x10, "RNF on missing sector", t, s, 0xEE);
			if(st & 0x10) sectors_rnf++;
			// Read Address returns ID fields of this track
			if(!ref.empty()) {
				std::vector<uint8_t> id;
				st = run_cmd(0xC0, &id, nullptr);
				bool found = false;
				for(auto &x : ref) if(id.size() == 6 && id[0] == x.c && id[1] == x.h && id[2] == x.r) found = true;
				check(found && rd(2) == id[0], "read address", t, s, id.size() ? id[2] : -1);
			}
		}
	}
	printf("single reads: %ld sectors ok, %ld RNF checks\n", sectors_ok, sectors_rnf);

	// multi-sector read of track 1 side 0, ends with RNF after the last sector
	{
		seek(1); set_side(0);
		auto ref = parse_track(1, 0);
		wr(2, 1);
		std::vector<uint8_t> data;
		st = run_cmd(0x90, &data, nullptr);
		size_t expect = 0; int r = 1;
		for(bool more = true; more; ) {
			more = false;
			for(auto &x : ref) if(x.r == r && x.data) { expect += 128 << x.n; r++; more = true; break; }
		}
		check(data.size() == expect, "multi-sector length", 1, 0, r);
		check(st & 0x10, "multi-sector ends with RNF", 1, 0, r);
		printf("multi-sector read: %zu bytes, %d sectors\n", data.size(), r - 1);
	}

	// write a sector, read it back, check the image bytes and the data CRC
	if(sides == 2 && tracks > 5) {
		seek(5); set_side(1);
		auto ref = parse_track(5, 1);
		const sec *x = nullptr;
		for(auto &y : ref) if(y.r == 3) x = &y;
		if(x && x->data) {
			size_t len = 128 << x->n;
			std::vector<uint8_t> pat(len);
			for(size_t i = 0; i < len; i++) pat[i] = (uint8_t)(i * 7 + 0x35);
			std::vector<uint8_t> before(img.begin(), img.end());
			wr(2, 3);
			st = run_cmd(0xA0, nullptr, &pat);
			check((st & 0x7C) == 0, "write status", 5, 1, 3);
			bool img_ok = !memcmp(&img[x->data], pat.data(), len);
			check(img_ok, "write image data", 5, 1, 3);
			uint16_t c = crc16(&img[x->data - 4], len + 4);
			uint16_t stored = img[x->data + len] << 8 | img[x->data + len + 1];
			check(c == stored, "write data CRC", 5, 1, 3);
			// nothing else changed
			size_t diff = 0;
			for(size_t i = 0; i < img.size(); i++)
				if(img[i] != before[i] && (i < x->data || i >= x->data + len + 2)) diff++;
			check(diff == 0, "write touched other bytes", 5, 1, 3);
			std::vector<uint8_t> back;
			wr(2, 3);
			st = run_cmd(0x80, &back, nullptr);
			check(back == pat, "read back", 5, 1, 3);
			printf("write sector: %s, CRC %04X\n", img_ok && c == stored ? "ok" : "bad", c);
		}
	}

	// a track past the end of the image reads as unformatted
	seek(tracks + 1); set_side(0);
	wr(2, 1);
	st = run_cmd(0x80, nullptr, nullptr);
	check(st & 0x10, "RNF past the last track", tracks + 1, 0, 1);

	// Read Track returns the raw image track
	{
		int t = tracks > 2 ? 2 : 0;
		seek(t); set_side(0);
		std::vector<uint8_t> raw;
		st = run_cmd(0xE4, &raw, nullptr);
		size_t base = 256 + (size_t)t * 6400;
		size_t avail = base < img.size() ? std::min<size_t>(6400, img.size() - base) : 0;
		bool ok = raw.size() == avail && !memcmp(raw.data(), &img[base], avail) && (st & 0x04) == 0;
		check(ok, "read track", t, 0, 0);
		printf("read track: %zu bytes%s\n", raw.size(), ok ? "" : " (mismatch)");
	}

	// Write Sector with a0 = 1 writes a deleted data mark
	if(sides == 2 && tracks > 5) {
		seek(5); set_side(1);
		auto ref = parse_track(5, 1);
		const sec *x = nullptr;
		for(auto &y : ref) if(y.r == 4) x = &y;
		if(x && x->data) {
			size_t len = 128 << x->n;
			std::vector<uint8_t> pat(len), before(img.begin(), img.end());
			for(size_t i = 0; i < len; i++) pat[i] = (uint8_t)(0xC3 ^ i);
			wr(2, 4);
			st = run_cmd(0xA1, nullptr, &pat);
			bool mark = img[x->data - 1] == 0xF8;
			uint16_t c = crc16(&img[x->data - 4], len + 4);
			bool crc_ok = c == (img[x->data + len] << 8 | img[x->data + len + 1]);
			size_t diff = 0;
			for(size_t i = 0; i < img.size(); i++)
				if(img[i] != before[i] && (i < x->data - 1 || i >= x->data + len + 2)) diff++;
			std::vector<uint8_t> back;
			wr(2, 4);
			int st2 = run_cmd(0x80, &back, nullptr);
			bool ok = (st & 0x7C) == 0 && mark && crc_ok && diff == 0 && back == pat && (st2 & 0x20);
			check(ok, "deleted data mark", 5, 1, 4);
			printf("deleted mark: %s (mark %02X, CRC %s, record type %d)\n", ok ? "ok" : "bad",
			       img[x->data - 1], crc_ok ? "ok" : "bad", (st2 >> 5) & 1);
		}
	}

	// Write Track: format track 6 side 0 with 17 sectors of 256 bytes, then
	// read them back; the neighbouring bytes of the image must not change
	if(tracks > 7) {
		const int t = 6;
		seek(t); set_side(0);
		std::vector<uint8_t> f, before(img.begin(), img.end());
		auto put = [&](uint8_t b, int n) { while(n--) f.push_back(b); };
		put(0x4E, 40); put(0x00, 12); put(0xF6, 3); put(0xFC, 1); put(0x4E, 40);
		for(int r = 1; r <= 17; r++) {
			put(0x00, 12); put(0xF5, 3); put(0xFE, 1);
			f.push_back(t); f.push_back(0); f.push_back(r); f.push_back(1); put(0xF7, 1);
			put(0x4E, 22); put(0x00, 12); put(0xF5, 3); put(0xFB, 1);
			// F5 to F7 are commands in Write Track data too, as on the WD1793,
			// so the sector holds r * 16 then E5 as formatters write
			f.push_back((uint8_t)(r * 16)); put(0xE5, 255);
			put(0xF7, 1); put(0x4E, 40);
		}
		put(0x4E, 1000);          // the program keeps feeding until INTRQ
		st = run_cmd(0xF4, nullptr, &f);
		auto ref = parse_track(t, 0);
		bool layout = ref.size() == 17;
		int good = 0;
		for(auto &x : ref) {
			bool id_ok = crc16(&img[x.data - 48], 8) == (img[x.data - 40] << 8 | img[x.data - 39]);
			bool d_ok = x.data && crc16(&img[x.data - 4], 260) == (img[x.data + 256] << 8 | img[x.data + 257]);
			if(x.c == t && x.h == 0 && x.n == 1 && id_ok && d_ok && img[x.data] == (uint8_t)(x.r * 16)) good++;
		}
		size_t base = 256 + (size_t)t * 6400, diff = 0;
		for(size_t i = 0; i < img.size(); i++)
			if(img[i] != before[i] && (i < base || i >= base + 6400)) diff++;
		int readback = 0;
		for(int r = 1; r <= 17; r++) {
			std::vector<uint8_t> d;
			wr(2, r);
			int s2 = run_cmd(0x80, &d, nullptr);
			if((s2 & 0x1C) == 0 && d.size() == 256 && d[0] == (uint8_t)(r * 16) && d[255] == 0xE5) readback++;
		}
		bool ok = (st & 0x64) == 0 && layout && good == 17 && diff == 0 && readback == 17;
		check(ok, "write track", t, 0, 0);
		printf("write track: status %02X, %zu sectors found, %d with good CRCs, %d read back, %zu bytes outside changed\n",
		       st & 0xFF, ref.size(), good, readback, diff);
	}

	// CRC checking on: every sector of track 1 side 0, counted
	{
		top->check_crc = 1;
		seek(1); set_side(0);
		int ok = 0, crcerr = 0, other = 0;
		for(auto &x : parse_track(1, 0)) {
			wr(2, x.r);
			std::vector<uint8_t> d;
			int s2 = run_cmd(0x80, &d, nullptr);
			if((s2 & 0x1C) == 0) ok++; else if(s2 & 0x08) crcerr++; else other++;
		}
		top->check_crc = 0;
		printf("check_crc: %d sectors ok, %d with CRC error, %d other errors\n", ok, crcerr, other);
	}

	printf("SD blocks read %ld, written %ld, %.1f ms simulated\n",
	       sd_blocks_read, sd_blocks_written, cycles / 24000.0);
	if(argc > 2) { FILE *o = fopen(argv[2], "wb"); fwrite(img.data(), 1, img.size(), o); fclose(o); }
	printf(failures ? "FAILED: %d\n" : "PASSED\n", failures);
	delete top;
	return failures != 0;
}
