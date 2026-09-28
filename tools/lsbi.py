#!/usr/bin/env python3
"""lsbi: LSBI (Majeed & Sulaiman, "LSB Improved") reference model and probe.

Subcommands:
  probe CARRIER STEGO [hypothesis switches]   decode STEGO, re-embed, compare
  extract-raw STEGO OUT [--body-only]         dump the hidden byte string
  embed-raw CARRIER PAYLOAD OUT               embed the exact PAYLOAD bytes
  embed-file CARRIER INFILE OUT               embed BE32(len)||data||ext||NUL

The model works on the pixel block only (BMP V3, 24 bpp). Flags live in the LSB
of pixel bytes 0..3 (never inverted); message bits start at pixel byte 4 and
skip every byte whose pixel-block index i has i % 3 == 2 (red).

Internal tooling: it is the oracle for the C implementation, not the deliverable.
"""
import sys
sys.dont_write_bytecode = True
import argparse
import collections
import os

import bmplib

TOOL = 'lsbi.py'

Hypothesis = collections.namedtuple(
    'Hypothesis',
    'use_red red_relative flag_order pattern_bits tie bit_order count_red flag_zero_inverts')
DEFAULT_HYP = Hypothesis(use_red=False, red_relative=False, flag_order='spec',
                         pattern_bits='21', tie='strict', bit_order='msb',
                         count_red=False, flag_zero_inverts=False)

MAX_EXT = 32  # bytes, including the leading '.', excluding the NUL


def skip_index(i, hyp):
    """True when carrier index i is a red byte that must not carry message bits."""
    if hyp.use_red:
        return False
    if hyp.red_relative:
        return (i - 4) % 3 == 2
    return i % 3 == 2


def positions(start, n_bits, pixel_len, hyp):
    """Yield the carrier indices of the next n_bits message bits, from `start`."""
    i = start
    produced = 0
    while produced < n_bits:
        if i >= pixel_len:
            raise bmplib.ToolError('carrier ran out of message-carrying bytes')
        if not skip_index(i, hyp):
            yield i
            produced += 1
        i += 1


def capacity(pixel_len, hyp):
    """Payload capacity in bytes (message bits start at pixel byte 4)."""
    if pixel_len < 4:
        return 0
    if hyp.use_red:
        usable = pixel_len - 4
    elif hyp.red_relative:
        m = pixel_len - 4
        usable = m - m // 3
    else:
        usable = pixel_len - pixel_len // 3 - 3
    return max(usable, 0) // 8


def pattern(b, hyp):
    p = (b >> 1) & 3
    if hyp.pattern_bits == '12':
        p = ((p & 1) << 1) | (p >> 1)
    return p


def flag_index(p, hyp):
    return p if hyp.flag_order == 'spec' else 3 - p


def read_flags(pix, hyp):
    """Flags by pattern (index 0..3 = pattern 00, 01, 10, 11)."""
    return [pix[flag_index(p, hyp)] & 1 for p in range(4)]


def flags_text(flags):
    return ''.join(str(f) for f in flags)


def lsbi_embed(pix, payload, hyp=DEFAULT_HYP):
    """Embed payload into the bytearray pix in place.

    Returns (flags, changed, unchanged); all three are indexed by pattern.
    """
    cap = capacity(len(pix), hyp)
    if len(payload) > cap:
        raise bmplib.ToolError(
            'payload of %d bytes exceeds the LSBI capacity of %d bytes' % (len(payload), cap))
    idx = list(positions(4, len(payload) * 8, len(pix), hyp))
    bits = []
    order = range(7, -1, -1) if hyp.bit_order == 'msb' else range(8)
    for byte in payload:
        for k in order:
            bits.append((byte >> k) & 1)
    changed = [0] * 4
    unchanged = [0] * 4
    for i, bit in zip(idx, bits):
        p = pattern(pix[i], hyp)
        if (pix[i] & 1) != bit:
            changed[p] += 1
        else:
            unchanged[p] += 1
    if hyp.count_red and idx and not hyp.use_red:
        # Rejected hypothesis: red bytes inside the message span count as unchanged.
        for i in range(4, idx[-1] + 1):
            if skip_index(i, hyp):
                unchanged[pattern(pix[i], hyp)] += 1
    flags = []
    zi = 1 if hyp.flag_zero_inverts else 0
    for p in range(4):
        if hyp.tie == 'invert':
            inv = 1 if changed[p] >= unchanged[p] and changed[p] > 0 else 0
        else:
            inv = 1 if changed[p] > unchanged[p] else 0
        flags.append(inv ^ zi)  # stored flag value
    for p in range(4):
        j = flag_index(p, hyp)
        pix[j] = (pix[j] & 0xFE) | flags[p]
    for i, bit in zip(idx, bits):
        p = pattern(pix[i], hyp)
        pix[i] = (pix[i] & 0xFE) | (bit ^ flags[p] ^ zi)
    return flags, changed, unchanged


