# Crypto notes: resolved ambiguities, README.txt errata, measured data

Date: 2026-09-28. Input for report question IX (implementation difficulties) and for the encryption sections of the report.

Sources:

- TP: `Trabajo Practico Implementacion-2026_2.pdf` (page numbers below are the printed page numbers 1-5).
- Vectors: `Ejemplo/lado.bmp` (carrier), `ladoLSB1aes128cbc.bmp`, `ladoLSBIaes256ofb.bmp`, `ladoLSBIdescfb.bmp`, all hiding the same 44886-byte PNG (sha256 `b93be15382f35f099ca286241dd7bb6e681d5bce8d315ac0b6240f0b516f549d`), and `Ejemplo/README.txt`.
- Tools: `tools/cryptoref.py` (independent oracle: Python `hashlib.pbkdf2_hmac` plus the `openssl enc` CLI, sharing no code with the C implementation) and the `stegobmp` binary. Run everything from the repo root on Linux/WSL.

Status vocabulary, used exactly: `verified-by-vector` means a cited run on a cátedra vector shows the alternative reading failing (or the chosen one reproducing the vector byte for byte). `flagged-unverified` means the vectors cannot decide the choice, so it is a design decision that must be re-checked if a new cátedra file contradicts it.

Model summary (what `src/crypto.c` and `src/payload.c` implement):

- One PKCS5_PBKDF2_HMAC call (SHA-256, 10000 iterations, salt = 8 zero bytes) over the raw password bytes, producing `key_len + iv_len` bytes; key = the first `key_len`, IV = the next `iv_len`.
- Lengths: aes128 16/16, aes192 24/16, aes256 32/16, 3des 24/8 (key/IV bytes).
- Ciphers: EVP `*_ecb`, `*_cfb8`, `*_ofb`, `*_cbc` for aes-128/192/256 and des-ede3. PKCS5 padding for ecb and cbc only.
- Hidden stream with `-pass`: `BE32(cipher size) || Enc(BE32(size) || data || ".ext" || 0x00)`. Nothing is random: same inputs, same bytes.

## Resolved ambiguities

### K1 — PBKDF2 parameters

- **Question:** Which PRF, iteration count and salt, and is the password used as raw bytes?
- **Spec says (page 5):** PBKDF2 with SHA-256, 10000 iterations, a fixed salt of 8 zero bytes.
- **Ejemplo README says:** "PBKDF2, usando sha256, con salt 0x0000000000000000, 10000 iteraciones", password `margarita`.
- **Evidence:** `python3 tools/cryptoref.py kdf aes256 margarita` prints `key=03db0a157acfe8de523760aa731d8122b25f8d99f3173ec0b52849f459a4c20d` and `iv=212420edc583a686a94d19a3497363a2`, both equal to the README's aes256 values (the README is the cátedra's own PBKDF2 output). `./stegobmp -extract -p Ejemplo/ladoLSBIaes256ofb.bmp -out h -steg LSBI -a aes256 -m ofb -pass margarita` prints `stegobmp: extracted 44886 bytes to 'h.png' (decrypted with aes256-ofb)` and the PNG has the reference sha256.
- **Resolution:** the password is passed to PBKDF2 as its raw argv bytes (`strlen`, no NUL, no trimming, no case folding, no normalisation). A UTF-8 password (`contraseña con espacios`) round-trips and is recovered by the oracle with the same string (test `edge-password-utf8`).
- **Status:** verified-by-vector.

### K2 — Key/IV split

