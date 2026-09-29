#!/usr/bin/env bash
# stegobmp test harness. Usage: bash tests/run_tests.sh [filter]
set -u
cd "$(dirname "$0")/.." || exit 2

BIN=./stegobmp
T=tests/out
rm -rf "$T"
mkdir -p "$T"
FILTER=${1:-}

PNG_SHA256=b93be15382f35f099ca286241dd7bb6e681d5bce8d315ac0b6240f0b516f549d
PNG_SIZE=44886

ran=0
passed=0
failed=0

run_case() {
    local name=$1 func=$2
    if [ -n "$FILTER" ] && [[ "$name" != *"$FILTER"* ]]; then
        return
    fi
    ran=$((ran + 1))
    export CASE_DIR="$T/$name"
    mkdir -p "$CASE_DIR"
    if ( "$func" ) >"$T/$name.log" 2>&1; then
        if grep -rqsE 'Sanitizer|runtime error:' "$T/$name.log" "$CASE_DIR"; then
            echo "FAIL $name: sanitizer report"
            failed=$((failed + 1))
            return
        fi
        echo "PASS $name"
        passed=$((passed + 1))
    else
        echo "FAIL $name: $(tail -n 1 "$T/$name.log")"
        failed=$((failed + 1))
    fi
}

fail_msg() {
    echo "$*"
    return 1
}

check_png() {
    python3 - "$1" <<'PY'
import sys, struct, zlib
d = open(sys.argv[1], 'rb').read()
def bad(m):
    print(m); sys.exit(1)
if d[:8] != b'\x89PNG\r\n\x1a\n':
    bad('bad PNG signature')
pos, first, last_end, idat = 8, True, 0, b''
name = b''
while pos < len(d):
    if pos + 8 > len(d):
        bad('truncated chunk header')
    ln, name = struct.unpack('>I4s', d[pos:pos+8])
    body = d[pos+8:pos+8+ln]
    crc = d[pos+8+ln:pos+12+ln]
    if len(body) != ln or len(crc) != 4:
        bad('truncated chunk')
    if zlib.crc32(name + body) & 0xffffffff != struct.unpack('>I', crc)[0]:
        bad('bad CRC in ' + name.decode('latin1'))
    if first and name != b'IHDR':
        bad('IHDR not first')
    first = False
    if name == b'IDAT':
        idat += body
    pos += 12 + ln
if name != b'IEND' or pos != len(d):
    bad('IEND not last at EOF')
try:
    zlib.decompress(idat)
except Exception as e:
    bad('IDAT does not inflate: %s' % e)
PY
}

diff_region() {
    python3 - "$1" "$2" <<'PY'
import sys
a = open(sys.argv[1], 'rb').read()
b = open(sys.argv[2], 'rb').read()
maxoff, mask = -1, 0
if len(a) != len(b):
    print('maxoff=-2 mask=0x0'); sys.exit(0)
for i, (x, y) in enumerate(zip(a, b)):
    if x != y:
        maxoff = i
        mask |= x ^ y
print('maxoff=%d mask=0x%x' % (maxoff, mask))
PY
}

no_tmp() {
    [ -z "$(find "$T" -name '.stegobmp-tmp-*')" ] || fail_msg "leftover temp file"
}

case_vector_extract_LSB1() {
    mkdir -p "$T/vx1"
    $BIN -extract -p Ejemplo/ladoLSB1.bmp -out "$T/vx1/out1" -steg LSB1 || fail_msg "extract exit $?" || return 1
    [ -f "$T/vx1/out1.png" ] || fail_msg "out1.png missing" || return 1
    [ "$(stat -c %s "$T/vx1/out1.png")" = "$PNG_SIZE" ] || fail_msg "wrong size" || return 1
    [ "$(sha256sum "$T/vx1/out1.png" | cut -d' ' -f1)" = "$PNG_SHA256" ] || fail_msg "wrong sha256" || return 1
    check_png "$T/vx1/out1.png" || return 1
    no_tmp
}

case_vector_reembed_LSB1() {
    mkdir -p "$T/vr1"
    $BIN -extract -p Ejemplo/ladoLSB1.bmp -out "$T/vr1/h" -steg LSB1 || fail_msg "extract failed" || return 1
    $BIN -embed -in "$T/vr1/h.png" -p Ejemplo/lado.bmp -out "$T/vr1/s.bmp" -steg LSB1 || fail_msg "embed failed" || return 1
    cmp "$T/vr1/s.bmp" Ejemplo/ladoLSB1.bmp || fail_msg "re-embed differs from ladoLSB1.bmp" || return 1
    cmp -n 54 "$T/vr1/s.bmp" Ejemplo/lado.bmp || fail_msg "header changed"
}

