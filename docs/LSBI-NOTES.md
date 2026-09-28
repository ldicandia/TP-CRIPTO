# LSBI notes: resolved ambiguities, paper/TP issues, measured data

Date: 2026-09-28. Input for REP-02 (question I) and REP-03 (question II) of the report.

Sources:

- TP: `Trabajo Practico Implementacion-2026_2.pdf` (page numbers below are the printed page numbers 1-5).
- Paper: Majeed and Sulaiman, "An Improved LSB Image Steganography Technique using Bit-Inverse in 24 bit Colour Image", JATIT 80(2), 2015, `16Vol80No2.pdf` (journal pages 342-348).
- Vectors: `Ejemplo/lado.bmp` (carrier, 640x480, 24 bpp, no row padding), `ladoLSBI.bmp`, `ladoLSBIaes256ofb.bmp`, `ladoLSBIdescfb.bmp`.
- Tools: `tools/lsbi.py` (LSBI reference model and probe), `tools/bmpdiff.py`, `tools/lsbstats.py`. Run them from the repo root on Linux/WSL: `python3 tools/lsbi.py probe Ejemplo/lado.bmp Ejemplo/ladoLSBI.bmp`.

Status vocabulary, used exactly: `verified-by-vector` means a cited probe run shows an alternative reading failing on a cátedra vector. `flagged-unverified` means the vectors cannot decide the choice, so it is a design decision that must be re-checked if a new cátedra file contradicts it.

Model summary (what the reference model implements, and what plan 02-02 must implement in C):

- Pixel block = the file bytes from `bfOffBits` to `bfOffBits + stride*|height|`, indexed `i = 0, 1, 2, ...` in file order (B, G, R, B, G, R, ...).
- Flags: pixel bytes 0..3 hold, in their LSB, the flags of patterns 00, 01, 10, 11 (flag 1 = that pattern is inverted). They are written with plain LSB1 and are never inverted.
- Message bits (MSB first inside each byte) start at pixel byte 4. Every byte with `i % 3 == 2` (red) is skipped.
- The pattern of a byte is `(b >> 1) & 3`, so bit 2 is the high digit. Bits 1 and 2 are never modified.
- For each pattern, `changed` = message-carrying bytes whose cover LSB differs from the message bit, `unchanged` = the rest. The pattern is inverted iff `changed > unchanged`. Then each message bit is written as `bit XOR flag[pattern]`.
- Capacity in stream bytes = `floor((pixel_len - floor(pixel_len/3) - 3) / 8)`; for `lado.bmp` this is 76799.

## Resolved ambiguities

### A1 — Flag storage location and bit order

- **Question:** Where are the four pattern flags stored, in which order, and how (plain or inverted)?
- **Paper says (p. 344, step 6; p. 346 pseudocode):** "Store the status of the patterns that inverse its pixel in specific location." The location is never given.
- **TP says (page 5, top; page 4 for byte order):** the flags are saved "en los primeros 4 bytes de la imagen consecutivos con LSB1 normal (no se invierten, y se usan los 3 canales R, G y B)". The example "1010" is the flags for patterns 00, 01, 10, 11 in that order.
- **Evidence:** `python3 tools/bmpdiff.py --limit 4 Ejemplo/lado.bmp Ejemplo/ladoLSBIaes256ofb.bmp` prints `diff offset=56 region=PIX row=0 col=2 chan=R old=0xff new=0xfe xor=0x01`. Offset 56 is pixel byte 2, a red byte, and message bits never go there, so it is a flag byte. The rejected reading (flag of pattern p stored in byte 3-p): `python3 tools/lsbi.py probe --flag-order reversed Ejemplo/lado.bmp Ejemplo/ladoLSBIaes256ofb.bmp` prints `size=4294922424` and `framing=invalid ext=-` and `reembed_identical=no`. The default reading prints `flags=0001` and `reembed_identical=yes` on the same vector, and `flags=1000` with `reembed_identical=yes` for `ladoLSBIdescfb.bmp`, so the order is exercised by vectors whose flags are not all 1.
- **Resolution:** pixel byte k (k = 0..3) holds the flag of pattern `k` (00, 01, 10, 11), written as `(b & 0xFE) | flag`, all three channels used, never inverted.
- **Status:** verified-by-vector.