- **Question:** Are key and IV taken from one derivation (key first), or derived separately?
- **Spec says (page 5):** the key and the IV are separated out of a single PBKDF2 output.
- **Ejemplo README says:** aes256 key = derived bytes 0-31 and IV = bytes 32-47; 3des key = bytes 0-23 and IV = bytes 24-31.
- **Evidence:** `python3 tools/cryptoref.py open Ejemplo/ladoLSBIaes256ofb.bmp LSBI aes256 ofb margarita d` prints `cipher_size=44895 size=44886 ext=.png`; `python3 tools/cryptoref.py open Ejemplo/ladoLSBIdescfb.bmp LSBI 3des cfb margarita d` prints `cipher_size=44895 size=44886 ext=.png`; `python3 tools/cryptoref.py open Ejemplo/ladoLSB1aes128cbc.bmp LSB1 aes128 cbc margarita d` prints `cipher_size=44896 size=44886 ext=.png`. A single `PKCS5_PBKDF2_HMAC` call of `key_len + iv_len` bytes therefore reproduces all three vectors, and `tests vector-reembed-*` re-embeds them byte for byte.
- **Resolution:** derive `key_len + iv_len` bytes in one call; key first, then IV. The output length depends on the algorithm (an aes128 derivation is 32 bytes, not 48).
- **Status:** verified-by-vector.

### K3 — README.txt aes128 errata

- **Question:** `Ejemplo/README.txt` lists, for `ladoLSB1aes128cbc.bmp`, "Key derivada (32 bytes): 03db0a157acfe8de523760aa731d8122" and "IV derivada (16 bytes): 212420edc583a686a94d19a3497363a2". Which of these is right?
- **Spec says:** nothing about this file.
- **Ejemplo README says:** the two lines above. The key shown is 16 bytes (32 hex digits) although labelled "32 bytes", and the IV shown is bytes 32-47 of the derivation, i.e. the aes256 IV.
- **Evidence:** `python3 tools/cryptoref.py kdf aes128 margarita` prints `key=03db0a157acfe8de523760aa731d8122` and `iv=b25f8d99f3173ec0b52849f459a4c20d`. With that split IV, `python3 tools/cryptoref.py open Ejemplo/ladoLSB1aes128cbc.bmp LSB1 aes128 cbc margarita d` prints `cipher_size=44896 size=44886 ext=.png` and writes the PNG. With the README's IV, `python3 tools/cryptoref.py open Ejemplo/ladoLSB1aes128cbc.bmp LSB1 aes128 cbc margarita d --iv 212420edc583a686a94d19a3497363a2` exits 1 with `cryptoref.py: error: decrypted size field says 2474312226 bytes but the plaintext has only 44895 bytes` and writes nothing (the first CBC block is garbage; only the IV differs, so the padding of the last block is still valid).
- **Resolution:** the README's aes128 IV is an erratum (copy of the aes256 IV). The rule of K2 (split key-then-IV) is what the vector obeys. The README's aes128 key value is correct (equal to the first 16 bytes); only its "32 bytes" label is wrong. Tests `cryptoref-kdf-aes128` and `cryptoref-readme-aes128-iv-erratum` pin both facts.
- **Status:** verified-by-vector.

### K4 — aes192 by rule

- **Question:** What are the key and IV for aes192, which has no cátedra vector?
- **Spec says (page 5):** the same derivation applies to every algorithm.
- **Ejemplo README says:** nothing (no aes192 file).
- **Evidence:** `python3 tools/cryptoref.py kdf aes192 margarita` prints `key=03db0a157acfe8de523760aa731d8122b25f8d99f3173ec0` and `iv=b52849f459a4c20d212420edc583a686`, that is key = bytes 0-23 and IV = bytes 24-39 by the K2 rule. `differential-crypto-aes192-*` (four cases) show stegobmp and the independent oracle agreeing on this derivation, but both apply the same rule, so this proves consistency only.
- **Resolution:** aes192 follows K2. If the cátedra ever supplies an aes192 file that contradicts it, this is the first thing to re-check.
- **Status:** flagged-unverified.

### K5 — Encrypted payload framing and ciphertext sizes