case_vector_diff_region_LSB1() {
    mkdir -p "$T/vd1"
    $BIN -extract -p Ejemplo/ladoLSB1.bmp -out "$T/vd1/h" -steg LSB1 || return 1
    $BIN -embed -in "$T/vd1/h.png" -p Ejemplo/lado.bmp -out "$T/vd1/s.bmp" -steg LSB1 || return 1
    local r
    r=$(diff_region Ejemplo/lado.bmp "$T/vd1/s.bmp")
    local mo=${r#maxoff=}
    mo=${mo%% *}
    [ "$mo" -le 359213 ] && [[ "$r" == *"mask=0x1" ]] || fail_msg "unexpected diff region: $r"
}

case_cap_over_LSB1() {
    mkdir -p "$T/cap1"
    head -c 115192 /dev/zero > "$T/cap1/over.bin"
    $BIN -embed -in "$T/cap1/over.bin" -p Ejemplo/lado.bmp -out "$T/cap1/over.bmp" -steg LSB1 2>"$T/cap1/err"
    local rc=$?
    [ "$rc" = 2 ] || fail_msg "expected exit 2, got $rc" || return 1
    grep -qF "maximum capacity of 'Ejemplo/lado.bmp' with LSB1 is 115200 bytes" "$T/cap1/err" || fail_msg "capacity message missing" || return 1
    [ ! -e "$T/cap1/over.bmp" ] || fail_msg "output file created" || return 1
    no_tmp
}

case_vector_extract_LSB4() {
    mkdir -p "$T/vx4"
    $BIN -extract -p Ejemplo/ladoLSB4.bmp -out "$T/vx4/out4" -steg LSB4 || fail_msg "extract exit $?" || return 1
    [ "$(stat -c %s "$T/vx4/out4.png")" = "$PNG_SIZE" ] || fail_msg "wrong size" || return 1
    [ "$(sha256sum "$T/vx4/out4.png" | cut -d' ' -f1)" = "$PNG_SHA256" ] || fail_msg "wrong sha256" || return 1
    check_png "$T/vx4/out4.png" || return 1
    no_tmp
}

case_vector_reembed_LSB4() {
    mkdir -p "$T/vr4"
    $BIN -extract -p Ejemplo/ladoLSB4.bmp -out "$T/vr4/h" -steg LSB4 || fail_msg "extract failed" || return 1
    $BIN -embed -in "$T/vr4/h.png" -p Ejemplo/lado.bmp -out "$T/vr4/s.bmp" -steg LSB4 || fail_msg "embed failed" || return 1
    cmp "$T/vr4/s.bmp" Ejemplo/ladoLSB4.bmp || fail_msg "re-embed differs from ladoLSB4.bmp" || return 1
    cmp -n 54 "$T/vr4/s.bmp" Ejemplo/lado.bmp || fail_msg "header changed"
}

case_vector_diff_region_LSB4() {
    mkdir -p "$T/vd4"
    $BIN -extract -p Ejemplo/ladoLSB4.bmp -out "$T/vd4/h" -steg LSB4 || return 1
    $BIN -embed -in "$T/vd4/h.png" -p Ejemplo/lado.bmp -out "$T/vd4/s.bmp" -steg LSB4 || return 1
    local r mo mk
    r=$(diff_region Ejemplo/lado.bmp "$T/vd4/s.bmp")
    mo=${r#maxoff=}
    mo=${mo%% *}
    mk=${r##*mask=}
    [ "$mo" -le 89843 ] && [ $((mk & ~0x0F)) -eq 0 ] || fail_msg "unexpected diff region: $r"
}

case_vector_extract_LSBI() {
    mkdir -p "$T/vxI"
    $BIN -extract -p Ejemplo/ladoLSBI.bmp -out "$T/vxI/outI" -steg LSBI || fail_msg "extract exit $?" || return 1
    [ -f "$T/vxI/outI.png" ] || fail_msg "outI.png missing" || return 1
    [ "$(stat -c %s "$T/vxI/outI.png")" = "$PNG_SIZE" ] || fail_msg "wrong size" || return 1
    [ "$(sha256sum "$T/vxI/outI.png" | cut -d' ' -f1)" = "$PNG_SHA256" ] || fail_msg "wrong sha256" || return 1
    check_png "$T/vxI/outI.png" || return 1
    no_tmp
}

case_vector_reembed_LSBI() {
    mkdir -p "$T/vrI"
    $BIN -extract -p Ejemplo/ladoLSBI.bmp -out "$T/vrI/h" -steg LSBI || fail_msg "extract failed" || return 1
    $BIN -embed -in "$T/vrI/h.png" -p Ejemplo/lado.bmp -out "$T/vrI/s.bmp" -steg LSBI || fail_msg "embed failed" || return 1
    cmp "$T/vrI/s.bmp" Ejemplo/ladoLSBI.bmp || fail_msg "re-embed differs from ladoLSBI.bmp" || return 1
    cmp -n 54 "$T/vrI/s.bmp" Ejemplo/lado.bmp || fail_msg "header changed"
}

case_vector_diff_region_LSBI() {
    mkdir -p "$T/vdI"
    $BIN -extract -p Ejemplo/ladoLSBI.bmp -out "$T/vdI/h" -steg LSBI || return 1
    $BIN -embed -in "$T/vdI/h.png" -p Ejemplo/lado.bmp -out "$T/vdI/s.bmp" -steg LSBI || return 1
    local r
    r=$(python3 tools/bmpdiff.py Ejemplo/lado.bmp "$T/vdI/s.bmp") || fail_msg "bmpdiff failed" || return 1
    grep -xF 'summary changed_bytes=170852 changed_bits=170852 mask=0x01 first=78 last=538794' <<<"$r" >/dev/null || fail_msg "summary line differs: $r" || return 1
    grep -xF 'channels B=85551 G=85301 R=0 PAD=0 HDR=0 TRAIL=0 OTHER=0' <<<"$r" >/dev/null || fail_msg "channels line differs: $r"
}

make_bmp() {
    python3 - "$1" "$2" "$3" "$4" "${5:-}" <<'PY'
import sys, struct, random
path, w, h, trailing = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4])
fill = sys.argv[5]
stride = (w * 3 + 3) & ~3
if fill:
    pix = bytes([int(fill, 16)]) * (stride * h)
else:
    rnd = random.Random(1234)
    pix = bytes(rnd.randrange(256) for _ in range(stride * h))
hdr = b'BM' + struct.pack('<IHHI', 54 + stride * h + trailing, 0, 0, 54)
hdr += struct.pack('<IiiHHIIiiII', 40, w, h, 1, 24, 0, stride * h, 2835, 2835, 0, 0)
open(path, 'wb').write(hdr + pix + b'\xab' * trailing)
PY
}

roundtrip() {
    local method=$1 infile=$2 carrier=$3 dir=$4 ext=$5
    shift 5
    $BIN -embed -in "$infile" -p "$carrier" -out "$dir/s.bmp" -steg "$method" "$@" || fail_msg "embed failed" || return 1
    $BIN -extract -p "$dir/s.bmp" -out "$dir/o" -steg "$method" "$@" || fail_msg "extract failed" || return 1
    [ -f "$dir/o$ext" ] || fail_msg "missing $dir/o$ext" || return 1
    cmp "$infile" "$dir/o$ext" || fail_msg "content differs" || return 1
    cmp -n 54 "$dir/s.bmp" "$carrier" || fail_msg "header changed"
}

case_roundtrip() {
    local method=$1 kind=$2 d="$T/rt-$2-$1" f ext
    mkdir -p "$d"
    case $kind in
    text) f="$d/hello.txt"; ext=.txt
        printf 'Criptografía y Seguridad — ñandú\nlínea 2\n' > "$f" ;;
    binary) f="$d/data.bin"; ext=.bin; head -c 20000 /dev/urandom > "$f" ;;
    multidot) f="$d/archive.tar.gz"; ext=.gz; head -c 3000 /dev/urandom > "$f" ;;
    noext) f="$d/README"; ext=.; echo "no extension here" > "$f" ;;
    spaces) d="$d/with space"; mkdir -p "$d"; f="$d/my secret file.txt"; ext=.txt
        echo "spaces" > "$f" ;;
    esac
    roundtrip "$method" "$f" Ejemplo/lado.bmp "$d" "$ext"
}

case_empty() {
    local method=$1 d="$T/empty-$1"
    mkdir -p "$d"
    : > "$d/empty.txt"
    roundtrip "$method" "$d/empty.txt" Ejemplo/lado.bmp "$d" .txt || return 1
    [ "$(stat -c %s "$d/o.txt")" = 0 ] || fail_msg "not empty"
}

case_padded_capacity() {
    local method=$1 d="$T/padcap-$1" n
    mkdir -p "$d"
    make_bmp "$d/c.bmp" 33 17 16
    case $method in LSB1) n=203 ;; LSB4) n=841 ;; LSBI) n=132 ;; esac
    head -c "$n" /dev/urandom > "$d/f.bin"
    roundtrip "$method" "$d/f.bin" "$d/c.bmp" "$d" .bin || return 1
    [ "$(stat -c %s "$d/s.bmp")" = "$(stat -c %s "$d/c.bmp")" ] || fail_msg "size changed" || return 1
    cmp <(tail -c 16 "$d/s.bmp") <(tail -c 16 "$d/c.bmp") || fail_msg "trailing bytes changed"
}

case_out_equals_carrier() {
    local d="$T/same"
    mkdir -p "$d"
    cp Ejemplo/lado.bmp "$d/c.bmp"
    $BIN -extract -p Ejemplo/ladoLSB1.bmp -out "$d/h" -steg LSB1 || return 1
    $BIN -embed -in "$d/h.png" -p "$d/c.bmp" -out "$d/c.bmp" -steg LSB1 || fail_msg "embed failed" || return 1
    cmp "$d/c.bmp" Ejemplo/ladoLSB1.bmp || fail_msg "differs from reference"
}

case_parallel_embed() {
    local d="$T/par" pids=() p
    mkdir -p "$d"
    $BIN -extract -p Ejemplo/ladoLSB1.bmp -out "$d/h" -steg LSB1 || return 1
    for _ in 1 2 3 4; do
        $BIN -embed -in "$d/h.png" -p Ejemplo/lado.bmp -out "$d/stego.bmp" -steg LSB1 >/dev/null 2>&1 &
        pids+=($!)
    done
    for p in "${pids[@]}"; do
        wait "$p" || fail_msg "a parallel embed failed" || return 1
    done
    cmp "$d/stego.bmp" Ejemplo/ladoLSB1.bmp || fail_msg "differs from reference" || return 1
    no_tmp
}

USAGE1='  stegobmp -embed -in <file> -p <bitmapfile> -out <bitmapfile> -steg <LSB1 | LSB4 | LSBI> [-a <aes128 | aes192 | aes256 | 3des>] [-m <ecb | cfb | ofb | cbc>] [-pass <password>]'
USAGE2='  stegobmp -extract -p <bitmapfile> -out <file> -steg <LSB1 | LSB4 | LSBI> [-a <aes128 | aes192 | aes256 | 3des>] [-m <ecb | cfb | ofb | cbc>] [-pass <password>]'
EF_N=0