### A2 — Which channels carry message bits; where the red index starts counting

- **Question:** Are red bytes skipped for the message, and is the red position counted from the start of the pixel block or from byte 4?
- **Paper says (abstract p. 342; p. 345 last paragraph; p. 345-346 pseudocode "For each colour from green and blue"):** only green and blue carry data; red "will act as noise data".
- **TP says (page 4):** bytes are used in physical file order, "el primer byte es azul, el siguiente es verde, el tercero rojo". The TP never says explicitly that red is skipped for the message (it only says the flags use "los 3 canales R, G y B", page 5).
- **Evidence:** `python3 tools/bmpdiff.py Ejemplo/lado.bmp Ejemplo/ladoLSBI.bmp` prints `channels B=85551 G=85301 R=0 PAD=0 HDR=0 TRAIL=0 OTHER=0`, so no red byte changes (the flags of that vector are all 1 and byte 2 is already 1). Rejected readings: `python3 tools/lsbi.py probe --use-red Ejemplo/lado.bmp Ejemplo/ladoLSBI.bmp` prints `size=658` and `reembed_identical=no`; `python3 tools/lsbi.py probe --red-relative Ejemplo/lado.bmp Ejemplo/ladoLSBI.bmp` prints `size=109078`, `framing=invalid ext=-` and `reembed_identical=no`. The accepted reading prints `size=44886` and `reembed_identical=yes`.
- **Resolution:** message bits skip every byte whose pixel-block index `i` satisfies `i % 3 == 2`, counted from the start of the pixel block (so byte 2, a flag byte, and byte 5, 8, ... are red).
- **Status:** verified-by-vector.

### A3 — Where message bits start; payload framing; bit order

- **Question:** Where does the message start, what is the framing, and which bit of each byte goes first?
- **Paper says (p. 344, Section 4 algorithm):** the i-th message bit goes to an index `j_i`; nothing about framing or byte order.
- **TP says (pages 3-5):** the stream is `size(4 bytes, big endian) || data || extension || 0x00`; with encryption it is `cipher size || cipher(size || data || extension)`. The flags are stored first (page 5) and add 4 bytes.
- **Evidence:** `python3 tools/lsbi.py probe Ejemplo/lado.bmp Ejemplo/ladoLSBI.bmp` prints `size=44886` and `framing=plain ext=.png`, and `python3 tools/lsbi.py extract-raw --body-only Ejemplo/ladoLSBI.bmp /tmp/p.png` writes 44886 bytes with sha256 `b93be15382f35f099ca286241dd7bb6e681d5bce8d315ac0b6240f0b516f549d`, the same PNG that the LSB1 and LSB4 vectors hold. Rejected reading (LSB-first inside each byte): `python3 tools/lsbi.py probe --bit-order lsb Ejemplo/lado.bmp Ejemplo/ladoLSBI.bmp` prints `size=62826` and `framing=cipher ext=-`. Note that `reembed_identical=yes` is not a discriminator for the bit order (a wrong decode re-embeds losslessly), the decoded size and the PNG hash are. For the encrypted vectors `size=44895` = 4 + 44886 + 5, as expected for a stream cipher mode (OFB, CFB8) with no padding.
- **Resolution:** the first message bit goes to pixel byte 4 (the first non-flag byte); bits go MSB first; the framing is the TP's.
- **Status:** verified-by-vector.

### A4 — How the two pattern bits are read

