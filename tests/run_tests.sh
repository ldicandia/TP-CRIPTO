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

make_bmp() {
    python3 - "$1" "$2" "$3" "$4" <<'PY'
import sys, struct, random
path, w, h, trailing = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4])
stride = (w * 3 + 3) & ~3
rnd = random.Random(1234)
pix = bytes(rnd.randrange(256) for _ in range(stride * h))
hdr = b'BM' + struct.pack('<IHHI', 54 + stride * h + trailing, 0, 0, 54)
hdr += struct.pack('<IiiHHIIiiII', 40, w, h, 1, 24, 0, stride * h, 2835, 2835, 0, 0)
open(path, 'wb').write(hdr + pix + b'\xab' * trailing)
PY
}

roundtrip() {
    local method=$1 infile=$2 carrier=$3 dir=$4 ext=$5
    $BIN -embed -in "$infile" -p "$carrier" -out "$dir/s.bmp" -steg "$method" || fail_msg "embed failed" || return 1
    $BIN -extract -p "$dir/s.bmp" -out "$dir/o" -steg "$method" || fail_msg "extract failed" || return 1
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
    if [ "$method" = LSB1 ]; then n=203; else n=841; fi
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

case_pass_refused() {
    local mode=$1
    if [ "$mode" = embed ]; then
        expect_fail 1 'encryption (-pass) is not supported by this build' '@D@/o*' -- -embed -in Ejemplo/README.txt -p Ejemplo/lado.bmp -out @D@/o.bmp -steg LSB1 -pass secretpw
    else
        expect_fail 1 'encryption (-pass) is not supported by this build' '@D@/x*' -- -extract -p Ejemplo/ladoLSB1.bmp -out @D@/x -steg LSB1 -pass secretpw
    fi || return 1
    ! grep -q secretpw "$CASE_DIR"/ef*.out "$CASE_DIR"/ef*.err || fail_msg "password leaked"
}
pr_embed() { case_pass_refused embed; }
pr_extract() { case_pass_refused extract; }

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
for m in LSB1 LSB4; do
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
ef cli-lsbi-unsupported 1 'steganography method LSBI is not supported by this build (supported: LSB1, LSB4)' "$O" -- $E -steg LSBI
run_case cli-pass-refused-embed pr_embed
run_case cli-pass-refused-extract pr_extract
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

if [ "$ran" -eq 0 ]; then
    echo "no test case matches filter '$FILTER'"
    exit 2
fi
echo "SUMMARY: $passed passed, $failed failed"
[ "$failed" -eq 0 ]