# expect_fail CODE PATTERN OUTGLOB -- ARGS...   (@D@ in OUTGLOB/ARGS -> $CASE_DIR)
expect_fail() {
    local code=$1 pattern=$2 outglob=${3//@D@/$CASE_DIR} a
    shift 4
    local args=()
    for a in "$@"; do args+=("${a//@D@/$CASE_DIR}"); done
    EF_N=$((EF_N + 1))
    local out="$CASE_DIR/ef$EF_N.out" errf="$CASE_DIR/ef$EF_N.err" rc
    "$BIN" "${args[@]}" >"$out" 2>"$errf"
    rc=$?
    [ "$rc" = "$code" ] || fail_msg "expected exit $code, got $rc" || return 1
    head -n 1 "$errf" | grep -q '^stegobmp: error: ' || fail_msg "first stderr line lacks 'stegobmp: error: '" || return 1
    grep -qF -- "$pattern" "$errf" || fail_msg "stderr lacks '$pattern'" || return 1
    grep -qxF -- "$USAGE1" "$errf" && grep -qxF -- "$USAGE2" "$errf" || fail_msg "usage lines missing" || return 1
    if [ -n "$outglob" ] && compgen -G "$outglob" >/dev/null; then fail_msg "output file created: $outglob" || return 1; fi
    no_tmp || return 1
    if grep -qE 'Sanitizer|runtime error:' "$out" "$errf"; then fail_msg "sanitizer report" || return 1; fi
}

ef_runner() { expect_fail "${EF[@]}"; }
# ef NAME CODE PATTERN OUTGLOB -- ARGS...
ef() {
    local name=$1
    shift
    EF=("$@")
    run_case "$name" ef_runner
}

vector_png() {
    $BIN -extract -p Ejemplo/ladoLSB1.bmp -out "$CASE_DIR/vec" -steg LSB1 >/dev/null || return 1
}

# patch_bytes FILE OFFSET HEX...
patch_bytes() {
    local f=$1 off=$2 s='' h
    shift 2
    for h in "$@"; do s="$s\\x$h"; done
    printf "$s" | dd of="$f" bs=1 seek="$off" conv=notrunc status=none
}

bmpc_runner() {
    local mode=$1 off=$2 pattern=$3
    shift 3
    if [ "$off" = head ]; then
        head -c "$1" Ejemplo/lado.bmp > "$CASE_DIR/c.bmp"
    else
        cp Ejemplo/lado.bmp "$CASE_DIR/c.bmp"
        patch_bytes "$CASE_DIR/c.bmp" "$off" "$@"
    fi
    if [ "$mode" = embed ]; then
        expect_fail 2 "$pattern" '@D@/o*' -- -embed -in Ejemplo/README.txt -p @D@/c.bmp -out @D@/o.bmp -steg LSB1
    else
        expect_fail 2 "$pattern" '@D@/x*' -- -extract -p @D@/c.bmp -out @D@/x -steg LSB1
    fi
}
BMPC=()
bmpc() {
    local name=$1
    shift
    BMPC=("$@")
    run_case "$name" bmpc_call
}
bmpc_call() { bmpc_runner "${BMPC[@]}"; }

case_top_down_ok() {
    cp Ejemplo/lado.bmp "$CASE_DIR/c.bmp"
    patch_bytes "$CASE_DIR/c.bmp" 22 20 FE FF FF
    roundtrip LSB1 Ejemplo/README.txt "$CASE_DIR/c.bmp" "$CASE_DIR" .txt
}

case_cap_exact() {
    local m=$1 n=$2
    head -c "$n" /dev/zero > "$CASE_DIR/f.bin"
    roundtrip "$m" "$CASE_DIR/f.bin" Ejemplo/lado.bmp "$CASE_DIR" .bin
}
case_cap_over_LSB4() {
    head -c 460792 /dev/zero > "$CASE_DIR/f.bin"
    expect_fail 2 "maximum capacity of 'Ejemplo/lado.bmp' with LSB4 is 460800 bytes" '@D@/o*' -- -embed -in @D@/f.bin -p Ejemplo/lado.bmp -out @D@/o.bmp -steg LSB4
}
case_cap_sparse() {
    local d rc
    d=$(mktemp -d)
    truncate -s 5G "$d/huge.bin"
    timeout 5 "$BIN" -embed -in "$d/huge.bin" -p Ejemplo/lado.bmp -out "$CASE_DIR/o.bmp" -steg LSB4 >/dev/null 2>"$CASE_DIR/err"
    rc=$?
    rm -rf "$d"
    [ "$rc" = 2 ] || fail_msg "expected exit 2, got $rc" || return 1
    grep -qF "maximum capacity of 'Ejemplo/lado.bmp' with LSB4 is 460800 bytes" "$CASE_DIR/err" || fail_msg "capacity message missing" || return 1
    [ ! -e "$CASE_DIR/o.bmp" ] || fail_msg "output created"
}
case_ext_invalid_space() {
    echo x > "$CASE_DIR/photo.my ext"
    expect_fail 2 'unsupported file extension' '@D@/o*' -- -embed -in "@D@/photo.my ext" -p Ejemplo/lado.bmp -out @D@/o.bmp -steg LSB1
}
case_ext_too_long() {
    local f="$CASE_DIR/f.$(printf 'a%.0s' $(seq 1 40))"
    echo x > "$f"
    expect_fail 2 'unsupported file extension' '@D@/o*' -- -embed -in "$f" -p Ejemplo/lado.bmp -out @D@/o.bmp -steg LSB1
}

case_io_in_is_directory() {
    expect_fail 3 'not a regular file' '@D@/o*' -- -embed -in @D@ -p Ejemplo/lado.bmp -out @D@/o.bmp -steg LSB1
}

case_inputs_unmodified() {
    local d=$CASE_DIR before after
    vector_png || return 1
    cp Ejemplo/lado.bmp "$d/carrier.bmp"
    head -c 115192 /dev/zero > "$d/big.bin"
    before=$(sha256sum "$d/vec.png" "$d/carrier.bmp" "$d/big.bin")
    $BIN -embed -in "$d/vec.png" -p "$d/carrier.bmp" -out "$d/s.bmp" -steg LSB1 >/dev/null || return 1
    $BIN -embed -in "$d/big.bin" -p "$d/carrier.bmp" -out "$d/b.bmp" -steg LSB1 >/dev/null 2>&1
    $BIN -extract -p "$d/s.bmp" -out "$d/x" -steg LSB1 >/dev/null || return 1
    after=$(sha256sum "$d/vec.png" "$d/carrier.bmp" "$d/big.bin")
    [ "$before" = "$after" ] || fail_msg "an input file changed" || return 1
    [ ! -e "$d/b.bmp" ] || fail_msg "failed embed created output"
}

case_any_order_stego_only() {
    vector_png || return 1
    $BIN -steg LSB1 -a aes256 -m ofb -out "$CASE_DIR/o.bmp" -p Ejemplo/lado.bmp -in "$CASE_DIR/vec.png" -embed || fail_msg "embed failed" || return 1
    cmp "$CASE_DIR/o.bmp" Ejemplo/ladoLSB1.bmp || fail_msg "differs from reference"
}
case_extract_mode_only_stego() {
    $BIN -out "$CASE_DIR/x" -steg LSB1 -m cbc -extract -p Ejemplo/ladoLSB1.bmp || fail_msg "extract failed" || return 1
    [ "$(sha256sum "$CASE_DIR/x.png" | cut -d' ' -f1)" = "$PNG_SHA256" ] || fail_msg "wrong sha256"
}

run_case vector-extract-LSB1 case_vector_extract_LSB1
run_case vector-reembed-LSB1 case_vector_reembed_LSB1
run_case vector-diff-region-LSB1 case_vector_diff_region_LSB1
run_case cap-over-LSB1 case_cap_over_LSB1
run_case vector-extract-LSB4 case_vector_extract_LSB4
run_case vector-reembed-LSB4 case_vector_reembed_LSB4
run_case vector-diff-region-LSB4 case_vector_diff_region_LSB4
run_case vector-extract-LSBI case_vector_extract_LSBI
run_case vector-reembed-LSBI case_vector_reembed_LSBI
run_case vector-diff-region-LSBI case_vector_diff_region_LSBI
# ---- encrypted cátedra vectors: tag | file | method | alg | mode ----
ENC_VECTORS=(
    "LSB1aes128cbc|Ejemplo/ladoLSB1aes128cbc.bmp|LSB1|aes128|cbc"
    "LSBIaes256ofb|Ejemplo/ladoLSBIaes256ofb.bmp|LSBI|aes256|ofb"
    "LSBIdescfb|Ejemplo/ladoLSBIdescfb.bmp|LSBI|3des|cfb"
)

case_enc_vector_extract() {
    local file=$1 method=$2 alg=$3 mode=$4 d=$CASE_DIR
    $BIN -extract -p "$file" -out "$d/h" -steg "$method" -a "$alg" -m "$mode" -pass margarita >"$d/run.log" 2>&1 || fail_msg "extract exit $?" || return 1
    [ -f "$d/h.png" ] || fail_msg "h.png missing" || return 1
    [ "$(stat -c %s "$d/h.png")" = "$PNG_SIZE" ] || fail_msg "wrong size" || return 1
    [ "$(sha256sum "$d/h.png" | cut -d" " -f1)" = "$PNG_SHA256" ] || fail_msg "wrong sha256" || return 1
    check_png "$d/h.png" || return 1
    grep -qF "(decrypted with $alg-$mode)" "$d/run.log" || fail_msg "success line lacks (decrypted with $alg-$mode)" || return 1
    ! grep -q margarita "$d/run.log" || fail_msg "password leaked into output" || return 1
    no_tmp
}

case_enc_vector_reembed() {
    local file=$1 method=$2 alg=$3 mode=$4 d=$CASE_DIR
    $BIN -extract -p "$file" -out "$d/h" -steg "$method" -a "$alg" -m "$mode" -pass margarita >/dev/null || fail_msg "extract failed" || return 1
    $BIN -embed -in "$d/h.png" -p Ejemplo/lado.bmp -out "$d/s.bmp" -steg "$method" -a "$alg" -m "$mode" -pass margarita >/dev/null || fail_msg "embed failed" || return 1
    cmp "$d/s.bmp" "$file" || fail_msg "re-embed differs from $file" || return 1
    cmp -n 54 "$d/s.bmp" Ejemplo/lado.bmp || fail_msg "header changed"
}

for row in "${ENC_VECTORS[@]}"; do
    IFS="|" read -r tag file method alg mode <<<"$row"
    eval "vxe_$tag() { case_enc_vector_extract $file $method $alg $mode; }"
    eval "vre_$tag() { case_enc_vector_reembed $file $method $alg $mode; }"
    run_case "vector-extract-$tag" "vxe_$tag"
    run_case "vector-reembed-$tag" "vre_$tag"
done

# ---- differential: stegobmp vs tools/cryptoref.py (hashlib PBKDF2 + openssl enc) ----
case_differential_crypto() {
    local alg=$1 mode=$2 d=$CASE_DIR want
    case $mode in
    cfb | ofb) want=1009 ;;
    *) case $alg in 3des) want=1016 ;; *) want=1024 ;; esac ;;
    esac
    head -c 1000 /dev/urandom > "$d/f.bin"
    $BIN -embed -in "$d/f.bin" -p Ejemplo/lado.bmp -out "$d/s.bmp" -steg LSB1 -a "$alg" -m "$mode" -pass 'clave de prueba' >/dev/null || fail_msg "embed failed" || return 1
    python3 tools/cryptoref.py open "$d/s.bmp" LSB1 "$alg" "$mode" 'clave de prueba' "$d/ref" > "$d/ref.out" || fail_msg "oracle failed: $(cat "$d/ref.out")" || return 1
    grep -qxF "cipher_size=$want size=1000 ext=.bin" "$d/ref.out" || fail_msg "oracle says: $(cat "$d/ref.out"), expected cipher_size=$want" || return 1
    cmp "$d/f.bin" "$d/ref.bin" || fail_msg "oracle output differs from the hidden file" || return 1
    $BIN -extract -p "$d/s.bmp" -out "$d/o" -steg LSB1 -a "$alg" -m "$mode" -pass 'clave de prueba' >/dev/null || fail_msg "extract failed" || return 1
    cmp "$d/f.bin" "$d/o.bin" || fail_msg "stegobmp extract differs from the hidden file"
}
for alg in aes128 aes192 aes256 3des; do
    for mode in ecb cfb ofb cbc; do
        eval "dc_${alg}_${mode}() { case_differential_crypto $alg $mode; }"
        run_case "differential-crypto-$alg-$mode" "dc_${alg}_${mode}"
    done