- **Question:** Is the pattern `(bit2, bit1)` (bit 2 as the high digit) or `(bit1, bit2)`?
- **Paper says (p. 344 Section 5 step 1, p. 345 example):** the pattern is made of "the 2nd last and 3rd last bit"; no digit order is stated. The worked example (p. 345) gives pattern `10` to `10001100` (bit 2 = 1, bit 1 = 0) and pattern `01` to `10101011` (bit 2 = 0, bit 1 = 1), which is consistent with bit 2 being the high digit.
- **TP says (page 5):** flags are listed for patterns 00, 01, 10, 11 in that order; it does not define the pattern digits.
- **Evidence:** `python3 tools/lsbi.py probe --pattern-bits 12 Ejemplo/lado.bmp Ejemplo/ladoLSBI.bmp` still prints `reembed_identical=yes`, and so does the same command on `ladoLSBIaes256ofb.bmp` and `ladoLSBIdescfb.bmp`. Reason: patterns 01 and 10 have equal flags in all three vectors (`flags=1111`, `flags=0001`, `flags=1000`), so swapping the two digits gives the same bytes.
- **Resolution:** `pattern = (b >> 1) & 3` (bit 2 is the high digit), following the paper's worked example. If a future cátedra file has different flags for 01 and 10, re-check this first.
- **Status:** flagged-unverified.

### A5 — Over which bytes changed/unchanged are counted

- **Question:** Are the counts taken over the message-carrying bytes only, or over the whole span (red bytes included as "unchanged")?
- **Paper says (p. 344 steps 4-5; p. 345 step 4):** compare each pattern between the cover and the stego image (after standard LSB) and invert if more pixels changed than not.
- **TP says:** nothing.
- **Evidence:** `python3 tools/lsbi.py probe --count-red Ejemplo/lado.bmp Ejemplo/ladoLSBI.bmp` prints `recomputed_flags=0000 match=no` and `reembed_identical=no`; the same holds for `ladoLSBIaes256ofb.bmp` and `ladoLSBIdescfb.bmp`. The accepted reading prints e.g. `counts pattern=00 changed=32367 unchanged=32028 invert=1` and `recomputed_flags=1111 match=yes`.
- **Resolution:** counts are over the message-carrying bytes only (G and B bytes that receive a message bit), using the cover LSB against the message bit, before any inversion. Flag bytes and untouched bytes are not counted.
- **Status:** verified-by-vector.

### A6 — Tie rule

- **Question:** What happens when `changed == unchanged`?
- **Paper says (p. 344 step 5; p. 345 step 4c):** invert "if the number of pixels that have changed ... is greater than the number of pixels that are not changed". Ties are not discussed; the literal reading is strict `>`.
- **TP says:** nothing.
- **Evidence:** no vector has a tie (see the four `counts` lines of every probe run, e.g. `counts pattern=11 changed=88172 unchanged=71581 invert=1`). `python3 tools/lsbi.py probe --tie invert Ejemplo/lado.bmp Ejemplo/ladoLSBI.bmp` still prints `reembed_identical=yes`, and so does the same command on the two encrypted vectors.
- **Resolution:** invert iff `changed > unchanged` (a tie leaves the pattern non-inverted), following the literal paper text. When a pattern has no message-carrying bytes the flag is 0.
- **Status:** flagged-unverified.

### A7 — Inversion scope

- **Question:** What exactly is inverted, and what is left untouched?
- **Paper says (p. 344-345):** "Inverse the LSB bits" of the pixels (bytes) of the inverted patterns.
- **TP says:** nothing beyond the flags.
- **Evidence:** `python3 tools/bmpdiff.py Ejemplo/lado.bmp Ejemplo/ladoLSBI.bmp` prints `summary changed_bytes=170852 changed_bits=170852 mask=0x01 first=78 last=538794` and `bitpos b0=170852 b1=0 b2=0 b3=0 b4=0 b5=0 b6=0 b7=0`: only bit 0 ever changes (an inversion of the whole byte would show a wider mask), `channels ... R=0` shows red untouched, and `HDR=0 TRAIL=0` show that the header and trailing bytes are untouched. `python3 tools/bmpdiff.py Ejemplo/lado.bmp Ejemplo/ladoLSBIaes256ofb.bmp` prints `channels B=89677 G=89654 R=1 ...`: the one red change is flag byte 2 (offset 56).
- **Resolution:** only the LSB of message-carrying bytes is XORed with the pattern's flag. Bits 1..7, red bytes (other than flag byte 2), the header, the trailing bytes and every byte after the message stay untouched.
- **Status:** verified-by-vector.

