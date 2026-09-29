#!/usr/bin/env python3
"""cryptoref: independent oracle for stegobmp's encryption (python3 stdlib + the openssl CLI).

Subcommands:
  kdf ALG PASSWORD                      print key=<hex> and iv=<hex> (PBKDF2-HMAC-SHA256,
                                        8 zero bytes of salt, 10000 iterations, one call of
                                        keylen+ivlen bytes, key first)
  open STEGO METHOD ALG MODE PASSWORD OUTPREFIX [--key HEX] [--iv HEX]
                                        read BE32(cipher size) || ciphertext out of STEGO
                                        (METHOD LSB1|LSB4|LSBI), decrypt it with `openssl enc -d`,
                                        check BE32(size) || data || ext || NUL and write
                                        OUTPREFIX+ext; prints cipher_size=<n> size=<s> ext=<ext>

ALG is aes128|aes192|aes256|3des, MODE is ecb|cfb|ofb|cbc. cfb maps to the 8-bit variant
(cfb8) and ofb to the full-block one, exactly like the cátedra's OpenSSL table.

Internal tooling: it never shares code with the C implementation, so a disagreement between
the two is a bug to explain. It is the oracle for the tests, not the deliverable.
"""
import sys
sys.dont_write_bytecode = True
import argparse
import hashlib
import subprocess

import bmplib
import lsbi

TOOL = 'cryptoref.py'

# name: (key_len, iv_len, block, openssl prefix)
ALGS = {
    'aes128': (16, 16, 16, 'aes-128'),
    'aes192': (24, 16, 16, 'aes-192'),
    'aes256': (32, 16, 16, 'aes-256'),
    '3des': (24, 8, 8, 'des-ede3'),
}
MODES = {'ecb': 'ecb', 'cfb': 'cfb8', 'ofb': 'ofb', 'cbc': 'cbc'}
SALT = bytes(8)
ITERATIONS = 10000


def derive(alg, password):
    """One PBKDF2 call over the raw password bytes; returns (key, iv)."""
    key_len, iv_len, _block, _prefix = ALGS[alg]
    pw = password.encode('utf-8', 'surrogateescape')
    buf = hashlib.pbkdf2_hmac('sha256', pw, SALT, ITERATIONS, key_len + iv_len)
    return buf[:key_len], buf[key_len:]


def read_lsb(pix, nbytes, bits):
    """Read nbytes from an LSB1 (bits=1) or LSB4 (bits=4) stream, MSB first."""
    mask = (1 << bits) - 1
    out = bytearray()
    cur = 0
    have = 0
    for b in pix:
        cur = (cur << bits) | (b & mask)
        have += bits
        if have == 8:
            out.append(cur)
            cur = 0
            have = 0
            if len(out) == nbytes:
                break
    return bytes(out)


def stream_capacity(method, pix):
    if method == 'LSB1':
        return len(pix) // 8
    if method == 'LSB4':
        return len(pix) // 2
    return lsbi.capacity(len(pix), lsbi.DEFAULT_HYP)


def read_stream(method, pix, nbytes):
    if method == 'LSB1':
        return read_lsb(pix, nbytes, 1)
    if method == 'LSB4':
        return read_lsb(pix, nbytes, 4)
    data, _flags = lsbi.lsbi_read(pix, nbytes)
    return data


def openssl_decrypt(alg, mode, key, iv, cipher):
    name = '%s-%s' % (ALGS[alg][3], MODES[mode])
    cmd = ['openssl', 'enc', '-d', '-' + name, '-K', key.hex(), '-nosalt']
    if mode != 'ecb':
        cmd += ['-iv', iv.hex()]
    try:
        proc = subprocess.run(cmd, input=cipher, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    except OSError as e:
        raise bmplib.ToolError('cannot run openssl: %s' % e)
    if proc.returncode != 0:
        raise bmplib.ToolError('openssl could not decrypt (bad padding?)')
    return proc.stdout


def parse_plain(plain):
    """Strict framing of a decrypted plaintext; returns (data, ext str)."""
    if len(plain) < 6:
        raise bmplib.ToolError('decrypted data too short (%d bytes)' % len(plain))
    size = int.from_bytes(plain[:4], 'big')
    if 4 + size + 2 > len(plain):
        raise bmplib.ToolError('decrypted size field says %d bytes but the plaintext has only %d bytes'
                               % (size, len(plain)))
    if plain[-1] != 0:
        raise bmplib.ToolError('decrypted data does not end with a NUL byte')
    ext = plain[4 + size:-1]
    if b'\x00' in ext or not lsbi.ext_is_valid(ext):
        raise bmplib.ToolError('decrypted extension field is malformed')
    return plain[4:4 + size], ext.decode('ascii')


def parse_hex(name, value, length):
    try:
        raw = bytes.fromhex(value)
    except ValueError:
        raise bmplib.ToolError('%s is not valid hex' % name)
    if len(raw) != length:
        raise bmplib.ToolError('%s must be %d bytes, got %d' % (name, length, len(raw)))
    return raw


def cmd_kdf(a):
    key, iv = derive(a.alg, a.password)
    print('key=%s' % key.hex())
    print('iv=%s' % iv.hex())
    return 0


def cmd_open(a):
    data, info = lsbi.load_carrier(a.stego)
    pix = data[info.pixel_offset:info.pixel_end]
    key, iv = derive(a.alg, a.password)
    if a.key is not None:
        key = parse_hex('--key', a.key, ALGS[a.alg][0])
    if a.iv is not None:
        iv = parse_hex('--iv', a.iv, ALGS[a.alg][1])
    cap = stream_capacity(a.method, pix)
    if cap < 4:
        raise bmplib.ToolError('carrier too small to hold a size field')
    n = int.from_bytes(read_stream(a.method, pix, 4), 'big')
    if n < 1 or n > cap - 4:
        raise bmplib.ToolError('hidden ciphertext size field says %d bytes (capacity %d)' % (n, cap - 4))
    cipher = read_stream(a.method, pix, 4 + n)[4:]
    plain = openssl_decrypt(a.alg, a.mode, key, iv, cipher)
    body, ext = parse_plain(plain)
    bmplib.atomic_write(a.outprefix + ext, body, [a.stego])
    print('cipher_size=%d size=%d ext=%s' % (n, len(body), ext))
    return 0


def main(argv):
    ap = argparse.ArgumentParser(prog=TOOL, description='Independent oracle for stegobmp encryption.')
    sub = ap.add_subparsers(dest='cmd')
    sub.required = True
    p = sub.add_parser('kdf')
    p.add_argument('alg', choices=sorted(ALGS))
    p.add_argument('password')
    p.set_defaults(fn=cmd_kdf)
    p = sub.add_parser('open')
    p.add_argument('stego')
    p.add_argument('method', choices=['LSB1', 'LSB4', 'LSBI'])
    p.add_argument('alg', choices=sorted(ALGS))
    p.add_argument('mode', choices=sorted(MODES))
    p.add_argument('password')
    p.add_argument('outprefix')
    p.add_argument('--key')
    p.add_argument('--iv')
    p.set_defaults(fn=cmd_open)
    args = ap.parse_args(argv)
    return args.fn(args)


if __name__ == '__main__':
    try:
        sys.exit(main(sys.argv[1:]))
    except (bmplib.ToolError, OSError) as e:
        bmplib.error_exit(TOOL, str(e))