done

for m in LSB1 LSB4 LSBI; do
    for k in text binary multidot noext spaces; do
        eval "rt_${m}_${k}() { case_roundtrip $m $k; }"
        run_case "roundtrip-$m-$k" "rt_${m}_${k}"
    done
    eval "em_$m() { case_empty $m; }"
    run_case "edge-empty-$m" "em_$m"
    eval "pc_$m() { case_padded_capacity $m; }"
    run_case "edge-padded-capacity-$m" "pc_$m"
done
run_case edge-out-equals-carrier case_out_equals_carrier
run_case edge-parallel-embed case_parallel_embed

E='-embed -in Ejemplo/README.txt -p Ejemplo/lado.bmp -out @D@/o.bmp'
O='@D@/o*'
X='@D@/x*'
ef cli-wrong-case-steg 1 "invalid value for -steg: 'lsb1'" "$O" -- $E -steg lsb1
ef cli-duplicate-param 1 'duplicate parameter -p' "$O" -- $E -p Ejemplo/lado.bmp -steg LSB1
ef cli-no-args 1 'missing -embed or -extract' '' --
ef cli-unknown-Embed 1 "unknown parameter '-Embed'" "$O" -- -Embed -in Ejemplo/README.txt -p Ejemplo/lado.bmp -out @D@/o.bmp -steg LSB1
ef cli-unknown-double-dash 1 "unknown parameter '--embed'" "$O" -- --embed -in Ejemplo/README.txt -p Ejemplo/lado.bmp -out @D@/o.bmp -steg LSB1
ef cli-unknown-STEG 1 "unknown parameter '-STEG'" "$O" -- $E -STEG LSB1
ef cli-unknown-positional 1 "unknown parameter 'foo'" "$O" -- $E -steg LSB1 foo
ef cli-glued-flag 1 "unknown parameter '-stegLSB1'" "$O" -- $E -stegLSB1
ef cli-prefix-flag 1 "unknown parameter '-ste'" "$O" -- $E -ste LSB1
ef cli-invalid-steg-LSB5 1 "invalid value for -steg: 'LSB5'" "$O" -- $E -steg LSB5
ef cli-invalid-steg-trailing-space 1 "invalid value for -steg: 'LSB1 '" "$O" -- $E -steg 'LSB1 '
ef cli-invalid-a-case 1 "invalid value for -a: 'AES128'" "$O" -- $E -steg LSB1 -a AES128
ef cli-invalid-a-des 1 "invalid value for -a: 'des'" "$O" -- $E -steg LSB1 -a des
ef cli-invalid-m-case 1 "invalid value for -m: 'CBC'" "$O" -- $E -steg LSB1 -m CBC
ef cli-missing-value-last 1 'missing value for -steg' "$O" -- $E -steg
ef cli-empty-value 1 'empty value for -p' "$O" -- -embed -in Ejemplo/README.txt -p '' -out @D@/o.bmp -steg LSB1
ef cli-flag-as-value 1 'missing value for -out' "$O" -- -embed -in Ejemplo/README.txt -p Ejemplo/lado.bmp -out -steg LSB1
ef cli-both-modes 1 'choose exactly one of -embed or -extract' "$O" -- $E -extract -steg LSB1
ef cli-missing-in 1 'missing required parameter -in for -embed' "$O" -- -embed -p Ejemplo/lado.bmp -out @D@/o.bmp -steg LSB1
ef cli-missing-out 1 'missing required parameter -out for -embed' "$O" -- -embed -in Ejemplo/README.txt -p Ejemplo/lado.bmp -steg LSB1
ef cli-missing-p-extract 1 'missing required parameter -p for -extract' "$X" -- -extract -out @D@/x -steg LSB1
ef cli-missing-steg-extract 1 'missing required parameter -steg for -extract' "$X" -- -extract -p Ejemplo/ladoLSB1.bmp -out @D@/x
ef cli-in-with-extract 1 '-in is not valid with -extract' "$X" -- -extract -in Ejemplo/README.txt -p Ejemplo/ladoLSB1.bmp -out @D@/x -steg LSB1
run_case cli-any-order-stego-only case_any_order_stego_only
run_case cli-extract-mode-only-stego case_extract_mode_only_stego

