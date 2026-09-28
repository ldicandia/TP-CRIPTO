#!/usr/bin/env python3
"""bmpdiff: byte/bit diff between a carrier BMP and a suspect (stego) file.

Usage: bmpdiff.py CARRIER SUSPECT [--limit N] [--csv]

Prints numbers and hex only. Never modifies any file.
"""
import sys
sys.dont_write_bytecode = True
import argparse
import math

import bmplib

TOOL = 'bmpdiff.py'


def diff_offsets(a, b):
    n = min(len(a), len(b))
    if a[:n] == b[:n]:
        return []
    return [i for i, (x, y) in enumerate(zip(a[:n], b[:n])) if x != y]


def color_samples(info, common):
    """Number of B/G/R bytes (padding excluded) inside the common length."""
    total = 0
    limit = min(info.pixel_end, common)
    row = 0
    while True:
        start = info.pixel_offset + row * info.stride
        if start >= limit:
            break
        hi = min(start + info.width * 3, limit)
        total += max(0, hi - start)
        row += 1
    return total


def analyse(a, b, limit):
    info = bmplib.parse_bmp(a)
    common = min(len(a), len(b))
    offs = diff_offsets(a, b)
    res = {'info': info, 'common': common, 'offs': offs}
    chan = {'B': 0, 'G': 0, 'R': 0, 'PAD': 0, 'HDR': 0, 'TRAIL': 0, 'OTHER': 0}
    bitpos = [0] * 8
    mask = 0
    sq_color = 0
    sq_all = 0
    for o in offs:
        x = a[o] ^ b[o]
        mask |= x
        for k in range(8):
            if (x >> k) & 1:
                bitpos[k] += 1
        d = a[o] - b[o]
        sq_all += d * d
        region, _r, _c, ch = bmplib.classify(info, o)
        if region == 'HDR':
            chan['HDR'] += 1
        elif region == 'TRAIL':
            chan['TRAIL'] += 1
        elif region == 'PIX' and ch in ('B', 'G', 'R', 'PAD'):
            chan[ch] += 1
            if ch != 'PAD':
                sq_color += d * d
        else:
            chan['OTHER'] += 1
    res.update(chan=chan, bitpos=bitpos, mask=mask, changed_bits=sum(bitpos))
    if info.is_bmp and info.channels_ok:
        samples = color_samples(info, common)
        sq = sq_color
        basis = 'pixels'
    else:
        samples = common
        sq = sq_all
        basis = 'raw'
    mse = (sq / float(samples)) if samples else 0.0
    psnr = None if mse == 0 else 10.0 * math.log10(255.0 * 255.0 / mse)
    res.update(samples=samples, basis=basis, mse=mse, psnr=psnr)
    return res


def main(argv):
    ap = argparse.ArgumentParser(prog=TOOL, description='Diff a carrier BMP against a suspect file.')
    ap.add_argument('carrier')
    ap.add_argument('suspect')
    ap.add_argument('--limit', type=int, default=20, help='max diff lines (0 = all, default 20)')
    ap.add_argument('--csv', action='store_true', help='print one CSV header and one row')
    args = ap.parse_args(argv)
    if args.limit < 0:
        bmplib.error_exit(TOOL, '--limit must be >= 0')
    a = bmplib.read_input(args.carrier)
    b = bmplib.read_input(args.suspect)
    r = analyse(a, b, args.limit)
    info = r['info']
    binfo = bmplib.parse_bmp(b)
    offs = r['offs']
    chan = r['chan']
    psnr_txt = 'inf' if r['psnr'] is None else '%.4f' % r['psnr']
    first = '-' if not offs else str(offs[0])
    last = '-' if not offs else str(offs[-1])
    extra = len(b) - len(a)

    if args.csv:
        print('carrier,suspect,changed_bytes,changed_bits,mask,first,last,B,G,R,PAD,HDR,TRAIL,OTHER,mse,psnr,samples,extra')
        print('%s,%s,%d,%d,0x%02x,%s,%s,%d,%d,%d,%d,%d,%d,%d,%.6f,%s,%d,%d' % (
            args.carrier.replace(',', '_'), args.suspect.replace(',', '_'),
            len(offs), r['changed_bits'], r['mask'], first, last,
            chan['B'], chan['G'], chan['R'], chan['PAD'], chan['HDR'],
            chan['TRAIL'], chan['OTHER'], r['mse'], psnr_txt, r['samples'], extra))
        return 0

    print('carrier path=%s size=%d %s' % (args.carrier, len(a), bmplib.describe(info)))
    print('suspect path=%s size=%d %s' % (args.suspect, len(b), bmplib.describe(binfo)))
    hn = min(54, r['common'])
    hdiff = sum(1 for i in range(hn) if a[i] != b[i])
    print('header identical=%s differing=%d' % ('yes' if hdiff == 0 else 'no', hdiff))
    shown = offs if args.limit == 0 else offs[:args.limit]
    for o in shown:
        region, row, col, ch = bmplib.classify(info, o)
        x = a[o] ^ b[o]
        print('diff offset=%d region=%s row=%s col=%s chan=%s old=0x%02x new=0x%02x xor=0x%02x' % (
            o, region, row, col, ch, a[o], b[o], x))
    if len(shown) < len(offs):
        print('more not_shown=%d' % (len(offs) - len(shown)))
    print('summary changed_bytes=%d changed_bits=%d mask=0x%02x first=%s last=%s' % (
        len(offs), r['changed_bits'], r['mask'], first, last))
    print('channels B=%d G=%d R=%d PAD=%d HDR=%d TRAIL=%d OTHER=%d' % (
        chan['B'], chan['G'], chan['R'], chan['PAD'], chan['HDR'], chan['TRAIL'], chan['OTHER']))
    print('bitpos ' + ' '.join('b%d=%d' % (k, v) for k, v in enumerate(r['bitpos'])))
    print('distortion mse=%.6f psnr=%s samples=%d basis=%s' % (
        r['mse'], psnr_txt, r['samples'], r['basis']))
    print('length carrier=%d suspect=%d extra=%d' % (len(a), len(b), extra))
    if extra > 0:
        print('extra_bytes offset=%d..%d' % (len(a), len(b) - 1))
    return 0


if __name__ == '__main__':
    try:
        sys.exit(main(sys.argv[1:]))
    except (bmplib.ToolError, OSError) as e:
        bmplib.error_exit(TOOL, str(e))
