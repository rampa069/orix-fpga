#!/usr/bin/env python3
"""Convert an EXTENDED CPC DSK (EDSK) image into an Oricutron MFM_DISK image.

Usage: edsk2mfm.py in.dsk out.dsk

Each track is rebuilt as a 6400 byte raw MFM track with the layout found in
the Sedoric 3 master disk: gap 4E x40, 00 x12, C2 C2 C2 FC index mark,
4E x40, then for every sector 00 x12, A1 A1 A1 FE C H R N CRC, 4E x22,
00 x12, A1 A1 A1 FB (F8 when the EDSK flags a deleted mark), data, CRC and
gap 4E, the rest of the track filled with 4E. The gap after each sector
shrinks when the track would not fit. CRCs are real CRC-CCITT values.
"""
import struct
import sys

TRACK = 6400


def crc16(data, c=0xFFFF):
    for b in data:
        c ^= b << 8
        for _ in range(8):
            c = ((c << 1) ^ 0x1021) & 0xFFFF if c & 0x8000 else (c << 1) & 0xFFFF
    return c


def read_edsk(d):
    if d[:8] != b'EXTENDED':
        raise ValueError('not an EXTENDED CPC DSK image')
    tracks, sides = d[0x30], d[0x31]
    sizes = d[0x34:0x34 + tracks * sides]
    out = {}
    pos = 0x100
    for i in range(tracks * sides):
        tsize = sizes[i] << 8
        if tsize == 0:
            continue
        t = d[pos:pos + tsize]
        if t[:10] != b'Track-Info':
            raise ValueError('bad track header at %#x' % pos)
        trk, side, nsec = t[0x10], t[0x11], t[0x15]
        secs = []
        dpos = pos + 0x100
        for s in range(nsec):
            c, h, r, n, st1, st2, lo, hi = t[0x18 + 8 * s:0x20 + 8 * s]
            ln = lo | hi << 8
            data = d[dpos:dpos + ln]
            secs.append((c, h, r, n, bool(st2 & 0x40), data[:128 << (n & 3)]))
            dpos += ln
        out[(trk, side)] = secs
        pos += tsize
    return tracks, sides, out


def build_track(secs):
    def sector(gap):
        b = bytearray()
        for c, h, r, n, deleted, data in secs:
            idf = b'\xa1\xa1\xa1\xfe' + bytes((c, h, r, n))
            b += b'\x00' * 12 + idf + struct.pack('>H', crc16(idf)) + b'\x4e' * 22
            dat = b'\xa1\xa1\xa1' + (b'\xf8' if deleted else b'\xfb') + data
            b += b'\x00' * 12 + dat + struct.pack('>H', crc16(dat)) + b'\x4e' * gap
        return b
    head = b'\x4e' * 40 + b'\x00' * 12 + b'\xc2\xc2\xc2\xfc' + b'\x4e' * 40
    for gap in (40, 24, 12, 4):
        t = head + sector(gap)
        if len(t) <= TRACK:
            return t + b'\x4e' * (TRACK - len(t))
    raise ValueError('sectors do not fit in a 6400 byte track')


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    tracks, sides, secs = read_edsk(open(sys.argv[1], 'rb').read())
    out = bytearray(b'MFM_DISK' + struct.pack('<III', sides, tracks, 1))
    out += b'\x00' * (256 - len(out))
    for s in range(sides):
        for t in range(tracks):
            out += build_track(secs.get((t, s), []))
    open(sys.argv[2], 'wb').write(out)
    print('%s: %d sides, %d tracks, %d bytes' % (sys.argv[2], sides, tracks, len(out)))


if __name__ == '__main__':
    main()
