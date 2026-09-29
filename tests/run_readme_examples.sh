#!/usr/bin/env bash
# Builds a clean copy of the deliverable files and runs the README's own build and example lines.
# Same as tests/check_readme.sh, but keeps the generated salida_* files in ./runs (repo root).
# Usage: bash tests/run_readme_examples.sh [README_PATH]   (needs only bash, coreutils, make, gcc)
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd) || exit 1
cd "$ROOT" || exit 1

README=${1:-README.md}
MIN_EXAMPLES=10
PNG_SHA256=b93be15382f35f099ca286241dd7bb6e681d5bce8d315ac0b6240f0b516f549d

TMP=$(mktemp -d) || { echo "FAIL check_readme: cannot create temp directory"; exit 1; }
RUNS="$ROOT/runs"

# Copy the generated outputs to ./runs (also on failure), then drop the temp directory.
save_outputs() {
    mkdir -p "$RUNS" || return
    rm -f "$RUNS"/salida_*
    for f in "$TMP"/salida_*; do
        [ -e "$f" ] || continue
        cp "$f" "$RUNS/"
    done
    echo "outputs saved in $RUNS"
    rm -rf "$TMP"
}
trap save_outputs EXIT

fail() {
    echo "FAIL check_readme: $*"
    exit 1
}

[ -f "$README" ] || fail "README not found: $README"

# block_lines MARKER: lines of the first fenced block after the marker, minus blanks and # comments.
block_lines() {
    local marker=$1
    grep -qF -- "<!-- check_readme:$marker -->" "$README" || return 2
    awk -v m="<!-- check_readme:$marker -->" '
        state == 0 && index($0, m) { state = 1; next }
        state == 1 && /^```/ { state = 2; next }
        state == 2 && /^```/ { exit }
        state == 2 {
            line = $0
            sub(/\r$/, "", line)
            if (line ~ /^[[:space:]]*$/ || line ~ /^[[:space:]]*#/) next
            print line
        }
    ' "$README"
}

INSTALL=$(block_lines install); rc=$?
[ "$rc" -ne 2 ] || fail "missing marker check_readme:install"
[ -n "$INSTALL" ] || fail "empty install block"
BUILD=$(block_lines build); rc=$?
[ "$rc" -ne 2 ] || fail "missing marker check_readme:build"
[ -n "$BUILD" ] || fail "empty build block"
EXAMPLES=$(block_lines examples); rc=$?
[ "$rc" -ne 2 ] || fail "missing marker check_readme:examples"
[ -n "$EXAMPLES" ] || fail "empty examples block"

# Install block: never executed, only checked.
for pkg in gcc make libssl-dev; do
    printf '%s\n' "$INSTALL" | grep -qw -- "$pkg" || fail "install block does not mention $pkg"
done
if command -v dpkg-query >/dev/null 2>&1; then
    for pkg in gcc make libssl-dev; do
        dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q 'install ok installed' \
            || fail "package $pkg is not installed"
    done
else
    echo "check_readme: note: dpkg-query not available, package check skipped"
fi

# Clean copy of the deliverable files only.
cp Makefile "$TMP/Makefile" || fail "cannot copy Makefile"
cp "$README" "$TMP/README.md" || fail "cannot copy README"
cp -r src "$TMP/src" || fail "cannot copy src"
cp -r include "$TMP/include" || fail "cannot copy include"
cp -r Ejemplo "$TMP/Ejemplo" || fail "cannot copy Ejemplo"

clean_run() {
    (cd "$TMP" && env -i PATH=/usr/local/bin:/usr/bin:/bin HOME="$TMP" LC_ALL=C bash -c "$1")
}

# Build block.
: > "$TMP/.build.log"
while IFS= read -r line; do
    [[ "$line" =~ ^make( |$) ]] || fail "unexpected build command: $line"
    clean_run "$line" >> "$TMP/.build.log" 2>&1 || {
        tail -n 20 "$TMP/.build.log"
        fail "build command failed: $line"
    }
done <<< "$BUILD"
if grep -E 'warning:|error:' "$TMP/.build.log" >/dev/null; then
    grep -E 'warning:|error:' "$TMP/.build.log" | head -n 5
    fail "build output contains warnings or errors"
fi
[ -x "$TMP/stegobmp" ] || fail "build did not produce ./stegobmp"

# Examples block.
count=0
while IFS= read -r line; do
    [[ "$line" == "./stegobmp "* ]] || fail "unexpected example command: $line"
    clean_run "$line" > "$TMP/.example.log" 2>&1 || {
        tail -n 5 "$TMP/.example.log"
        fail "example failed: $line"
    }
    count=$((count + 1))
done <<< "$EXAMPLES"
[ "$count" -ge "$MIN_EXAMPLES" ] || fail "only $count examples, need at least $MIN_EXAMPLES"
for needle in -embed -extract -pass; do
    printf '%s\n' "$EXAMPLES" | grep -qF -- "$needle" || fail "no example uses $needle"
done
if [ -f "$TMP/salida_defaults.bmp" ]; then
    cmp -s "$TMP/salida_defaults.bmp" "$TMP/Ejemplo/ladoLSB1aes128cbc.bmp" \
        || fail "salida_defaults.bmp differs from Ejemplo/ladoLSB1aes128cbc.bmp"
fi

# Usage lines printed by the fresh binary must appear verbatim in the README.
(cd "$TMP" && env -i PATH=/usr/local/bin:/usr/bin:/bin HOME="$TMP" LC_ALL=C ./stegobmp) > /dev/null 2> "$TMP/.usage.log"
usage_lines=0
while IFS= read -r ul; do
    usage_lines=$((usage_lines + 1))
    grep -qF -- "$ul" "$README" || fail "usage line missing from README: $ul"
done < <(sed -n 's/^  \(stegobmp .*\)$/\1/p' "$TMP/.usage.log")
[ "$usage_lines" -eq 2 ] || fail "expected 2 usage lines from ./stegobmp, got $usage_lines"

# Dynamic dependencies (NEEDED, not ldd): exactly libcrypto and libc.
if command -v readelf >/dev/null 2>&1; then
    while IFS= read -r lib; do
        case "$lib" in
            libcrypto.so.*|libc.so.6) ;;
            *) fail "unexpected library dependency: $lib" ;;
        esac
    done < <(readelf -d "$TMP/stegobmp" | sed -n 's/.*(NEEDED).*\[\(.*\)\]/\1/p')
    readelf -d "$TMP/stegobmp" | grep -q '(NEEDED).*\[libcrypto\.so\.' || fail "libcrypto is not a dependency"
    readelf -d "$TMP/stegobmp" | grep -q '(NEEDED).*\[libc\.so\.6\]' || fail "libc.so.6 is not a dependency"
else
    echo "check_readme: note: readelf not available, dependency check skipped"
fi

pngs=0
for f in "$TMP"/salida_*.png; do
    [ -e "$f" ] || continue
    pngs=$((pngs + 1))
    got=$(sha256sum "$f" | cut -d' ' -f1)
    [ "$got" = "$PNG_SHA256" ] || fail "$(basename "$f") has sha256 $got"
done
[ "$pngs" -ge 1 ] || fail "examples produced no salida_*.png"

echo "PASS check_readme: $count examples"
exit 0