bmpc bmp-bpp32-embed embed 28 'only 24 bits per pixel is supported' 20 00
bmpc bmp-bpp8-extract extract 28 'only 24 bits per pixel is supported' 08 00
bmpc bmp-compressed-embed embed 30 'compressed' 01 00 00 00
bmpc bmp-compressed-extract extract 30 'compressed' 01 00 00 00
bmpc bmp-not-v3 embed 14 'only BMP V3' 7C 00 00 00
bmpc bmp-bad-signature embed 0 "missing 'BM' signature" 58 58
bmpc bmp-too-short embed head 'shorter than the 54-byte header' 20
bmpc bmp-truncated embed head 'truncated BMP' 100000
bmpc bmp-huge-width embed 18 'truncated BMP' FF FF FF 7F
bmpc bmp-negative-width embed 18 'invalid BMP dimensions' FF FF FF FF
bmpc bmp-zero-height embed 22 'invalid BMP dimensions' 00 00 00 00
bmpc bmp-height-int-min embed 22 'truncated BMP' 00 00 00 80
bmpc bmp-offset-beyond embed 10 'invalid BMP pixel data offset' F0 FF FF FF
run_case bmp-top-down-ok case_top_down_ok

cap_exact_LSB1() { case_cap_exact LSB1 115191; }
cap_exact_LSB4() { case_cap_exact LSB4 460791; }
run_case cap-exact-LSB1 cap_exact_LSB1
run_case cap-exact-LSB4 cap_exact_LSB4
run_case cap-over-LSB4 case_cap_over_LSB4
run_case cap-sparse-5GiB case_cap_sparse
run_case ext-invalid-space case_ext_invalid_space
run_case ext-too-long case_ext_too_long

ef extract-clean-LSB1 2 'no hidden file found' "$X" -- -extract -p Ejemplo/lado.bmp -out @D@/x -steg LSB1
ef extract-clean-LSB4 2 'no hidden file found' "$X" -- -extract -p Ejemplo/lado.bmp -out @D@/x -steg LSB4
ef extract-wrong-method-LSB4 2 'no hidden file found' "$X" -- -extract -p Ejemplo/ladoLSB1.bmp -out @D@/x -steg LSB4
ef extract-wrong-method-LSB1 2 'no hidden file found' "$X" -- -extract -p Ejemplo/ladoLSB4.bmp -out @D@/x -steg LSB1
ef extract-encrypted-without-pass 2 'malformed extension field' "$X" -- -extract -p Ejemplo/ladoLSB1aes128cbc.bmp -out @D@/x -steg LSB1

ef io-missing-carrier 3 'cannot read' "$O" -- -embed -in Ejemplo/README.txt -p @D@/nope.bmp -out @D@/o.bmp -steg LSB1
ef io-missing-in 3 'cannot read' "$O" -- -embed -in @D@/nope.txt -p Ejemplo/lado.bmp -out @D@/o.bmp -steg LSB1
run_case io-in-is-directory case_io_in_is_directory
ef io-out-dir-missing 3 'cannot write' '@D@/no*' -- -embed -in Ejemplo/README.txt -p Ejemplo/lado.bmp -out @D@/no/such/dir/o.bmp -steg LSB1
ef io-extract-out-dir-missing 3 'cannot write' '@D@/no*' -- -extract -p Ejemplo/ladoLSB1.bmp -out @D@/no/such/x -steg LSB1
run_case inputs-unmodified case_inputs_unmodified

# ---- LSBI cases ----
case_cap_exact_LSBI() { case_cap_exact LSBI 76790; }
case_cap_over_LSBI() {
    head -c 76791 /dev/zero > "$CASE_DIR/f.bin"
    expect_fail 2 "maximum capacity of 'Ejemplo/lado.bmp' with LSBI is 76799 bytes" '@D@/o*' -- -embed -in @D@/f.bin -p Ejemplo/lado.bmp -out @D@/o.bmp -steg LSBI
}
case_padded_over_LSBI() {
    make_bmp "$CASE_DIR/c.bmp" 33 17 16
    head -c 133 /dev/urandom > "$CASE_DIR/f.bin"
    expect_fail 2 'with LSBI is 141 bytes' '@D@/o*' -- -embed -in @D@/f.bin -p @D@/c.bmp -out @D@/o.bmp -steg LSBI
}
case_lsbi_tiny_carrier() {
    make_bmp "$CASE_DIR/c.bmp" 1 1 0
    : > "$CASE_DIR/e.txt"
    expect_fail 2 'with LSBI is 0 bytes' '@D@/o*' -- -embed -in @D@/e.txt -p @D@/c.bmp -out @D@/o.bmp -steg LSBI || return 1
    expect_fail 2 'no hidden file found' '@D@/x*' -- -extract -p @D@/c.bmp -out @D@/x -steg LSBI
}
# lsbi_flag_case FILL LASTBYTES EXPECTED_FLAGS: 10x10 carrier of FILL bytes, 8-byte file
lsbi_flag_case() {
    local fill=$1 last=$2 want=$3 d=$CASE_DIR got
    make_bmp "$d/c.bmp" 10 10 0 "$fill"
    printf "\xff\xff\xff\xff\xff\xff\x$last\x00" > "$d/f.bin"
    roundtrip LSBI "$d/f.bin" "$d/c.bmp" "$d" .bin || return 1
    got=$(od -An -tx1 -j54 -N4 "$d/s.bmp" | tr -s ' ' | sed 's/^ //;s/ $//')
    [ "$got" = "$want" ] || fail_msg "flag bytes '$got', expected '$want'"
}
case_lsbi_flag_tie() { lsbi_flag_case 00 07 '00 00 00 00'; }
case_lsbi_flag_red() { lsbi_flag_case 04 0f '04 04 05 04'; }
# differential_lsbi NAME-arg: CARRIER-maker, size
case_differential_LSBI() {
    local kind=$1 d=$CASE_DIR carrier n
    case $kind in
    lado) carrier=Ejemplo/lado.bmp; n=20000 ;;
    padded) make_bmp "$d/c.bmp" 33 17 16; carrier=$d/c.bmp; n=132 ;;
    oddrow) make_bmp "$d/c.bmp" 31 20 5; carrier=$d/c.bmp; n=150 ;;
    esac
    head -c "$n" /dev/urandom > "$d/f.bin"
    $BIN -embed -in "$d/f.bin" -p "$carrier" -out "$d/s.bmp" -steg LSBI || fail_msg "embed failed" || return 1
    python3 tools/lsbi.py embed-file "$carrier" "$d/f.bin" "$d/ref.bmp" || fail_msg "reference model failed" || return 1
    cmp "$d/s.bmp" "$d/ref.bmp" || fail_msg "differs from tools/lsbi.py reference"
}
dl_lado() { case_differential_LSBI lado; }
dl_padded() { case_differential_LSBI padded; }
dl_oddrow() { case_differential_LSBI oddrow; }
run_case cap-exact-LSBI case_cap_exact_LSBI
run_case cap-over-LSBI case_cap_over_LSBI
run_case edge-padded-over-LSBI case_padded_over_LSBI
run_case edge-lsbi-tiny-carrier case_lsbi_tiny_carrier
run_case edge-lsbi-flag-tie case_lsbi_flag_tie
run_case edge-lsbi-flag-red case_lsbi_flag_red
run_case differential-LSBI-lado dl_lado
run_case differential-LSBI-padded dl_padded
run_case differential-LSBI-oddrow dl_oddrow
ef extract-clean-LSBI 2 'no hidden file found' "$X" -- -extract -p Ejemplo/lado.bmp -out @D@/x -steg LSBI
ef extract-wrong-method-LSBI-on-LSB1 2 'no hidden file found' "$X" -- -extract -p Ejemplo/ladoLSB1.bmp -out @D@/x -steg LSBI
ef extract-wrong-method-LSB1-on-LSBI 2 'no hidden file found' "$X" -- -extract -p Ejemplo/ladoLSBI.bmp -out @D@/x -steg LSB1
ef extract-wrong-method-LSB4-on-LSBI 2 'no hidden file found' "$X" -- -extract -p Ejemplo/ladoLSBI.bmp -out @D@/x -steg LSB4
# ---- CLI-03 defaults, encryption edge cases ----
case_default_embed() {
    # case_default_embed INFILE EXPECT_LINE -- SHORT_ARGS... -- LONG_ARGS...  (short and long must agree)
    local infile=$1 want=$2 d=$CASE_DIR
    shift 3
    local short=() long=()
    while [ "$1" != -- ]; do short+=("$1"); shift; done
    shift
    long=("$@")
    $BIN -embed -in "$infile" -p Ejemplo/lado.bmp -out "$d/short.bmp" -steg LSB1 "${short[@]}" >"$d/short.out" 2>&1 || fail_msg "short embed failed" || return 1
    $BIN -embed -in "$infile" -p Ejemplo/lado.bmp -out "$d/long.bmp" -steg LSB1 "${long[@]}" >"$d/long.out" 2>&1 || fail_msg "explicit embed failed" || return 1
    cmp "$d/short.bmp" "$d/long.bmp" || fail_msg "defaults differ from the explicit form" || return 1
    grep -qF "$want" "$d/short.out" || fail_msg "stdout lacks '$want': $(cat "$d/short.out")"
}
case_default_pass_only_embed() {
    vector_png || return 1
    case_default_embed "$CASE_DIR/vec.png" "with aes128-cbc encryption" -- -pass margarita -- -a aes128 -m cbc -pass margarita || return 1
    cmp "$CASE_DIR/short.bmp" Ejemplo/ladoLSB1aes128cbc.bmp || fail_msg "differs from Ejemplo/ladoLSB1aes128cbc.bmp"
}
case_default_a_only_embed() { case_default_embed Ejemplo/README.txt "with aes256-cbc encryption" -- -a aes256 -pass pw1 -- -a aes256 -m cbc -pass pw1; }
case_default_m_only_embed() { case_default_embed Ejemplo/README.txt "with aes128-ofb encryption" -- -m ofb -pass pw1 -- -a aes128 -m ofb -pass pw1; }