def lsbi_read(pix, nbytes, hyp=DEFAULT_HYP):
    """Decode the first nbytes hidden bytes. Returns (bytes, flags)."""
    flags = read_flags(pix, hyp)
    zi = 1 if hyp.flag_zero_inverts else 0
    out = bytearray()
    it = positions(4, nbytes * 8, len(pix), hyp)
    cur = 0
    n = 0
    msb = hyp.bit_order == 'msb'
    for i in it:
        b = pix[i]
        bit = (b & 1) ^ flags[pattern(b, hyp)] ^ zi
        cur = ((cur << 1) | bit) if msb else (cur | (bit << n))
        n += 1
        if n == 8:
            out.append(cur)
            cur = 0
            n = 0
    return bytes(out), flags


def ext_is_valid(ext):
    if not (1 <= len(ext) <= MAX_EXT) or ext[0:1] != b'.':
        return False
    for c in ext[1:]:
        if c < 0x21 or c > 0x7E or c in (0x2F, 0x5C):
            return False
    return True


def parse_framing(pix, hyp=DEFAULT_HYP, mode='auto'):
    """Decide the framing of the hidden stream.

    Returns (framing, size, ext, payload) where framing is plain|cipher|invalid,
    ext is a str ('-' when none) and payload is the exact hidden byte string
    (size field included; ext and NUL included for plain), or None if invalid.
    size is None when fewer than 4 bytes fit.
    """
    cap = capacity(len(pix), hyp)
    if cap < 4:
        return 'invalid', None, '-', None
    head, _flags = lsbi_read(pix, 4, hyp)
    size = int.from_bytes(head, 'big')
    if 4 + size > cap:
        return 'invalid', size, '-', None
    want = min(cap, 4 + size + MAX_EXT + 1)
    buf, _flags = lsbi_read(pix, want, hyp)
    tail = buf[4 + size:]
    nul = tail.find(b'\x00')
    plain_ok = 0 <= nul <= MAX_EXT and ext_is_valid(tail[:nul])
    if mode == 'plain' or (mode == 'auto' and plain_ok):
        if not plain_ok:
            return 'invalid', size, '-', None
        return 'plain', size, tail[:nul].decode('ascii'), buf[:4 + size + nul + 1]
    return 'cipher', size, '-', buf[:4 + size]


def payload_extension_of(path):
    """Mirror src/payload.c payload_extension_of."""
    base = os.path.basename(path)
    dot = base.rfind('.')
    if dot < 0:
        return '.'
    ext = base[dot:]
    if not ext_is_valid(ext.encode('utf-8', 'surrogateescape')):
        raise bmplib.ToolError("invalid file extension '%s'" % ext.encode('ascii', 'replace').decode())
    return ext


def frame_file(data, ext):
    if len(data) > 0xFFFFFFFF:
        raise bmplib.ToolError('input is too large for a 32-bit size field')
    return len(data).to_bytes(4, 'big') + data + ext.encode('ascii') + b'\x00'


def load_carrier(path):
    """Return (data, info) for a 24-bpp uncompressed BMP, else raise."""
    data = bmplib.read_input(path)
    info = bmplib.parse_bmp(data)
    if not info.is_bmp:
        raise bmplib.ToolError("'%s' is not a BMP V3 file (%s)" % (path, info.reason))
    if not info.channels_ok:
        raise bmplib.ToolError("'%s' is not an uncompressed 24-bpp BMP" % path)
    return data, info


def hyp_from_args(a):
    return Hypothesis(use_red=a.use_red, red_relative=a.red_relative,
                      flag_order=a.flag_order, pattern_bits=a.pattern_bits, tie=a.tie,
                      bit_order=a.bit_order, count_red=a.count_red,
                      flag_zero_inverts=a.flag_zero_inverts)


def add_hyp_args(p):
    p.add_argument('--use-red', action='store_true', help='also carry message bits in red bytes')
    p.add_argument('--red-relative', action='store_true', help='count red bytes from byte 4, not from the block start')
    p.add_argument('--flag-order', choices=['spec', 'reversed'], default='spec')
    p.add_argument('--pattern-bits', choices=['21', '12'], default='21')
    p.add_argument('--tie', choices=['strict', 'invert'], default='strict')
    p.add_argument('--framing', choices=['auto', 'plain', 'cipher'], default='auto')
    # Research switches used only to refute alternative readings (see docs/LSBI-NOTES.md).
    p.add_argument('--bit-order', choices=['msb', 'lsb'], default='msb')
    p.add_argument('--count-red', action='store_true',
                   help='count red bytes of the message span as unchanged when deciding flags')
    p.add_argument('--flag-zero-inverts', action='store_true',
                   help='read flag 0 as "inverted" instead of flag 1')