### A8 — Capacity formula

- **Question:** What is the maximum payload, and what does the error message report?
- **Paper says:** nothing about capacity (p. 343 only says capacity is a goal).
- **TP says (page 5):** "se le sumarán 4 bits (necesitando así 4 bytes más para ocultarlos)" and, in a box, that an error stating the maximum capacity must be shown when the payload does not fit.
- **Evidence:** `python3 tools/lsbi.py probe Ejemplo/lado.bmp Ejemplo/ladoLSBI.bmp` prints `capacity=76799`. The formula is `floor((921600 - 307200 - 3) / 8)`: 921600 pixel bytes, minus 307200 red bytes, minus the 3 non-red flag bytes (0, 1 and 3), divided by 8 bits. `make test-tools` case `lsbi-capacity` embeds 76799 random bytes and refuses 76800. The vectors only prove that 44895 bytes fit; they say nothing about the cátedra's own limit or message text.
- **Resolution:** the maximum stream length (`size || data || ext`, or `cipher size || cipher`) is 76799 bytes for `lado.bmp` (LSB1: 115200, LSB4: 460800 by the same counting). The wording of the error message is our design choice.
- **Status:** flagged-unverified.

### A9 — Row padding and the red index

- **Question:** With row padding, does the `i % 3` red index run over the flat pixel block including padding bytes?
- **Paper says:** nothing (images are treated as flat arrays).
- **TP says (page 5):** "Para el esteganografiado usen todo el bloque completo de los pixeles + bytes de padding." It does not say how the red skip interacts with padding.
- **Evidence:** `lado.bmp` is 640 px wide, so its stride is 1920 with no padding (`python3 tools/bmpdiff.py Ejemplo/lado.bmp Ejemplo/ladoLSBI.bmp` prints `PAD=0` and `stride=1920`). No vector exercises padding, so the flat model cannot be checked.
- **Resolution:** the model uses the flat pixel-block index (`i % 3 == 2` skipped), padding bytes included, per the TP sentence. Re-check in Phase 5 if the cátedra's LSBI steganalysis file has padded rows.
- **Status:** flagged-unverified.

### A10 — Flag semantics

- **Question:** Does a flag of 1 mean "this pattern is inverted", and are the flags themselves subject to inversion?
- **Paper says (p. 344 step 6):** stores "the status of the patterns that inverse its pixel". The polarity is implied only.
- **TP says (page 5):** "1 indica que '00' tuvo cambio, 0 indica que '01' no tuvo cambios ..."; the flag bits are stored "LSB1 normal (no se invierten ...)".
- **Evidence:** `python3 tools/lsbi.py probe --flag-zero-inverts Ejemplo/lado.bmp Ejemplo/ladoLSBI.bmp` prints `size=4294922409`, `framing=invalid ext=-` and `reembed_identical=no` (and the same failure on the other two vectors), while the default prints `recomputed_flags=1111 match=yes`. The flag bytes are written plain: in `ladoLSBIaes256ofb.bmp` the bytes 54..56 hold LSB 0 (`diff offset=54 ... new=0xfe`), exactly the value of flags `0001`.
- **Resolution:** flag 1 = the pattern is inverted; flag bits are stored as-is and are not passed through the inversion.
- **Status:** verified-by-vector.

## Paper and TP issues (REP-02 input)