- **Question:** What exactly is hidden, and is anything appended after the extension's NUL?
- **Spec says (page 3, page 4 top):** cipher size || encryption(real size || file data || extension).
- **Ejemplo README says:** nothing about framing.
- **Evidence:** the hidden size field is 44896 for aes128-cbc (`cipher_size=44896` above: 44895 plaintext bytes + 1 PKCS5 byte, since 44895 = 4 + 44886 + 5 and 44895 mod 16 = 15) and 44895 for aes256-ofb and 3des-cfb8 (no padding). The plaintext ends exactly at the NUL (`tests vector-reembed-*` reproduce the three files byte for byte, so no byte follows it). Ciphertext sizes measured for a 1000-byte file (plaintext 1009) over all 16 combinations by `differential-crypto-*`: 1024 for AES ecb/cbc, 1016 for 3DES ecb/cbc, 1009 for every cfb/ofb.
- **Resolution:** hidden stream = `BE32(ciphertext length) || ciphertext`; plaintext = `BE32(size) || data || ext || 0x00`. On extraction the ciphertext size field is bounded by the carrier's remaining capacity before any allocation; the plaintext is validated strictly (size fits, final byte is NUL, no NUL inside the extension, extension 1-32 printable ASCII bytes starting with `.`) before anything is written. A failure exits 2 with `cannot decrypt the hidden data with <alg>-<mode> (...)` and no output file.
- **Status:** verified-by-vector.

### K6 — Mode mapping (cfb8, full-block ofb, padding)

- **Question:** Which EVP variant is "CFB" and "OFB", and which modes pad?
- **Spec says (page 5):** CFB with 8-bit feedback, OFB with 128 bits; PKCS5 padding for block modes; the OpenSSL table maps CFB to `EVP_aes_128_cfb8` and OFB to `EVP_aes_128_ofb`.
- **Ejemplo README says:** `ladoLSBIdescfb.bmp` uses "cfb8"; aes256 is "ofb".
- **Evidence:** the 3des-cfb vector decrypts only with cfb8 (`cipher_size=44895 size=44886 ext=.png` from `tools/cryptoref.py open ... LSBI 3des cfb`, which calls `openssl enc -d -des-ede3-cfb8`), the aes256-ofb vector with the full-block `-aes-256-ofb`, and the aes128-cbc vector needs PKCS5 (size field 44896). For `1000` random bytes with `-steg LSB1 -a 3des -m ofb -pass pw`, the oracle prints `cipher_size=1009 size=1000 ext=.bin` and with `-a 3des -m ecb` it prints `cipher_size=1016 size=1000 ext=.bin`.
- **Resolution:** cfb = `*_cfb8` for every algorithm, ofb = `*_ofb` (feedback width = the cipher block, so 3DES OFB is 64-bit feedback), ecb and cbc use PKCS5 padding, cfb and ofb never pad. ECB ignores the IV.
- **Status:** verified-by-vector for aes128-cbc, aes256-ofb and 3des-cfb8; flagged-unverified for every ecb combination, for aes-cfb8 and for 3des-ofb (they are checked only against the OpenSSL CLI, not against a cátedra file).

### K7 — 3DES keying

- **Question:** How is the 24-byte 3DES key formed, and is any DES parity adjustment applied?
- **Spec says (page 5):** 3DES = des_ede3, three independent keys.
- **Ejemplo README says:** key = 24 bytes `03db0a157acfe8de523760aa731d8122b25f8d99f3173ec0` used as k1 = `03db0a157acfe8de`, k2 = `523760aa731d8122`, k3 = `b25f8d99f3173ec0`; IV = `b52849f459a4c20d` (8 bytes).
- **Evidence:** `python3 tools/cryptoref.py kdf 3des margarita` prints `key=03db0a157acfe8de523760aa731d8122b25f8d99f3173ec0` and `iv=b52849f459a4c20d`, equal to the README; `./stegobmp -extract -p Ejemplo/ladoLSBIdescfb.bmp -out d -steg LSBI -a 3des -m cfb -pass margarita` prints `stegobmp: extracted 44886 bytes to 'd.png' (decrypted with 3des-cfb)` and the PNG is the reference one; the re-embed is byte-identical.
- **Resolution:** k1 || k2 || k3 = derived bytes 0-23, IV = bytes 24-31, no parity adjustment (OpenSSL ignores the parity bits).
- **Status:** verified-by-vector.

