#!/usr/bin/env python3
"""Survey Oric disk images and report what each one exercises in the FDC.

Usage: survey.py [--csv] image.dsk ...

For MFM_DISK images it reports the geometry, the sector layout and the
oddities a WD1793 replica has to cope with: ID fields that do not match the
physical track or side, duplicate or unusual sector numbers, sizes other than
256 bytes, deleted data marks, ID fields without data, CRC errors, more than
32 sectors on a track, sectors running past the end of the track, truncated
files and files above 1 MB.
"""
import struct
import sys
from collections import Counter

TRACK = 6400


def crc16(data, c=0xFFFF):
    for b in data:
        c ^= b << 8
        for _ in range(8):
            c = ((c << 1) ^ 0x1021) & 0xFFFF if c & 0x8000 else (c << 1) & 0xFFFF
    return c


def survey(path):
    d = open(path, 'rb').read()
    r = {'file': path, 'size': len(d), 'format': '?', 'flags': set()}
    if d[:8] == b'EXTENDED':
        r['format'] = 'EDSK'
        return r
    if d[:8] != b'MFM_DISK':
        r['format'] = 'raw' if len(d) % 256 == 0 else 'unknown'
        return r
    r['format'] = 'MFM'
    sides, tracks, geom = struct.unpack_from('<III', d, 8)
    r.update(sides=sides, tracks=tracks, geom=geom)
    if geom != 1:
        r['flags'].add('geometry%d' % geom)
        return r
    expect = 256 + sides * tracks * TRACK
    if len(d) < expect:
        r['flags'].add('truncated')
    if len(d) > expect:
        r['flags'].add('trailing-data')
    if len(d) > 1 << 20:
        r['flags'].add('over-1MB')
    spt = Counter()
    sizes = Counter()
    for s in range(sides):
        for t in range(tracks):
            base = 256 + (s * tracks + t) * TRACK
            trk = d[base:base + TRACK]
            p, n, seen = 0, 0, Counter()
            while True:
                p = trk.find(b'\xa1\xa1\xa1\xfe', p)
                if p < 0 or p + 10 > len(trk):
                    break
                c, h, sec, sz = trk[p + 4:p + 8]
                n += 1
                seen[sec] += 1
                sizes[sz] += 1
                if c != t:
                    r['flags'].add('id-track-differs')
                if h != s:
                    r['flags'].add('id-side-differs')
                if sz > 3:
                    r['flags'].add('size-code>3')
                if sec == 0 or sec > 32:
                    r['flags'].add('odd-sector-number')
                if crc16(trk[p:p + 8]) != (trk[p + 8] << 8 | trk[p + 9]):
                    r['flags'].add('id-crc-error')
                q = None
                for k in range(p + 10, min(p + 10 + 46, len(trk) - 3)):
                    if trk[k:k + 3] == b'\xa1\xa1\xa1' and trk[k + 3] in (0xFB, 0xF8):
                        q = k
                        break
                if q is None:
                    r['flags'].add('id-without-data')
                    p += 10
                    continue
                if trk[q + 3] == 0xF8:
                    r['flags'].add('deleted-mark')
                ln = 128 << (sz & 3)
                end = q + 4 + ln + 2
                if end > len(trk):
                    r['flags'].add('data-past-track-end')
                    p = q + 4
                    continue
                if crc16(trk[q:q + 4 + ln]) != (trk[q + 4 + ln] << 8 | trk[q + 5 + ln]):
                    r['flags'].add('data-crc-error')
                p = q + 4 + ln
            spt[n] += 1
            if n > 32:
                r['flags'].add('over-32-sectors')
            if any(v > 1 for v in seen.values()):
                r['flags'].add('duplicate-sector-id')
    r['spt'] = dict(spt)
    r['sizes'] = dict(sizes)
    if 0 in spt and len(spt) > 1:
        r['flags'].add('unformatted-tracks')
    if len([k for k in spt if k]) > 1:
        r['flags'].add('mixed-spt')
    if set(sizes) - {1}:
        r['flags'].add('non-256-sectors')
    return r


def main():
    args = sys.argv[1:]
    csv = '--csv' in args
    args = [a for a in args if a != '--csv']
    for path in args:
        try:
            r = survey(path)
        except Exception as e:  # report and carry on with the rest
            print('%s\tERROR %s' % (path, e))
            continue
        flags = ','.join(sorted(r['flags']))
        if csv:
            print('\t'.join(str(x) for x in (path, r['format'], r['size'], r.get('sides', ''),
                                              r.get('tracks', ''), r.get('geom', ''),
                                              r.get('spt', ''), r.get('sizes', ''), flags)))
        else:
            print('%s: %s %d bytes sides=%s tracks=%s spt=%s sizes=%s %s' % (
                path, r['format'], r['size'], r.get('sides'), r.get('tracks'),
                r.get('spt'), r.get('sizes'), flags))


if __name__ == '__main__':
    main()
