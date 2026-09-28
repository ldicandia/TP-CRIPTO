"""Shared helpers for the stegobmp analysis tools (internal tooling, stdlib only).

Python 3.6+ compatible. No side effects on import.
"""
import collections
import os
import struct
import sys
import tempfile

MAX_INPUT = 512 * 1024 * 1024


class ToolError(Exception):
    """A user-facing error: printed as '<tool>: error: <msg>' and exit 1."""


BmpInfo = collections.namedtuple(
    'BmpInfo',
    'is_bmp reason declared_size pixel_offset width height bpp compression '
    'stride pixel_end pixel_len truncated top_down channels_ok')


def read_input(path, max_size=MAX_INPUT):
    """Read a whole file, checking its size first."""
    try:
        size = os.stat(path).st_size
    except OSError as e:
        raise ToolError("cannot read '%s': %s" % (path, e.strerror or e))
    if not os.path.isfile(path):
        raise ToolError("cannot read '%s': not a regular file" % path)
    if size > max_size:
        raise ToolError("'%s' is too large (%d bytes, limit %d)" % (path, size, max_size))
    try:
        with open(path, 'rb') as f:
            return f.read()
    except OSError as e:
        raise ToolError("cannot read '%s': %s" % (path, e.strerror or e))


def _bad(reason, **kw):
    vals = dict(is_bmp=False, reason=reason, declared_size=None, pixel_offset=None,
                width=None, height=None, bpp=None, compression=None, stride=None,
                pixel_end=None, pixel_len=None, truncated=False, top_down=False,
                channels_ok=False)
    vals.update(kw)
    return BmpInfo(**vals)


def parse_bmp(data):
    """Parse a BMP V3 header. Never raises."""
    n = len(data)
    if n < 54:
        return _bad('shorter than 54 bytes')
    if data[0:2] != b'BM':
        return _bad("missing 'BM' signature")
    declared_size, = struct.unpack_from('<I', data, 2)
    off, = struct.unpack_from('<I', data, 10)
    bisize, width, height = struct.unpack_from('<Iii', data, 14)
    bpp, = struct.unpack_from('<H', data, 28)
    comp, = struct.unpack_from('<I', data, 30)
    if bisize < 40:
        return _bad('biSize < 40')
    if width <= 0:
        return _bad('width <= 0')
    if height == 0:
        return _bad('height == 0')
    if off < 54 or off > n:
        return _bad('bfOffBits outside the file')
    stride = ((width * bpp + 31) // 32) * 4
    want = off + stride * abs(height)
    pixel_end = min(want, n)
    return BmpInfo(is_bmp=True, reason='', declared_size=declared_size,
                   pixel_offset=off, width=width, height=height, bpp=bpp,
                   compression=comp, stride=stride, pixel_end=pixel_end,
                   pixel_len=pixel_end - off, truncated=want > n,
                   top_down=height < 0, channels_ok=(bpp == 24 and comp == 0))


def classify(info, offset):
    """Return (region, row, col, chan) for a file offset."""
    if not info.is_bmp:
        return ('-', '-', '-', '-')
    if offset < info.pixel_offset:
        return ('HDR', '-', '-', '-')
    if offset >= info.pixel_end:
        return ('TRAIL', '-', '-', '-')
    rel = offset - info.pixel_offset
    row, col = divmod(rel, info.stride)
    if info.channels_ok:
        if col < info.width * 3:
            chan = 'BGR'[col % 3]
        else:
            chan = 'PAD'
    else:
        chan = '-'
    return ('PIX', row, col, chan)


def atomic_write(path, data, inputs):
    """Write data to path via a temp file, refusing to overwrite any input."""
    real = os.path.realpath(path)
    for inp in inputs:
        if os.path.realpath(inp) == real:
            raise ToolError("refusing to overwrite input file '%s'" % inp)
        try:
            if os.path.exists(path) and os.path.samefile(path, inp):
                raise ToolError("refusing to overwrite input file '%s'" % inp)
        except OSError:
            pass
    d = os.path.dirname(real) or '.'
    try:
        fd, tmp = tempfile.mkstemp(prefix='.bmptool-tmp-', dir=d)
    except OSError as e:
        raise ToolError("cannot write '%s': %s" % (path, e.strerror or e))
    try:
        with os.fdopen(fd, 'wb') as f:
            f.write(data)
        os.replace(tmp, path)
    except OSError as e:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise ToolError("cannot write '%s': %s" % (path, e.strerror or e))


def error_exit(tool, msg):
    sys.stderr.write('%s: error: %s\n' % (tool, msg))
    sys.exit(1)


def describe(info):
    """Fields for the carrier/suspect record ('-' for unknown)."""
    def f(v):
        return '-' if v is None else str(v)
    return ('bmp=%s pixel_offset=%s pixel_end=%s width=%s height=%s bpp=%s stride=%s' % (
        'yes' if info.is_bmp else 'no', f(info.pixel_offset), f(info.pixel_end),
        f(info.width), f(info.height), f(info.bpp), f(info.stride)))