### K8 — Encryption defaults and the no-pass rule

- **Question:** What are the defaults when only some of `-a`, `-m`, `-pass` are given, and what happens with `-a`/`-m` but no `-pass`?
- **Spec says (page 3):** `-a` and `-pass` without `-m` means CBC; `-m` and `-pass` without `-a` means aes128; only `-pass` means aes128 in CBC mode; without `-pass` there is no encryption (stego only).
- **Ejemplo README says:** nothing.
- **Evidence:** hiding the vector PNG with `./stegobmp -embed -in h.png -p Ejemplo/lado.bmp -out d.bmp -steg LSB1 -pass margarita` prints `stegobmp: hid 'h.png' (44886 bytes, extension '.png') in 'd.bmp' using LSB1 with aes128-cbc encryption` and `cmp d.bmp Ejemplo/ladoLSB1aes128cbc.bmp` succeeds. `-m ofb -pass pw1` prints `... using LSB1 with aes128-ofb encryption`, `-a aes256 -pass pw1` prints `... using LSB1 with aes256-cbc encryption`, and each is cmp-identical to the fully explicit form. Extraction with the wrong defaults is a clear error: `./stegobmp -extract -p Ejemplo/ladoLSBIaes256ofb.bmp -out z -steg LSBI -a aes256 -pass margarita` exits 2 with `cannot decrypt the hidden data with aes256-cbc (...): the ciphertext length 44895 is not a multiple of the 16-byte block`, and `-m ofb -pass margarita` exits 2 with `cannot decrypt the hidden data with aes128-ofb (...)`. With `-m ofb` and no `-pass`, stderr carries `stegobmp: note: -a/-m ignored because no -pass was given (no encryption)` and the file is hidden or extracted unencrypted.
- **Resolution:** `cli_parse` fills `aes128` / `cbc` for whichever of `-a` / `-m` is missing when `-pass` is present; `-pass` is the only encryption switch. The note keeps the silent-ignore case visible without changing the exit code.
- **Status:** verified-by-vector (the `-pass`-only embed reproduces the cátedra vector; the other defaults are checked by cmp against their explicit forms).

## Threat model notes (accepted, spec-mandated)

- A fixed all-zero salt, ECB availability and the absence of any MAC are required for byte compatibility with the cátedra's files; they weaken the scheme but are not implementation defects.
- The password travels on the command line (`-pass`), so it is visible in `ps` and shell history. stegobmp never prints the password, key or IV, and it wipes key material and plaintext buffers before freeing them.
- Wrong-password detection relies on PKCS5 padding (ecb/cbc) plus the strict plaintext framing (all modes). The format has no MAC, so a wrong password that passes both checks is astronomically unlikely but not impossible; in that case the output is garbage, never a crash.

## Report input (Q IX)

Implementation difficulties worth reporting:

- `Ejemplo/README.txt` has an erratum for `ladoLSB1aes128cbc.bmp`: it lists the aes256 IV (`212420edc583a686a94d19a3497363a2`) as the aes128 IV and labels a 16-byte key "32 bytes". The vector itself decides: only the split IV `b25f8d99f3173ec0b52849f459a4c20d` recovers the PNG (K3).
- The key/IV derivation is not stated per algorithm in the TP; the single-call `keylen + ivlen` split is what all three vectors obey (K2), which also fixes aes192 by rule (K4).
- "CFB = 8 bits, OFB = 128 bits" needs care with the EVP names: `*_cfb8` and full-block `*_ofb`; 3DES OFB necessarily has 64-bit feedback (K6).
- The padded modes need the ciphertext length before embedding, to check capacity: `(plain / block + 1) * block` for ecb/cbc, `plain` for cfb/ofb; sizes were measured for all 16 combinations against an independent oracle (K5).