# default_extract ARGS...: recover the PNG from the aes128-cbc vector with a partial spec
default_extract() {
    local d=$CASE_DIR
    $BIN -extract -p Ejemplo/ladoLSB1aes128cbc.bmp -out "$d/h" -steg LSB1 "$@" >"$d/run.log" 2>&1 || fail_msg "extract failed: $(cat "$d/run.log")" || return 1
    [ "$(sha256sum "$d/h.png" | cut -d' ' -f1)" = "$PNG_SHA256" ] || fail_msg "wrong sha256" || return 1
    grep -qF "(decrypted with aes128-cbc)" "$d/run.log" || fail_msg "stdout lacks (decrypted with aes128-cbc)"
}
case_default_pass_only_extract() { default_extract -pass margarita; }
case_default_a_only_extract() { default_extract -a aes128 -pass margarita; }
case_default_m_only_extract() { default_extract -m cbc -pass margarita; }

case_no_pass_note_embed() {
    local d=$CASE_DIR
    vector_png || return 1
    $BIN -embed -in "$d/vec.png" -p Ejemplo/lado.bmp -out "$d/o.bmp" -steg LSB1 -a aes256 -m ofb >"$d/out" 2>"$d/err" || fail_msg "embed exit $?" || return 1
    cmp "$d/o.bmp" Ejemplo/ladoLSB1.bmp || fail_msg "differs from Ejemplo/ladoLSB1.bmp" || return 1
    grep -qxF 'stegobmp: note: -a/-m ignored because no -pass was given (no encryption)' "$d/err" || fail_msg "note missing: $(cat "$d/err")"
}
case_no_pass_note_extract() {
    local d=$CASE_DIR
    $BIN -extract -p Ejemplo/ladoLSB1.bmp -out "$d/x" -steg LSB1 -a 3des >"$d/out" 2>"$d/err" || fail_msg "extract exit $?" || return 1
    [ "$(sha256sum "$d/x.png" | cut -d' ' -f1)" = "$PNG_SHA256" ] || fail_msg "wrong sha256" || return 1
    grep -qxF 'stegobmp: note: -a/-m ignored because no -pass was given (no encryption)' "$d/err" || fail_msg "note missing: $(cat "$d/err")"
}

case_encrypt_deterministic() {
    local d=$CASE_DIR
    $BIN -embed -in Ejemplo/README.txt -p Ejemplo/lado.bmp -out "$d/a.bmp" -steg LSBI -a 3des -m ofb -pass pw2 >/dev/null || return 1
    $BIN -embed -in Ejemplo/README.txt -p Ejemplo/lado.bmp -out "$d/b.bmp" -steg LSBI -a 3des -m ofb -pass pw2 >/dev/null || return 1
    cmp "$d/a.bmp" "$d/b.bmp" || fail_msg "two identical encrypted embeds differ"
}

case_parallel_embed_encrypted() {
    local d=$CASE_DIR pids=() p
    vector_png || return 1
    for _ in 1 2 3 4; do
        $BIN -embed -in "$d/vec.png" -p Ejemplo/lado.bmp -out "$d/stego.bmp" -steg LSB1 -pass margarita >/dev/null 2>&1 &
        pids+=($!)
    done
    for p in "${pids[@]}"; do
        wait "$p" || fail_msg "a parallel embed failed" || return 1
    done
    cmp "$d/stego.bmp" Ejemplo/ladoLSB1aes128cbc.bmp || fail_msg "differs from reference" || return 1
    no_tmp
}

case_password_utf8() {
    local d=$CASE_DIR pw='contraseña con espacios'
    head -c 3000 /dev/urandom > "$d/f.bin"
    roundtrip LSB4 "$d/f.bin" Ejemplo/lado.bmp "$d" .bin -a aes192 -m cfb -pass "$pw" || return 1
    python3 tools/cryptoref.py open "$d/s.bmp" LSB4 aes192 cfb "$pw" "$d/ref" >"$d/ref.out" || fail_msg "oracle failed: $(cat "$d/ref.out")" || return 1
    cmp "$d/f.bin" "$d/ref.bin" || fail_msg "oracle output differs"
}

run_case cli-default-pass-only-embed case_default_pass_only_embed
run_case cli-default-a-only-embed case_default_a_only_embed
run_case cli-default-m-only-embed case_default_m_only_embed
run_case cli-default-pass-only-extract case_default_pass_only_extract
run_case cli-default-a-only-extract case_default_a_only_extract
run_case cli-default-m-only-extract case_default_m_only_extract
ef cli-default-a-implies-cbc 2 'cannot decrypt the hidden data with aes256-cbc' '@D@/x*' -- -extract -p Ejemplo/ladoLSBIaes256ofb.bmp -out @D@/x -steg LSBI -a aes256 -pass margarita
ef cli-default-m-implies-aes128 2 'cannot decrypt the hidden data with aes128-ofb' '@D@/x*' -- -extract -p Ejemplo/ladoLSBIaes256ofb.bmp -out @D@/x -steg LSBI -m ofb -pass margarita
run_case cli-no-pass-note-embed case_no_pass_note_embed
run_case cli-no-pass-note-extract case_no_pass_note_extract
run_case edge-encrypt-deterministic case_encrypt_deterministic
run_case edge-parallel-embed-encrypted case_parallel_embed_encrypted
run_case edge-password-utf8 case_password_utf8

# ---- CRYP-04: decryption failures, corrupt/hostile ciphertext, encrypted capacity ----
# df NAME PASSWORD CODE PATTERN -- ARGS...: expect_fail, then the password must not appear in stdout/stderr
df_runner() {
    local pw=${DF[0]}
    EF_N=0
    expect_fail "${DF[@]:1}" || return 1
    if grep -qF -- "$pw" "$CASE_DIR"/ef*.out "$CASE_DIR"/ef*.err; then fail_msg "password '$pw' leaked into stdout/stderr" || return 1; fi
}
df() {
    local name=$1
    shift
    DF=("$1" "$2" "$3" '@D@/x*' "${@:4}")
    run_case "$name" df_runner
}

