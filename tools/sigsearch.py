#!/usr/bin/env python3
"""sigsearch: find known file signatures (magic numbers) anywhere in a file.

Usage: sigsearch.py FILE [--all] [--dump OFFSET|appended OUT] [--max-size BYTES]

For a BMP the hits are labelled by region: header, pixel (the pixel block) or
appended (after the pixel block). For any other input the region is 'file'.
Weak signatures (2-byte MZ/BM and the MPEG start codes) match by chance in pixel
data, so by default they are shown only at the first appended byte of a BMP or
at offset 0 of a non-BMP file; --all shows every one of them.

Prints numbers, names and hex of the matched magic only. Never modifies the
scanned file: --dump writes to an explicit OUT that must not be the input.
"""
import sys
sys.dont_write_bytecode = True
import argparse

import bmplib

TOOL = 'sigsearch.py'
DEFAULT_MAX = 1024 * 1024 * 1024


def _simple(name, needle):
    """Entry whose match is the needle itself."""
    n = len(needle)
    return (needle, lambda d, p: (name, n, 0))


def _bzip2(d, p):
    if p + 10 <= len(d) and 0x31 <= d[p + 3] <= 0x39 and d[p + 4:p + 10] == b'\x31\x41\x59\x26\x53\x59':
        return ('BZIP2', 10, 0)
    return None


def _riff(d, p):
    kind = d[p + 8:p + 12]
    if kind == b'WAVE':
        return ('RIFF-WAVE', 12, 0)
    if kind == b'AVI ':
        return ('RIFF-AVI', 12, 0)
    return ('RIFF', 4, 0)


def _mp4(d, p):
    # 'ftyp' sits 4 bytes after the start of its box (the box size field)
    if p < 4:
        return None
    return ('MP4', 4, 4)


def _id3(d, p):
    if p + 3 < len(d) and 2 <= d[p + 3] <= 4:
        return ('MP3-ID3', 4, 0)
    return None


STRONG = [
    _simple('PNG', b'\x89PNG\r\n\x1a\n'),
    _simple('JPEG', b'\xff\xd8\xff'),
    _simple('GIF', b'GIF87a'),
    _simple('GIF', b'GIF89a'),
    _simple('PDF', b'%PDF-'),
    _simple('ZIP', b'PK\x03\x04'),
    _simple('ZIP-EOCD', b'PK\x05\x06'),
    _simple('RAR', b'Rar!\x1a\x07'),
    _simple('7Z', b'7z\xbc\xaf\x27\x1c'),
    _simple('GZIP', b'\x1f\x8b\x08'),
    (b'BZh', _bzip2),
    (b'RIFF', _riff),
    _simple('OGG', b'OggS'),
    _simple('MKV', b'\x1a\x45\xdf\xa3'),
    (b'ftyp', _mp4),
    _simple('ASF', b'\x30\x26\xb2\x75\x8e\x66\xcf\x11'),
    _simple('FLV', b'FLV\x01'),
    (b'ID3', _id3),
    _simple('ELF', b'\x7fELF'),
    _simple('TIFF', b'II*\x00'),
    _simple('TIFF', b'MM\x00*'),
    _simple('SQLITE', b'SQLite format 3\x00'),
    _simple('XML', b'<?xml'),
    _simple('PS', b'%!PS'),
]

WEAK = [
    _simple('MZ', b'MZ'),
    _simple('BMP', b'BM'),
    _simple('MPEG-PS', b'\x00\x00\x01\xba'),
    _simple('MPEG-VIDEO', b'\x00\x00\x01\xb3'),
]


def _find_all(data, needle, resolver, out, strength):
    pos = data.find(needle)
    while pos != -1:
        r = resolver(data, pos)
        if r is not None:
            name, mlen, shift = r
            off = pos - shift
            if off >= 0:
                out.append((off, name, strength, data[pos:pos + mlen]))
        pos = data.find(needle, pos + 1)