Each item was confirmed by re-reading the PDF page cited.

Paper (Majeed and Sulaiman, JATIT 80(2)):

1. p. 344, Section 5 step 1: the list of patterns reads "either 00, 10, 10, or 11". `10` appears twice and `01` is missing; it should be 00, 01, 10, 11.
2. p. 345, Section 5 example (step 2 table): the cover value D is printed as the 7-bit "1010110", while step 1 of the same example lists it as the 8-bit "10101101" (and the later "Cover Image" line uses 10101101).
3. p. 343, Fig. 1: the axes are labelled "BLUE (0,1,0)" and "GREEN (0,0,1)"; in RGB coordinates green is (0,1,0) and blue is (0,0,1). Red (1,0,0) is right.
4. p. 345 (last paragraph before Section 6): "According to a research that was conducted by Hecht [8], 65% of all cones of human eyes are sensitive to red, 33% ... green, and only near 2% ... blue". Reference [8] on p. 348 is Rawat and Bhandari, a steganography paper, not Hecht. The claim also mixes cone population with sensitivity.
5. p. 346, "Original/Secret Message": "The following text includes 226 characters or 2881 bits". The quoted text is 220 characters (1760 bits, counting spaces, without quotation marks); 226 characters would be 1808 bits, so neither figure is consistent.
6. p. 347, PSNR definition: "cover image C of size M x M and the stego-image S of size N x N", but the MSE formula sums over one M x N grid and subtracts pixel by pixel, which requires both images to have the same size.
7. p. 342, abstract: "the last LSBs of both green and blue colour planes ... will be replaced by the first and the second most significant bits (MSB) of the secret image". The method (Sections 5-6) hides bits of a secret message in the LSBs; there is no "MSB of the secret image" step.
8. pp. 344-346, Sections 5 and 6: the word "pixel" is used for a single colour byte (e.g. p. 345, "Three pixels that have '10' pattern (A, B, D)": A, B, C, D are 8-bit values, not pixels).
9. p. 344 step 6 and p. 346 pseudocode: the pattern map is stored "in specific location" / "as a map in specific location"; the location, size and format are never defined, and the capacity cost of the map is not counted.
10. p. 344-345, Section 5 and Section 6: no tie rule (equal changed and unchanged counts) and no digit order for the 2-bit pattern is stated, and the pseudocode says "in any pattern of pic was more than pixels that not changed in alternative pattern in the stego", which is ambiguous.
11. pp. 343-344 vs pp. 344-346: Section 2 (standard LSB technique) and Section 4 (LSB) repeat each other, and Section 5 (step list and example) and Section 6 (pseudocode) describe the same procedure twice with different level of detail.
12. p. 346 vs p. 347: p. 346 says "we use three true RGB colour images (Lena.jpg, Baboon.jpg, Peppers.jpg)", but Fig. 2 (p. 346) shows six cover images and Table 1 (p. 347) reports six PSNR values (adds tree, Plane, Tifanny).
13. Typos: p. 345 "the lest significant bit" (Section 6 pseudocode), p. 345 "extract the massage bits", p. 346 "Babbon.jpg" (Fig. 2 caption) versus "Baboon.jpg" (text and Table 1, p. 347), p. 348 "REFRENCES".

TP (Trabajo Práctico 2026):

14. page 2, section 5.1: the `-steg` option is described as "LSB de 1bit, LSB de 4 bits, LSB Enhanced", while page 2 (examples), page 3 (5.2) and page 4 name the same method "LSB Improved". The `-steg` value is `LSBI` in every case.
15. page 2, "Ejemplo 2": "Esteganografiar el archivo de imagen 'mensaje1.txt'" calls a `.txt` file an image.
16. page 4: the method is only described as an "LSB Improved" variant "propuesta por Majeed y Sulaiman"; the TP never states that the red channel is skipped for message bits (the flags use "los 3 canales R, G y B", page 5), so the paper is needed to know it (see A2).
17. page 5, section 5.4: "usen todo el bloque completo de los pixeles + bytes de padding" does not say how the LSBI red skip counts padding bytes (see A9).
18. page 3 and page 4: the sub-headings of section 5.3 restart their numbering as "1. LSB1", "2. LSB4", "3. LSB Improved" inside "5.3.", which reads like top-level sections 1-3.