# flip_lsb FILE OFFSET: invert bit 0 of the byte at OFFSET
flip_lsb() {
    local b
    b=$(od -An -tu1 -j"$2" -N1 "$1" | tr -d ' ')
    patch_bytes "$1" "$2" "$(printf '%02x' $((b ^ 1)))"
}

# set_lsb1_size FILE VALUE: write VALUE (32 bits, MSB first) into the LSBs of file bytes 54..85
set_lsb1_size() {
    local f=$1 v=$2 i b bit
    for i in $(seq 0 31); do
        b=$(od -An -tu1 -j$((54 + i)) -N1 "$f" | tr -d ' ')
        bit=$(((v >> (31 - i)) & 1))
        patch_bytes "$f" $((54 + i)) "$(printf '%02x' $(((b & 254) | bit)))"
    done
}

V_CBC=Ejemplo/ladoLSB1aes128cbc.bmp
V_OFB=Ejemplo/ladoLSBIaes256ofb.bmp
V_CFB=Ejemplo/ladoLSBIdescfb.bmp
df decrypt-fail-wrong-password-LSB1aes128cbc naranja 2 "cannot decrypt the hidden data with aes128-cbc (wrong password, algorithm or mode, or '$V_CBC' holds no encrypted payload)" -- -extract -p $V_CBC -out @D@/x -steg LSB1 -a aes128 -m cbc -pass naranja
df decrypt-fail-wrong-password-LSBIaes256ofb naranja 2 "cannot decrypt the hidden data with aes256-ofb (wrong password" -- -extract -p $V_OFB -out @D@/x -steg LSBI -a aes256 -m ofb -pass naranja
df decrypt-fail-wrong-password-LSBIdescfb naranja 2 "cannot decrypt the hidden data with 3des-cfb (wrong password" -- -extract -p $V_CFB -out @D@/x -steg LSBI -a 3des -m cfb -pass naranja
df decrypt-fail-password-case Margarita 2 "with aes128-cbc (wrong password" -- -extract -p $V_CBC -out @D@/x -steg LSB1 -a aes128 -m cbc -pass Margarita
df decrypt-fail-wrong-alg margarita 2 "with aes192-cbc (wrong password" -- -extract -p $V_CBC -out @D@/x -steg LSB1 -a aes192 -m cbc -pass margarita
df decrypt-fail-wrong-mode margarita 2 "with aes256-cfb (wrong password" -- -extract -p $V_OFB -out @D@/x -steg LSBI -a aes256 -m cfb -pass margarita
case_decrypt_ecb_wrong_password() {
    $BIN -embed -in Ejemplo/README.txt -p Ejemplo/lado.bmp -out "$CASE_DIR/s.bmp" -steg LSB1 -a 3des -m ecb -pass uno >/dev/null || fail_msg "embed failed" || return 1
    df_runner
}
DF=(dos 2 "with 3des-ecb (wrong password" '@D@/x*' -- -extract -p @D@/s.bmp -out @D@/x -steg LSB1 -a 3des -m ecb -pass dos)
run_case decrypt-fail-ecb-wrong-password case_decrypt_ecb_wrong_password
df decrypt-fail-pass-on-plain-LSB1 margarita 2 "with aes128-cbc (wrong password" -- -extract -p Ejemplo/ladoLSB1.bmp -out @D@/x -steg LSB1 -pass margarita
df decrypt-fail-pass-on-plain-LSB4-ofb margarita 2 "with aes128-ofb (wrong password" -- -extract -p Ejemplo/ladoLSB4.bmp -out @D@/x -steg LSB4 -m ofb -pass margarita
df decrypt-fail-pass-on-plain-LSBI-3des-cfb margarita 2 "with 3des-cfb (wrong password" -- -extract -p Ejemplo/ladoLSBI.bmp -out @D@/x -steg LSBI -a 3des -m cfb -pass margarita
df decrypt-fail-pass-on-clean-LSB1 margarita 2 "no hidden file found" -- -extract -p Ejemplo/lado.bmp -out @D@/x -steg LSB1 -pass margarita
df decrypt-fail-pass-on-clean-LSBI margarita 2 "no hidden file found" -- -extract -p Ejemplo/lado.bmp -out @D@/x -steg LSBI -pass margarita

case_decrypt_corrupt_cbc_padding() {
    cp $V_CBC "$CASE_DIR/c.bmp"
    flip_lsb "$CASE_DIR/c.bmp" 359125
    expect_fail 2 "with aes128-cbc (wrong password" '@D@/x*' -- -extract -p @D@/c.bmp -out @D@/x -steg LSB1 -a aes128 -m cbc -pass margarita || return 1
    expect_fail 2 "bad padding" '@D@/x*' -- -extract -p @D@/c.bmp -out @D@/x -steg LSB1 -a aes128 -m cbc -pass margarita
}
case_decrypt_corrupt_ofb_size() {
    $BIN -embed -in Ejemplo/README.txt -p Ejemplo/lado.bmp -out "$CASE_DIR/c.bmp" -steg LSB1 -a aes128 -m ofb -pass margarita >/dev/null || fail_msg "embed failed" || return 1
    flip_lsb "$CASE_DIR/c.bmp" 86
    expect_fail 2 "the decrypted data is not a valid hidden file" '@D@/x*' -- -extract -p @D@/c.bmp -out @D@/x -steg LSB1 -a aes128 -m ofb -pass margarita
}
case_decrypt_hostile() {
    local v=$1 alg_pat=$2 pat2=$3 pat1=$4
    cp $V_CBC "$CASE_DIR/c.bmp"
    set_lsb1_size "$CASE_DIR/c.bmp" "$v"
    expect_fail 2 "$pat1" '@D@/x*' -- -extract -p @D@/c.bmp -out @D@/x -steg LSB1 -a aes128 -m cbc -pass margarita || return 1
    expect_fail 2 "$pat2" '@D@/x*' -- -extract -p @D@/c.bmp -out @D@/x -steg LSB1 -a aes128 -m cbc -pass margarita
}
dh_zero() { case_decrypt_hostile 0 x "ciphertext size field is 0" "no hidden file found"; }
dh_max() { case_decrypt_hostile 4294967295 x "at most" "no hidden file found"; }
dh_notblock() { case_decrypt_hostile 44895 x "not a multiple of the 16-byte block" "aes128-cbc"; }
run_case decrypt-corrupt-cbc-padding case_decrypt_corrupt_cbc_padding
run_case decrypt-corrupt-ofb-size case_decrypt_corrupt_ofb_size
run_case decrypt-hostile-size-zero dh_zero
run_case decrypt-hostile-size-max dh_max
run_case decrypt-hostile-size-not-block dh_notblock

# cap-enc: METHOD ALG MODE MAXFIT NEED_OVER CAPACITY
case_cap_enc_exact() { head -c "$5" /dev/zero > "$CASE_DIR/f.bin"; roundtrip "$1" "$CASE_DIR/f.bin" Ejemplo/lado.bmp "$CASE_DIR" .bin -a "$2" -m "$3" -pass pw; }
case_cap_enc_over() {
    head -c "$(($5 + 1))" /dev/zero > "$CASE_DIR/f.bin"
    expect_fail 2 "the payload needs $6 bytes" '@D@/o*' -- -embed -in @D@/f.bin -p Ejemplo/lado.bmp -out @D@/o.bmp -steg "$1" -a "$2" -m "$3" -pass pw || return 1
    expect_fail 2 "maximum capacity of 'Ejemplo/lado.bmp' with $1 is $7 bytes" '@D@/o*' -- -embed -in @D@/f.bin -p Ejemplo/lado.bmp -out @D@/o.bmp -steg "$1" -a "$2" -m "$3" -pass pw
}
CAP_ENC=(
    "LSB1 aes128 cbc 115174 115204 115200"
    "LSB1 aes128 ofb 115187 115201 115200"
    "LSB1 3des cbc 115182 115204 115200"
    "LSB4 aes256 cbc 460774 460804 460800"
    "LSBI aes128 cbc 76774 76804 76799"
)
for row in "${CAP_ENC[@]}"; do
    read -r cm ca cmo cfit cneed ccap <<<"$row"
    eval "cee_${cm}_${ca}_${cmo}() { case_cap_enc_exact $cm $ca $cmo x $cfit; }"
    eval "ceo_${cm}_${ca}_${cmo}() { case_cap_enc_over $cm $ca $cmo x $cfit $cneed $ccap; }"
    run_case "cap-enc-exact-$cm-$ca-$cmo" "cee_${cm}_${ca}_${cmo}"
    run_case "cap-enc-over-$cm-$ca-$cmo" "ceo_${cm}_${ca}_${cmo}"
