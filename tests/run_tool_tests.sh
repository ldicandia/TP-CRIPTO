#!/usr/bin/env bash
# Tests for the internal analysis tools (tools/*.py).
# Usage: bash tests/run_tool_tests.sh [filter]
set -u
cd "$(dirname "$0")/.." || exit 2

T=tests/out/tools
rm -rf "$T"
mkdir -p "$T"
FILTER=${1:-}

PNG_SHA256=b93be15382f35f099ca286241dd7bb6e681d5bce8d315ac0b6240f0b516f549d
LADO=Ejemplo/lado.bmp

sha256sum Ejemplo/* > "$T/ejemplo.sha256"

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
        if grep -qE '^Traceback \(most recent call last\):' "$T/$name.log"; then
            echo "FAIL $name: python traceback in log"
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

# has_line FILE LINE: exact whole-line match.
has_line() {
    grep -qxF -- "$2" "$1" || fail_msg "missing line: $2"
}

# Build the four hostile inputs in $1.
make_hostile() {
    local d=$1
    : > "$d/empty.bin"
    printf 'BMxxxxxxxxxxxxxxxxxxxxxxxxxxxx' > "$d/short.bmp"
    printf 'this is just a text file, not a bitmap\n' > "$d/text.txt"
    cp "$LADO" "$d/hugewidth.bmp"
    printf '\xff\xff\xff\x7f' | dd of="$d/hugewidth.bmp" bs=1 seek=18 conv=notrunc 2>/dev/null
}

# run_hostile TOOLSCRIPT MODE: run the tool on each hostile input; exit 0 or 1 only.
run_hostile() {
    local tool=$1 mode=$2 d="$CASE_DIR" f rc
    make_hostile "$d"
    for f in empty.bin short.bmp text.txt hugewidth.bmp; do
        case $mode in
            diff)
                python3 "tools/$tool" "$LADO" "$d/$f" >"$d/o1" 2>"$d/e1"; rc=$?
                [ $rc -le 1 ] || fail_msg "$tool $f (suspect): exit $rc" || return 1
                python3 "tools/$tool" "$d/$f" "$LADO" >"$d/o2" 2>"$d/e2"; rc=$?
                [ $rc -le 1 ] || fail_msg "$tool $f (carrier): exit $rc" || return 1
                ;;
            stats)
                python3 "tools/$tool" "$d/$f" >"$d/o1" 2>"$d/e1"; rc=$?
                [ $rc -le 1 ] || fail_msg "$tool $f: exit $rc" || return 1
                python3 "tools/$tool" --prefix 100 "$LADO" "$d/$f" >"$d/o2" 2>"$d/e2"; rc=$?
                [ $rc -le 1 ] || fail_msg "$tool $f (2 files): exit $rc" || return 1
                ;;
            probe)
                python3 "tools/$tool" probe "$d/$f" "$LADO" >"$d/o1" 2>"$d/e1"; rc=$?
                [ $rc -le 1 ] || fail_msg "$tool probe $f (carrier): exit $rc" || return 1
                python3 "tools/$tool" probe "$LADO" "$d/$f" >"$d/o2" 2>"$d/e2"; rc=$?
                [ $rc -le 1 ] || fail_msg "$tool probe $f (stego): exit $rc" || return 1
                python3 "tools/$tool" extract-raw "$d/$f" "$d/x.out" >"$d/o3" 2>"$d/e3"; rc=$?
                [ $rc -le 1 ] || fail_msg "$tool extract-raw $f: exit $rc" || return 1
                ;;
        esac
        if cat "$d"/o* "$d"/e* 2>/dev/null | grep -q 'Traceback'; then
            fail_msg "traceback for $f" || return 1
        fi
    done
}

# ---------------------------------------------------------------- diff

case_diff_vector_LSBI() {
    local o="$CASE_DIR/out"
    python3 tools/bmpdiff.py "$LADO" Ejemplo/ladoLSBI.bmp > "$o" || fail_msg "exit $?" || return 1
    has_line "$o" 'summary changed_bytes=170852 changed_bits=170852 mask=0x01 first=78 last=538794' || return 1
    has_line "$o" 'channels B=85551 G=85301 R=0 PAD=0 HDR=0 TRAIL=0 OTHER=0' || return 1
    has_line "$o" 'bitpos b0=170852 b1=0 b2=0 b3=0 b4=0 b5=0 b6=0 b7=0' || return 1
    has_line "$o" 'distortion mse=0.185386 psnr=55.4500 samples=921600 basis=pixels' || return 1
    grep -m1 '^diff offset=' "$o" | grep -q '^diff offset=78 region=PIX row=0 col=24 chan=B' \
        || fail_msg "first diff line wrong"
}

case_diff_vector_LSB1() {
    local o="$CASE_DIR/out"
    python3 tools/bmpdiff.py "$LADO" Ejemplo/ladoLSB1.bmp > "$o" || fail_msg "exit $?" || return 1
    has_line "$o" 'summary changed_bytes=190182 changed_bits=190182 mask=0x01 first=54 last=359213' || return 1
    has_line "$o" 'channels B=63231 G=63610 R=63341 PAD=0 HDR=0 TRAIL=0 OTHER=0' || return 1
    has_line "$o" 'distortion mse=0.206361 psnr=54.9845 samples=921600 basis=pixels'
}

case_diff_vector_LSB4() {
    local o="$CASE_DIR/out"
    python3 tools/bmpdiff.py "$LADO" Ejemplo/ladoLSB4.bmp > "$o" || fail_msg "exit $?" || return 1
    has_line "$o" 'summary changed_bytes=85370 changed_bits=205965 mask=0x0f first=54 last=89843' || return 1
    has_line "$o" 'channels B=28437 G=28490 R=28443 PAD=0 HDR=0 TRAIL=0 OTHER=0' || return 1
    has_line "$o" 'bitpos b0=50123 b1=51465 b2=51853 b3=52524 b4=0 b5=0 b6=0 b7=0' || return 1
    has_line "$o" 'distortion mse=8.763059 psnr=38.7042 samples=921600 basis=pixels'
}

case_diff_all_vectors() {
    local v o
    for v in LSB1 LSB4 LSBI LSB1aes128cbc LSBIaes256ofb LSBIdescfb; do
        o="$CASE_DIR/$v.out"
        python3 tools/bmpdiff.py "$LADO" "Ejemplo/lado$v.bmp" > "$o" || fail_msg "$v: exit $?" || return 1
        has_line "$o" 'header identical=yes differing=0' || return 1
        grep -q '^diff offset=' "$o" || fail_msg "$v: no diff line" || return 1
        grep -q '^summary ' "$o" || fail_msg "$v: no summary line" || return 1
    done
}

case_diff_identical() {
    local o="$CASE_DIR/out"
    python3 tools/bmpdiff.py "$LADO" "$LADO" > "$o" || fail_msg "exit $?" || return 1
    has_line "$o" 'summary changed_bytes=0 changed_bits=0 mask=0x00 first=- last=-' || return 1
    has_line "$o" 'distortion mse=0.000000 psnr=inf samples=921600 basis=pixels'
}

case_diff_appended() {
    local o="$CASE_DIR/out" s="$CASE_DIR/app.bmp"
    cp "$LADO" "$s"
    head -c 100 /dev/urandom >> "$s"
    python3 tools/bmpdiff.py "$LADO" "$s" > "$o" || fail_msg "exit $?" || return 1
    has_line "$o" 'length carrier=921654 suspect=921754 extra=100' || return 1
    has_line "$o" 'extra_bytes offset=921654..921753'
}

case_diff_limit() {
    local o="$CASE_DIR/out" n
    python3 tools/bmpdiff.py --limit 5 "$LADO" Ejemplo/ladoLSBI.bmp > "$o" || fail_msg "exit $?" || return 1
    n=$(grep -c '^diff offset=' "$o")
    [ "$n" = 5 ] || fail_msg "expected 5 diff lines, got $n" || return 1
    has_line "$o" 'more not_shown=170847'
}

case_diff_csv() {
    local o="$CASE_DIR/out" n
    python3 tools/bmpdiff.py --csv "$LADO" Ejemplo/ladoLSBI.bmp > "$o" || fail_msg "exit $?" || return 1
    n=$(wc -l < "$o")
    [ "$n" = 2 ] || fail_msg "expected 2 lines, got $n" || return 1
    head -n 1 "$o" | grep -q '^carrier,suspect,changed_bytes' || fail_msg "bad csv header"
}

case_diff_hostile() { run_hostile bmpdiff.py diff; }

case_tools_py36_syntax() {
    python3 - <<'PY' || fail_msg "py3.6 syntax check failed" || return 1
import ast, glob, sys
for p in sorted(glob.glob('tools/*.py')):
    ast.parse(open(p).read(), p, feature_version=(3, 6))
PY
    if grep -n 'bit_count' tools/*.py; then
        fail_msg "bit_count is not available before Python 3.10"
    fi
}

run_case diff-vector-LSBI case_diff_vector_LSBI
run_case diff-vector-LSB1 case_diff_vector_LSB1
run_case diff-vector-LSB4 case_diff_vector_LSB4
run_case diff-all-vectors case_diff_all_vectors
run_case diff-identical case_diff_identical
run_case diff-appended case_diff_appended
run_case diff-limit case_diff_limit
run_case diff-csv case_diff_csv
run_case diff-hostile case_diff_hostile
run_case tools-py36-syntax case_tools_py36_syntax

# ---------------------------------------------------------------- stats

case_stats_side_by_side_LSBI() {
    local o="$CASE_DIR/out" l
    python3 tools/lsbstats.py "$LADO" Ejemplo/ladoLSBI.bmp > "$o" || fail_msg "exit $?" || return 1
    for l in 'bytes R 307200 307200' \
             'lsb1_count B 168177 172824' \
             'lsb1_count G 167170 172269' \
             'lsb1_count R 168582 168582' \
             'chi2_pov B 8475.17 3520.98' \
             'chi2_pov G 7592.63 3345.95' \
             'chi2_pov R 8606.07 8606.07' \
             'bytes PAD 0 0' \
             'lsb1_count ALL 503929 513675'; do
        has_line "$o" "$l" || return 1
    done
}

case_stats_prefix_chi2_LSB1() {
    local o="$CASE_DIR/out" l
    python3 tools/lsbstats.py --prefix 359160 "$LADO" Ejemplo/ladoLSB1.bmp > "$o" || fail_msg "exit $?" || return 1
    for l in 'bytes B 119720 119720' \
             'chi2_pov B 8364.48 3107.61' \
             'chi2_pov G 7476.97 2943.28' \
             'chi2_pov R 8495.27 2862.38'; do
        has_line "$o" "$l" || return 1
    done
}

case_stats_csv() {
    local o="$CASE_DIR/out" n
    python3 tools/lsbstats.py --csv "$LADO" Ejemplo/ladoLSB1.bmp Ejemplo/ladoLSBI.bmp > "$o" || fail_msg "exit $?" || return 1
    n=$(wc -l < "$o")
    [ "$n" = 16 ] || fail_msg "expected 16 lines (header + 15 rows), got $n" || return 1
    head -n 1 "$o" | grep -q '^file,chan,bytes,lsb1_count' || fail_msg "bad csv header"
}

case_stats_hostile() { run_hostile lsbstats.py stats; }

run_case stats-side-by-side-LSBI case_stats_side_by_side_LSBI
run_case stats-prefix-chi2-LSB1 case_stats_prefix_chi2_LSB1
run_case stats-csv case_stats_csv
run_case stats-hostile case_stats_hostile

# ---------------------------------------------------------------- lsbi

case_lsbi_probe_plain() {
    local o="$CASE_DIR/out" l
    python3 tools/lsbi.py probe "$LADO" Ejemplo/ladoLSBI.bmp > "$o" || fail_msg "exit $?" || return 1
    for l in 'capacity=76799' 'flags=1111' 'size=44886' 'framing=plain ext=.png' \
             'counts pattern=00 changed=32367 unchanged=32028 invert=1' \
             'counts pattern=01 changed=32650 unchanged=32263 invert=1' \
             'counts pattern=10 changed=35119 unchanged=34980 invert=1' \
             'counts pattern=11 changed=88172 unchanged=71581 invert=1' \
             'recomputed_flags=1111 match=yes' 'reembed_identical=yes'; do
        has_line "$o" "$l" || return 1
    done
}

case_lsbi_probe_aes256ofb() {
    local o="$CASE_DIR/out" l
    python3 tools/lsbi.py probe "$LADO" Ejemplo/ladoLSBIaes256ofb.bmp > "$o" || fail_msg "exit $?" || return 1
    for l in 'flags=0001' 'size=44895' 'framing=cipher ext=-' \
             'recomputed_flags=0001 match=yes' 'reembed_identical=yes'; do
        has_line "$o" "$l" || return 1
    done
}

case_lsbi_probe_descfb() {
    local o="$CASE_DIR/out" l
    python3 tools/lsbi.py probe "$LADO" Ejemplo/ladoLSBIdescfb.bmp > "$o" || fail_msg "exit $?" || return 1
    for l in 'flags=1000' 'size=44895' 'framing=cipher ext=-' \
             'recomputed_flags=1000 match=yes' 'reembed_identical=yes'; do
        has_line "$o" "$l" || return 1
    done
}

case_lsbi_hyp_use_red() {
    local o="$CASE_DIR/out"
    python3 tools/lsbi.py probe --use-red "$LADO" Ejemplo/ladoLSBI.bmp > "$o" || fail_msg "exit $?" || return 1
    has_line "$o" 'size=658' || return 1
    has_line "$o" 'reembed_identical=no'
}

case_lsbi_hyp_red_relative() {
    local o="$CASE_DIR/out"
    python3 tools/lsbi.py probe --red-relative "$LADO" Ejemplo/ladoLSBI.bmp > "$o" || fail_msg "exit $?" || return 1
    has_line "$o" 'size=109078' || return 1
    has_line "$o" 'framing=invalid ext=-' || return 1
    has_line "$o" 'reembed_identical=no'
}

case_lsbi_hyp_flag_order() {
    local o="$CASE_DIR/out"
    python3 tools/lsbi.py probe --flag-order reversed "$LADO" Ejemplo/ladoLSBIaes256ofb.bmp > "$o" || fail_msg "exit $?" || return 1
    has_line "$o" 'size=4294922424' || return 1
    has_line "$o" 'framing=invalid ext=-' || return 1
    has_line "$o" 'reembed_identical=no'
}

case_lsbi_hyp_undecidable() {
    local v h o
    for v in LSBI LSBIaes256ofb LSBIdescfb; do
        for h in '--tie invert' '--pattern-bits 12'; do
            o="$CASE_DIR/$v.out"
            # shellcheck disable=SC2086
            python3 tools/lsbi.py probe $h "$LADO" "Ejemplo/lado$v.bmp" > "$o" || fail_msg "$v $h: exit $?" || return 1
            has_line "$o" 'reembed_identical=yes' || fail_msg "$v $h: not identical" || return 1
        done
    done
}

# Research switches: alternative readings that the vectors do refute.
case_lsbi_hyp_research() {
    local o="$CASE_DIR/out" v
    python3 tools/lsbi.py probe --bit-order lsb "$LADO" Ejemplo/ladoLSBI.bmp > "$o" || fail_msg "exit $?" || return 1
    has_line "$o" 'size=62826' || return 1
    has_line "$o" 'framing=cipher ext=-' || return 1
    for v in LSBI LSBIaes256ofb LSBIdescfb; do
        python3 tools/lsbi.py probe --count-red "$LADO" "Ejemplo/lado$v.bmp" > "$o" || fail_msg "exit $?" || return 1
        has_line "$o" 'recomputed_flags=0000 match=no' || return 1
        has_line "$o" 'reembed_identical=no' || return 1
        python3 tools/lsbi.py probe --flag-zero-inverts "$LADO" "Ejemplo/lado$v.bmp" > "$o" || fail_msg "exit $?" || return 1
        has_line "$o" 'framing=invalid ext=-' || return 1
        has_line "$o" 'reembed_identical=no' || return 1
    done
}

case_lsbi_extract_raw() {
    local out="$CASE_DIR/png.bin" n
    python3 tools/lsbi.py extract-raw --body-only Ejemplo/ladoLSBI.bmp "$out" || fail_msg "exit $?" || return 1
    n=$(stat -c %s "$out")
    [ "$n" = 44886 ] || fail_msg "expected 44886 bytes, got $n" || return 1
    [ "$(sha256sum "$out" | cut -d' ' -f1)" = "$PNG_SHA256" ] || fail_msg "wrong sha256"
}

case_lsbi_embed_file_roundtrip() {
    local d="$CASE_DIR" o="$CASE_DIR/out"
    printf 'line one\nline two\n\ttabbed line three\n' > "$d/note.txt"
    python3 tools/lsbi.py embed-file "$LADO" "$d/note.txt" "$d/stego.bmp" || fail_msg "embed exit $?" || return 1
    cmp -n 54 "$LADO" "$d/stego.bmp" || fail_msg "header changed" || return 1
    python3 tools/lsbi.py probe "$LADO" "$d/stego.bmp" > "$o" || fail_msg "probe exit $?" || return 1
    has_line "$o" 'framing=plain ext=.txt' || return 1
    has_line "$o" 'reembed_identical=yes' || return 1
    python3 tools/lsbi.py extract-raw --body-only "$d/stego.bmp" "$d/back.txt" || fail_msg "extract exit $?" || return 1
    cmp "$d/note.txt" "$d/back.txt" || fail_msg "roundtrip differs"
}

case_lsbi_capacity() {
    local d="$CASE_DIR"
    head -c 76799 /dev/urandom > "$d/max.bin"
    head -c 76800 /dev/urandom > "$d/over.bin"
    python3 tools/lsbi.py embed-raw "$LADO" "$d/max.bin" "$d/max.bmp" || fail_msg "embed at capacity failed" || return 1
    python3 tools/lsbi.py embed-raw "$LADO" "$d/over.bin" "$d/over.bmp" 2> "$d/err"
    [ $? -eq 1 ] || fail_msg "over capacity should exit 1" || return 1
    grep -q '^lsbi.py: error: .*76799' "$d/err" || fail_msg "capacity not reported" || return 1
    [ ! -e "$d/over.bmp" ] || fail_msg "output created for an oversize payload"
}

case_lsbi_refuse_overwrite() {
    local d="$CASE_DIR" before rc
    cp "$LADO" "$d/copy.bmp"
    before=$(sha256sum "$d/copy.bmp" | cut -d' ' -f1)
    printf 'hello\n' > "$d/in.txt"
    python3 tools/lsbi.py embed-file "$d/copy.bmp" "$d/in.txt" "$d/copy.bmp" 2> "$d/err"; rc=$?
    [ "$rc" = 1 ] || fail_msg "expected exit 1, got $rc" || return 1
    grep -q '^lsbi.py: error:' "$d/err" || fail_msg "no error line" || return 1
    [ "$(sha256sum "$d/copy.bmp" | cut -d' ' -f1)" = "$before" ] || fail_msg "input was modified"
}

case_lsbi_hostile() {
    local d="$CASE_DIR" rc
    printf 'plain text, not a bitmap\n' > "$d/t.txt"
    python3 tools/lsbi.py probe "$d/t.txt" "$LADO" > "$d/o" 2> "$d/e"; rc=$?
    [ "$rc" = 1 ] || fail_msg "expected exit 1, got $rc" || return 1
    grep -q '^lsbi.py: error:' "$d/e" || fail_msg "no error line" || return 1
    run_hostile lsbi.py probe
}

run_case lsbi-probe-plain case_lsbi_probe_plain
run_case lsbi-probe-aes256ofb case_lsbi_probe_aes256ofb
run_case lsbi-probe-descfb case_lsbi_probe_descfb
run_case lsbi-hyp-use-red case_lsbi_hyp_use_red
run_case lsbi-hyp-red-relative case_lsbi_hyp_red_relative
run_case lsbi-hyp-flag-order case_lsbi_hyp_flag_order
run_case lsbi-hyp-undecidable case_lsbi_hyp_undecidable
run_case lsbi-hyp-research case_lsbi_hyp_research
run_case lsbi-extract-raw case_lsbi_extract_raw
run_case lsbi-embed-file-roundtrip case_lsbi_embed_file_roundtrip
run_case lsbi-capacity case_lsbi_capacity
run_case lsbi-refuse-overwrite case_lsbi_refuse_overwrite
run_case lsbi-hostile case_lsbi_hostile

# ---------------------------------------------------------------- sigsearch

# make_sig_fixture DIR: DIR/{png,jpg,zip,pdf}.bin and DIR/t.bmp = lado.bmp + the four parts.
make_sig_fixture() {
    local d=$1
    python3 tools/lsbi.py extract-raw --body-only Ejemplo/ladoLSBI.bmp "$d/png.bin" || return 1
    printf '\xff\xd8\xff\xe0\x00\x10JFIF\x00\x01\x01\x00\x00\x01\x00\x01\x00\x00\xff\xd9' > "$d/jpg.bin"
    python3 -c "
import sys, zipfile
z = zipfile.ZipFile(sys.argv[1], 'w', zipfile.ZIP_STORED)
z.writestr('note.txt', 'hidden note\n')
z.close()
" "$d/zip.bin" || return 1
    printf '%%PDF-1.4\n1 0 obj\n<< >>\nendobj\ntrailer\n<< >>\n%%%%EOF\n' > "$d/pdf.bin"
    cat "$LADO" "$d/png.bin" "$d/jpg.bin" "$d/zip.bin" "$d/pdf.bin" > "$d/t.bmp"
}

case_sig_appended_bmp() {
    local d="$CASE_DIR" o="$CASE_DIR/out" sp sj sz sf pe=921654 total n
    make_sig_fixture "$d" || fail_msg "fixture build failed" || return 1
    sp=$(stat -c %s "$d/png.bin"); sj=$(stat -c %s "$d/jpg.bin")
    sz=$(stat -c %s "$d/zip.bin"); sf=$(stat -c %s "$d/pdf.bin")
    total=$((sp + sj + sz + sf))
    python3 tools/sigsearch.py "$d/t.bmp" > "$o" || fail_msg "exit $?" || return 1
    has_line "$o" "container type=BMP pixel_offset=54 pixel_end=921654 declared_size=921654 appended=$total truncated=no" || return 1
    grep -q "^hit offset=$pe region=appended type=PNG strength=strong magic=89504e470d0a1a0a" "$o" \
        || fail_msg "PNG hit missing" || return 1
    grep -q "^hit offset=$((pe + sp)) region=appended type=JPEG strength=strong" "$o" \
        || fail_msg "JPEG hit missing" || return 1
    grep -q "^hit offset=$((pe + sp + sj)) region=appended type=ZIP strength=strong" "$o" \
        || fail_msg "ZIP hit missing" || return 1
    grep -q "^hit offset=$((pe + sp + sj + sz)) region=appended type=PDF strength=strong" "$o" \
        || fail_msg "PDF hit missing" || return 1
    n=$(sed -n 's/^summary .*appended_region_hits=\([0-9]*\)$/\1/p' "$o")
    [ "${n:-0}" -ge 4 ] || fail_msg "appended_region_hits=$n, expected >= 4"
}

case_sig_ejemplo_clean() {
    local f o
    for f in Ejemplo/*.bmp; do
        o="$CASE_DIR/$(basename "$f").out"
        python3 tools/sigsearch.py "$f" > "$o" || fail_msg "$f: exit $?" || return 1
        grep -q ' appended=0 ' "$o" || fail_msg "$f: appended != 0" || return 1
        if grep -qE '^hit .*type=(PNG|JPEG|GIF|PDF|ZIP) ' "$o"; then
            fail_msg "$f: false positive"; return 1
        fi
    done
}

case_sig_offset_in_data() {
    local d="$CASE_DIR" o="$CASE_DIR/out"
    python3 tools/lsbi.py extract-raw --body-only Ejemplo/ladoLSBI.bmp "$d/png.bin" || fail_msg "extract failed" || return 1
    { head -c 1000 /dev/zero; cat "$d/png.bin"; } > "$d/blob.bin"
    python3 tools/sigsearch.py "$d/blob.bin" > "$o" || fail_msg "exit $?" || return 1
    has_line "$o" 'container type=none' || return 1
    grep -q '^hit offset=1000 region=file type=PNG' "$o" || fail_msg "no hit at 1000" || return 1
    python3 tools/sigsearch.py "$d/png.bin" > "$o" || fail_msg "exit $?" || return 1
    grep -q '^hit offset=0 region=file type=PNG' "$o" || fail_msg "no hit at 0"
}

case_sig_all_weak() {
    local o="$CASE_DIR/out" n
    python3 tools/sigsearch.py "$LADO" > "$o" || fail_msg "exit $?" || return 1
    if grep -qE '^hit .*type=(MZ|BMP) ' "$o"; then fail_msg "weak hits shown by default"; return 1; fi
    python3 tools/sigsearch.py --all "$LADO" > "$o" || fail_msg "exit $?" || return 1
    n=$(grep -c "^hit .*type=MZ " "$o"); [ "$n" = 41 ] || fail_msg "MZ count $n, expected 41" || return 1
    n=$(grep -c "^hit .*type=BMP " "$o"); [ "$n" = 62 ] || fail_msg "BMP count $n, expected 62"
}

case_sig_dump() {
    local d="$CASE_DIR" before rc
    make_sig_fixture "$d" || fail_msg "fixture build failed" || return 1
    cat "$d/png.bin" "$d/jpg.bin" "$d/zip.bin" "$d/pdf.bin" > "$d/parts.bin"
    python3 tools/sigsearch.py --dump appended "$d/a.out" "$d/t.bmp" > "$d/o1" || fail_msg "dump appended: exit $?" || return 1
    cmp "$d/parts.bin" "$d/a.out" || fail_msg "--dump appended differs" || return 1
    python3 tools/sigsearch.py --dump 921654 "$d/n.out" "$d/t.bmp" > "$d/o2" || fail_msg "dump offset: exit $?" || return 1
    cmp "$d/parts.bin" "$d/n.out" || fail_msg "--dump 921654 differs" || return 1
    grep -q "^dumped offset=921654 bytes=$(stat -c %s "$d/parts.bin") " "$d/o2" || fail_msg "no dumped line" || return 1
    before=$(sha256sum "$d/t.bmp" | cut -d' ' -f1)
    python3 tools/sigsearch.py --dump appended "$d/t.bmp" "$d/t.bmp" > "$d/o3" 2> "$d/e3"; rc=$?
    [ "$rc" = 1 ] || fail_msg "self-overwrite exit $rc, expected 1" || return 1
    [ "$(sha256sum "$d/t.bmp" | cut -d' ' -f1)" = "$before" ] || fail_msg "input modified" || return 1
    python3 tools/sigsearch.py --dump 99999999 "$d/x.out" "$d/t.bmp" > "$d/o4" 2> "$d/e4"; rc=$?
    [ "$rc" = 1 ] || fail_msg "offset beyond EOF exit $rc, expected 1" || return 1
    [ ! -e "$d/x.out" ] || fail_msg "x.out created"
}

case_sig_hostile() {
    local d="$CASE_DIR" rc big
    python3 tools/sigsearch.py "$d/does-not-exist" > "$d/o" 2> "$d/e"; rc=$?
    [ "$rc" = 1 ] || fail_msg "missing file exit $rc" || return 1
    head -n 1 "$d/e" | grep -q '^sigsearch.py: error:' || fail_msg "bad error line" || return 1
    make_hostile "$d"
    python3 tools/sigsearch.py "$d/empty.bin" > "$d/o" 2> "$d/e"; rc=$?
    [ "$rc" = 0 ] || fail_msg "empty exit $rc" || return 1
    has_line "$d/o" 'container type=none' || return 1
    has_line "$d/o" 'summary hits=0 strong=0 weak=0 appended_region_hits=0' || return 1
    python3 tools/sigsearch.py "$d/short.bmp" > "$d/o" 2> "$d/e"; rc=$?
    [ "$rc" = 0 ] || fail_msg "short exit $rc" || return 1
    has_line "$d/o" 'container type=none' || return 1
    python3 tools/sigsearch.py "$d/hugewidth.bmp" > "$d/o" 2> "$d/e"; rc=$?
    [ "$rc" = 0 ] || fail_msg "hugewidth exit $rc" || return 1
    grep -q ' truncated=yes$' "$d/o" || fail_msg "truncated=yes missing" || return 1
    python3 tools/sigsearch.py "$d/text.txt" > "$d/o" 2> "$d/e"; rc=$?
    [ "$rc" = 0 ] || fail_msg "text exit $rc" || return 1
    big=$(mktemp -d /tmp/sigsearch-big.XXXXXX) || fail_msg "mktemp failed" || return 1
    truncate -s 1100M "$big/big.bin"
    python3 tools/sigsearch.py "$big/big.bin" > "$d/o" 2> "$d/e"; rc=$?
    rm -rf "$big"
    [ "$rc" = 1 ] || fail_msg "1100 MiB file exit $rc, expected 1" || return 1
    head -n 1 "$d/e" | grep -q '^sigsearch.py: error:' || fail_msg "bad size error line"
}

run_case sig-appended-bmp case_sig_appended_bmp
run_case sig-ejemplo-clean case_sig_ejemplo_clean
run_case sig-offset-in-data case_sig_offset_in_data
run_case sig-all-weak case_sig_all_weak
run_case sig-dump case_sig_dump
run_case sig-hostile case_sig_hostile

# <<< new cases are inserted above this line; tools-inputs-unmodified stays last >>>

case_tools_inputs_unmodified() {
    sha256sum -c --quiet "$T/ejemplo.sha256" || fail_msg "an Ejemplo input changed"
}
run_case tools-inputs-unmodified case_tools_inputs_unmodified

if [ "$ran" -eq 0 ]; then
    echo "no test case matches filter '$FILTER'"
    exit 2
fi
echo "SUMMARY: $passed passed, $failed failed"
[ "$failed" -eq 0 ]