Cátedra example file (`Ejemplo/README.txt`, no page numbers):

19. For `ladoLSB1aes128cbc.bmp` it says "Key derivada (32 bytes):03db0a157acfe8de523760aa731d8122", but that hex string is 32 characters, that is 16 bytes (correct for AES-128); the "(32 bytes)" label is wrong.

## Measured data (REP-03 seed)

Carrier `Ejemplo/lado.bmp` (640x480, 24 bpp, 921600 colour bytes). Values come from `python3 tools/bmpdiff.py Ejemplo/lado.bmp Ejemplo/<vector>` (all pixel-basis, samples=921600).

| Vector | Changed bytes | Changed bits | Bit mask | First..last offset | B / G / R changed | MSE | PSNR (dB) |
|---|---|---|---|---|---|---|---|
| ladoLSB1.bmp | 190182 | 190182 | 0x01 | 54..359213 | 63231 / 63610 / 63341 | 0.206361 | 54.9845 |
| ladoLSB4.bmp | 85370 | 205965 | 0x0f | 54..89843 | 28437 / 28490 / 28443 | 8.763059 | 38.7042 |
| ladoLSBI.bmp | 170852 | 170852 | 0x01 | 78..538794 | 85551 / 85301 / 0 | 0.185386 | 55.4500 |
| ladoLSB1aes128cbc.bmp | 179687 | 179687 | 0x01 | 54..359251 | 59905 / 59915 / 59867 | 0.194973 | 55.2311 |
| ladoLSBIaes256ofb.bmp | 179332 | 179332 | 0x01 | 54..538845 | 89677 / 89654 / 1 | 0.194588 | 55.2397 |
| ladoLSBIdescfb.bmp | 179198 | 179198 | 0x01 | 55..538837 | 89634 / 89563 / 1 | 0.194442 | 55.2429 |

LSB4 changed bits per position (`bitpos`): b0=50123, b1=51465, b2=51853, b3=52524.

Capacity of `lado.bmp` (stream bytes, `size || data || ext`): LSB1 115200, LSB4 460800, LSBI 76799.

Per-channel LSB statistics over the whole pixel block (`python3 tools/lsbstats.py Ejemplo/lado.bmp Ejemplo/ladoLSB1.bmp Ejemplo/ladoLSB4.bmp Ejemplo/ladoLSBI.bmp`, 307200 bytes per channel):

| Channel | lsb1_count lado / LSB1 / LSB4 / LSBI | chi2_pov lado / LSB1 / LSB4 / LSBI |
|---|---|---|
| B | 168177 / 140750 / 157798 / 172824 | 8475.17 / 2125.38 / 5232.30 / 3520.98 |
| G | 167170 / 140408 / 156923 / 172269 | 7592.63 / 2144.94 / 4372.81 / 3345.95 |
| R | 168582 / 140603 / 158127 / 168582 | 8606.07 / 2028.76 / 5226.22 / 8606.07 |

Reading: LSBI leaves the red channel statistically identical to the cover (equal `lsb1_count` and `chi2_pov`), while LSB1 and LSB4 disturb all three channels. The pairs-of-values chi-square is the sum over the 128 value pairs (2k, 2k+1) of `(h[2k] - e)^2 / e` with `e = (h[2k] + h[2k+1]) / 2`; it is computed over the whole block here, and over the first 359160 bytes for the LSB1 payload span in the test `stats-prefix-chi2-LSB1`. It drops when the pair counts are equalised by embedding, so a lower value than the cover on a channel indicates embedding there.