def scan(data, info, show_all):
    """Return the list of (offset, name, strength, magic_bytes), sorted."""
    hits = []
    for needle, resolver in STRONG:
        _find_all(data, needle, resolver, hits, 'strong')
    if info.is_bmp:
        weak_at = info.pixel_end if info.pixel_end < len(data) else None
    else:
        weak_at = 0 if len(data) > 0 else None
    for needle, resolver in WEAK:
        if show_all:
            found = []
            _find_all(data, needle, resolver, found, 'weak')
        else:
            found = []
            if weak_at is not None and data.startswith(needle, weak_at):
                r = resolver(data, weak_at)
                if r is not None:
                    found.append((weak_at, r[0], 'weak', data[weak_at:weak_at + r[1]]))
        for h in found:
            if info.is_bmp and h[1] == 'BMP' and h[0] == 0:
                continue  # the container's own signature
            hits.append(h)
    hits.sort(key=lambda h: (h[0], h[1]))
    return hits


def region_of(info, off):
    if not info.is_bmp:
        return 'file'
    if off < info.pixel_offset:
        return 'header'
    if off < info.pixel_end:
        return 'pixel'
    return 'appended'


def parse_offset(text, info, size):
    if text == 'appended':
        if not info.is_bmp:
            raise bmplib.ToolError("'appended' needs a BMP input; give a numeric offset")
        return info.pixel_end
    try:
        off = int(text, 0)
    except ValueError:
        raise bmplib.ToolError("invalid --dump offset '%s'" % text)
    if off < 0 or off > size:
        raise bmplib.ToolError('--dump offset %d is outside the file (0..%d)' % (off, size))
    return off


def main(argv):
    ap = argparse.ArgumentParser(prog=TOOL, description='Search a file for known magic numbers.')
    ap.add_argument('file')
    ap.add_argument('--all', action='store_true', help='also show every weak (2-byte / MPEG) match')
    ap.add_argument('--dump', nargs=2, metavar=('OFFSET', 'OUT'),
                    help="write bytes [OFFSET, EOF) to OUT; OFFSET may be the word 'appended'")
    ap.add_argument('--max-size', type=int, default=DEFAULT_MAX,
                    help='refuse files larger than this (default 1073741824)')
    args = ap.parse_args(argv)
    if args.max_size < 0:
        bmplib.error_exit(TOOL, '--max-size must be >= 0')

    data = bmplib.read_input(args.file, args.max_size)
    size = len(data)
    info = bmplib.parse_bmp(data)
    dump_off = None
    if args.dump:
        dump_off = parse_offset(args.dump[0], info, size)

    lines = ['file path=%s size=%d' % (args.file, size)]
    if info.is_bmp:
        lines.append('container type=BMP pixel_offset=%d pixel_end=%d declared_size=%d appended=%d truncated=%s' % (
            info.pixel_offset, info.pixel_end, info.declared_size, size - info.pixel_end,
            'yes' if info.truncated else 'no'))
    else:
        lines.append('container type=none')

    hits = scan(data, info, args.all)
    strong = weak = appended = 0
    for off, name, strength, magic in hits:
        region = region_of(info, off)
        if strength == 'strong':
            strong += 1
        else:
            weak += 1
        if region == 'appended':
            appended += 1
        lines.append('hit offset=%d region=%s type=%s strength=%s magic=%s' % (
            off, region, name, strength, magic.hex()))
    lines.append('summary hits=%d strong=%d weak=%d appended_region_hits=%d' % (
        len(hits), strong, weak, appended))

    if dump_off is not None:
        out = args.dump[1]
        bmplib.atomic_write(out, data[dump_off:], [args.file])
        lines.append('dumped offset=%d bytes=%d out=%s' % (dump_off, size - dump_off, out))

    sys.stdout.write('\n'.join(lines) + '\n')
    return 0


if __name__ == '__main__':
    try:
        sys.exit(main(sys.argv[1:]))
    except (bmplib.ToolError, OSError) as e:
        bmplib.error_exit(TOOL, str(e))