done
case_cap_enc_sparse() {
    local d rc
    d=$(mktemp -d)
    truncate -s 5G "$d/huge.bin"
    timeout 5 "$BIN" -embed -in "$d/huge.bin" -p Ejemplo/lado.bmp -out "$CASE_DIR/o.bmp" -steg LSB4 -pass pw >/dev/null 2>"$CASE_DIR/err"
    rc=$?
    rm -rf "$d"
    [ "$rc" = 2 ] || fail_msg "expected exit 2, got $rc" || return 1
    grep -qF "maximum capacity of 'Ejemplo/lado.bmp' with LSB4 is 460800 bytes" "$CASE_DIR/err" || fail_msg "capacity message missing" || return 1
    [ ! -e "$CASE_DIR/o.bmp" ] || fail_msg "output created"
}
run_case cap-enc-sparse-5GiB case_cap_enc_sparse

# ---- TEST-02: method x (none + algorithm x mode) matrix, registered after everything else ----
case_matrix() {
    local m=$1
    shift
    head -c 1000 /dev/urandom > "$CASE_DIR/m.dat"
    roundtrip "$m" "$CASE_DIR/m.dat" Ejemplo/lado.bmp "$CASE_DIR" .dat "$@"
}
for m in LSB1 LSB4 LSBI; do
    eval "mx_${m}_none() { case_matrix $m; }"
    run_case "matrix-$m-none" "mx_${m}_none"
    for alg in aes128 aes192 aes256 3des; do
        for mode in ecb cfb ofb cbc; do
            eval "mx_${m}_${alg}_${mode}() { case_matrix $m -a $alg -m $mode -pass 'matriz 2026'; }"
            run_case "matrix-$m-$alg-$mode" "mx_${m}_${alg}_${mode}"
        done
    done
done

# oracle_cipher_size STEGO ALG MODE PW PREFIX WANT
oracle_cipher_size() {
    python3 tools/cryptoref.py open "$1" LSB1 "$2" "$3" "$4" "$5" > "$5.out" || fail_msg "oracle failed: $(cat "$5.out")" || return 1
    grep -q "^cipher_size=$6 " "$5.out" || fail_msg "oracle says: $(cat "$5.out"), expected cipher_size=$6"
}
case_empty_enc() {
    local alg=$1 mode=$2 d=$CASE_DIR want
    case $mode in cfb | ofb) want=9 ;; *) want=16 ;; esac
    : > "$d/e.txt"
    roundtrip LSB1 "$d/e.txt" Ejemplo/lado.bmp "$d" .txt -a "$alg" -m "$mode" -pass pw || return 1
    [ "$(stat -c %s "$d/o.txt")" = 0 ] || fail_msg "not empty" || return 1
    oracle_cipher_size "$d/s.bmp" "$alg" "$mode" pw "$d/ref" "$want"
}
case_pkcs5_fullblock() {
    local alg=$1 mode=$2 d=$CASE_DIR want
    case $alg in 3des) want=40 ;; *) want=48 ;; esac
    head -c 23 /dev/urandom > "$d/f.bin"
    roundtrip LSB1 "$d/f.bin" Ejemplo/lado.bmp "$d" .bin -a "$alg" -m "$mode" -pass pw || return 1
    oracle_cipher_size "$d/s.bmp" "$alg" "$mode" pw "$d/ref" "$want"
}
for alg in aes128 aes192 aes256 3des; do
    for mode in ecb cfb ofb cbc; do
        eval "ee_${alg}_${mode}() { case_empty_enc $alg $mode; }"
        run_case "edge-empty-enc-$alg-$mode" "ee_${alg}_${mode}"
    done
done
for alg in aes128 aes192 aes256 3des; do
    for mode in ecb cbc; do
        eval "pf_${alg}_${mode}() { case_pkcs5_fullblock $alg $mode; }"
        run_case "edge-pkcs5-fullblock-$alg-$mode" "pf_${alg}_${mode}"
    done
done

case_readme_examples() {
    local out
    out=$(bash tests/check_readme.sh 2>&1) || { echo "$out" | tail -n 5; fail_msg "check_readme.sh failed"; }
    echo "$out" | grep -q '^PASS check_readme:' || fail_msg "no PASS check_readme line"
}
run_case readme-examples case_readme_examples

# Every OpenSSL identifier must exist in OpenSSL 1.0.2, 1.1.1 and 3.x (pampero's version is unknown).
OPENSSL_ALLOWLIST="EVP_CIPHER EVP_CIPHER_CTX EVP_CIPHER_CTX_new EVP_CIPHER_CTX_free
EVP_CIPHER_CTX_set_padding EVP_CipherInit_ex EVP_CipherUpdate EVP_CipherFinal_ex
EVP_EncryptInit_ex EVP_EncryptUpdate EVP_EncryptFinal_ex EVP_DecryptInit_ex EVP_DecryptUpdate
EVP_DecryptFinal_ex EVP_sha256 EVP_aes_128_ecb EVP_aes_128_cbc EVP_aes_128_cfb8 EVP_aes_128_ofb
EVP_aes_192_ecb EVP_aes_192_cbc EVP_aes_192_cfb8 EVP_aes_192_ofb EVP_aes_256_ecb EVP_aes_256_cbc
EVP_aes_256_cfb8 EVP_aes_256_ofb EVP_des_ede3 EVP_des_ede3_ecb EVP_des_ede3_cbc EVP_des_ede3_cfb8
EVP_des_ede3_ofb EVP_MAX_BLOCK_LENGTH EVP_MAX_KEY_LENGTH EVP_MAX_IV_LENGTH PKCS5_PBKDF2_HMAC
OPENSSL_cleanse ERR_clear_error"

case_openssl_allowlist() {
    local id bad="" hdr ldl
    for id in $(grep -ohE '\b(EVP|PKCS5|OPENSSL|ERR|OSSL)_[A-Za-z0-9_]+' src/*.c src/*.h | sort -u); do
        case " $(echo $OPENSSL_ALLOWLIST) " in
            *" $id "*) ;;
            *) bad="$bad $id" ;;
        esac
    done
    [ -z "$bad" ] || fail_msg "OpenSSL identifiers outside the 1.0.2/1.1.1/3.x allowlist:$bad"
    for hdr in $(grep -ohE '#include <openssl/[a-z_]+\.h>' src/*.c src/*.h | sort -u | sed 's/#include <\(.*\)>/\1/'); do
        case "$hdr" in
            openssl/evp.h|openssl/crypto.h|openssl/err.h) ;;
            *) fail_msg "OpenSSL header not allowed: $hdr" ;;
        esac
    done
    ldl=$(grep -E '^LDLIBS' Makefile)
    case "$ldl" in *-lcrypto*) ;; *) fail_msg "Makefile LDLIBS lacks -lcrypto" ;; esac
    [ -z "$(echo "$ldl" | grep -oE -- '-l[a-z0-9_]+' | grep -vx -- '-lcrypto')" ] \
        || fail_msg "Makefile links a library other than -lcrypto: $ldl"
}
run_case build-openssl-api-allowlist case_openssl_allowlist

if [ "$ran" -eq 0 ]; then
    echo "no test case matches filter '$FILTER'"
    exit 2
fi
echo "SUMMARY: $passed passed, $failed failed"
[ "$failed" -eq 0 ]
