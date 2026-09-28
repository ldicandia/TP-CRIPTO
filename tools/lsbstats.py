#!/usr/bin/env python3
"""lsbstats: per-channel LSB statistics of one or more files, side by side.

Usage: lsbstats.py FILE [FILE ...] [--prefix N] [--csv]

For each file the analysed range is its pixel block (whole file when it is not
a BMP), optionally limited to the first N bytes (--prefix). The range printed
as range=<start>..<end> is half-open (end exclusive). Never modifies any file.
"""
import sys
sys.dont_write_bytecode = True
import argparse
import collections

import bmplib

TOOL = 'lsbstats.py'
CHANS = ['B', 'G', 'R', 'PAD', 'ALL']
METRICS = ['bytes', 'lsb1_count', 'lsb1_ratio', 'bit1_ratio', 'bit2_ratio',
           'bit3_ratio', 'pat00', 'pat01', 'pat10', 'pat11', 'chi2_pov']


def hist(buf):
    h = [0] * 256
    for v, c in collections.Counter(buf).items():
        h[v] = c
    return h


def add_hist(dst, src):
    for i in range(256):
        dst[i] += src[i]


def analyse(data, prefix):
    """Return (info, start, end, {chan: hist or None})."""
    info = bmplib.parse_bmp(data)
    if info.is_bmp:
        start, end = info.pixel_offset, info.pixel_end
    else:
        start, end = 0, len(data)
    if prefix is not None:
        end = min(end, start + prefix)
    hists = dict((c, None) for c in CHANS)
    if info.is_bmp and info.channels_ok:
        hb = [[0] * 256 for _ in range(4)]  # B G R PAD
        colour_w = info.width * 3
        if info.stride == colour_w:
            block = data[start:end]
            for k in range(3):
                hb[k] = hist(block[k::3])
        else:
            row = 0
            while True:
                rs = start + row * info.stride
                if rs >= end:
                    break
                ce = min(rs + colour_w, end)
                seg = data[rs:ce]
                for k in range(3):
                    add_hist(hb[k], hist(seg[k::3]))
                pe = min(rs + info.stride, end)
                if pe > ce:
                    add_hist(hb[3], hist(data[ce:pe]))
                row += 1
        allh = [0] * 256
        for h in hb:
            add_hist(allh, h)
        for k, c in enumerate(('B', 'G', 'R', 'PAD')):
            hists[c] = hb[k]
        hists['ALL'] = allh
    else:
        hists['ALL'] = hist(data[start:end])
    return info, start, end, hists


def metrics(h):
    """Return dict metric -> printable string for one histogram (None -> '-')."""
    if h is None:
        return dict((m, '-') for m in METRICS)
    n = sum(h)
    out = {'bytes': str(n)}

    def bitcount(bit):
        return sum(h[v] for v in range(256) if (v >> bit) & 1)

    out['lsb1_count'] = str(bitcount(0))
    for name, bit in (('lsb1_ratio', 0), ('bit1_ratio', 1), ('bit2_ratio', 2), ('bit3_ratio', 3)):
        out[name] = '%.6f' % (bitcount(bit) / float(n)) if n else '-'
    for p in range(4):
        out['pat%d%d' % (p >> 1, p & 1)] = str(sum(h[v] for v in range(256) if ((v >> 1) & 3) == p))
    chi = 0.0
    used = False
    for k in range(128):
        e = (h[2 * k] + h[2 * k + 1]) / 2.0
        if e > 0:
            chi += (h[2 * k] - e) ** 2 / e
            used = True
    out['chi2_pov'] = '%.2f' % chi if used else '-'
    return out


def main(argv):
    ap = argparse.ArgumentParser(prog=TOOL, description='Per-channel LSB statistics.')
    ap.add_argument('files', nargs='+', metavar='FILE')
    ap.add_argument('--prefix', type=int, default=None, help='only the first N bytes of the pixel block')
    ap.add_argument('--csv', action='store_true', help='CSV output: one row per (file, chan)')
    args = ap.parse_args(argv)
    if args.prefix is not None and args.prefix < 0:
        bmplib.error_exit(TOOL, '--prefix must be >= 0')
    results = []
    for path in args.files:
        data = bmplib.read_input(path)
        info, start, end, hists = analyse(data, args.prefix)
        results.append((path, info, start, end, dict((c, metrics(hists[c])) for c in CHANS)))

    if args.csv:
        print('file,chan,' + ','.join(METRICS))
        for path, _info, _s, _e, m in results:
            for c in CHANS:
                print('%s,%s,%s' % (path.replace(',', '_'), c, ','.join(m[c][x] for x in METRICS)))
        return 0

    for k, (path, info, start, end, _m) in enumerate(results, 1):
        print('file[%d] path=%s bmp=%s pixel_offset=%s pixel_end=%s range=%d..%d' % (
            k, path, 'yes' if info.is_bmp else 'no',
            '-' if not info.is_bmp else info.pixel_offset,
            '-' if not info.is_bmp else info.pixel_end, start, end))
    for metric in METRICS:
        for c in CHANS:
            print('%s %s %s' % (metric, c, ' '.join(r[4][c][metric] for r in results)))
    return 0


if __name__ == '__main__':
    try:
        sys.exit(main(sys.argv[1:]))
    except (bmplib.ToolError, OSError) as e:
        bmplib.error_exit(TOOL, str(e))