def cmd_probe(a):
    hyp = hyp_from_args(a)
    cdata, cinfo = load_carrier(a.carrier)
    sdata, sinfo = load_carrier(a.stego)
    if cinfo.pixel_len != sinfo.pixel_len:
        raise bmplib.ToolError('carrier and stego pixel blocks differ in length (%d vs %d)' % (
            cinfo.pixel_len, sinfo.pixel_len))
    cpix = bytearray(cdata[cinfo.pixel_offset:cinfo.pixel_end])
    spix = bytearray(sdata[sinfo.pixel_offset:sinfo.pixel_end])
    extras = ''
    if hyp.bit_order == 'lsb':
        extras += ' bit_order=lsb'
    if hyp.count_red:
        extras += ' count_red=yes'
    if hyp.flag_zero_inverts:
        extras += ' flag_zero_inverts=yes'
    print('hypothesis channels=%s red_origin=%s flag_order=%s pattern_bits=%s tie=%s%s' % (
        'BGR' if hyp.use_red else 'BG', 'relative' if hyp.red_relative else 'absolute',
        '00,01,10,11' if hyp.flag_order == 'spec' else '11,10,01,00',
        hyp.pattern_bits, hyp.tie, extras))
    print('capacity=%d' % capacity(len(spix), hyp))
    flags = read_flags(spix, hyp) if len(spix) >= 4 else [0, 0, 0, 0]
    print('flags=%s' % flags_text(flags))
    framing, size, ext, payload = parse_framing(spix, hyp, a.framing)
    print('size=%s' % ('-' if size is None else size))
    print('framing=%s ext=%s' % (framing, ext))
    if framing == 'invalid':
        print('reembed_identical=no')
        return 0
    rflags, changed, unchanged = lsbi_embed(cpix, payload, hyp)
    for p in range(4):
        print('counts pattern=%d%d changed=%d unchanged=%d invert=%d' % (
            p >> 1, p & 1, changed[p], unchanged[p], rflags[p]))
    print('recomputed_flags=%s match=%s' % (flags_text(rflags), 'yes' if rflags == flags else 'no'))
    recon = cdata[:cinfo.pixel_offset] + bytes(cpix) + cdata[cinfo.pixel_end:]
    print('reembed_identical=%s' % ('yes' if recon == sdata else 'no'))
    return 0


def cmd_extract_raw(a):
    hyp = hyp_from_args(a)
    sdata, sinfo = load_carrier(a.stego)
    spix = bytearray(sdata[sinfo.pixel_offset:sinfo.pixel_end])
    framing, size, _ext, payload = parse_framing(spix, hyp, a.framing)
    if framing == 'invalid':
        raise bmplib.ToolError('no valid hidden stream found in %s' % a.stego)
    out = payload[4:4 + size] if a.body_only else payload
    bmplib.atomic_write(a.out, out, [a.stego])
    print('wrote %d bytes framing=%s' % (len(out), framing))
    return 0


def embed_common(carrier, out, payload, hyp):
    cdata, cinfo = load_carrier(carrier)
    cpix = bytearray(cdata[cinfo.pixel_offset:cinfo.pixel_end])
    flags, _c, _u = lsbi_embed(cpix, payload, hyp)
    res = cdata[:cinfo.pixel_offset] + bytes(cpix) + cdata[cinfo.pixel_end:]
    return res, flags


def cmd_embed_raw(a):
    hyp = hyp_from_args(a)
    payload = bmplib.read_input(a.payload)
    res, flags = embed_common(a.carrier, a.out, payload, hyp)
    bmplib.atomic_write(a.out, res, [a.carrier, a.payload])
    print('embedded %d bytes flags=%s' % (len(payload), flags_text(flags)))
    return 0


def cmd_embed_file(a):
    hyp = hyp_from_args(a)
    data = bmplib.read_input(a.infile)
    payload = frame_file(data, payload_extension_of(a.infile))
    res, flags = embed_common(a.carrier, a.out, payload, hyp)
    bmplib.atomic_write(a.out, res, [a.carrier, a.infile])
    print('embedded %d bytes flags=%s' % (len(payload), flags_text(flags)))
    return 0


def main(argv):
    ap = argparse.ArgumentParser(prog=TOOL, description='LSBI reference model and probe.')
    sub = ap.add_subparsers(dest='cmd')
    sub.required = True
    p = sub.add_parser('probe')
    p.add_argument('carrier')
    p.add_argument('stego')
    add_hyp_args(p)
    p.set_defaults(fn=cmd_probe)
    p = sub.add_parser('extract-raw')
    p.add_argument('stego')
    p.add_argument('out')
    p.add_argument('--body-only', action='store_true')
    add_hyp_args(p)
    p.set_defaults(fn=cmd_extract_raw)
    p = sub.add_parser('embed-raw')
    p.add_argument('carrier')
    p.add_argument('payload')
    p.add_argument('out')
    add_hyp_args(p)
    p.set_defaults(fn=cmd_embed_raw)
    p = sub.add_parser('embed-file')
    p.add_argument('carrier')
    p.add_argument('infile')
    p.add_argument('out')
    add_hyp_args(p)
    p.set_defaults(fn=cmd_embed_file)
    args = ap.parse_args(argv)
    return args.fn(args)


if __name__ == '__main__':
    try:
        sys.exit(main(sys.argv[1:]))
    except (bmplib.ToolError, OSError) as e:
        bmplib.error_exit(TOOL, str(e))
