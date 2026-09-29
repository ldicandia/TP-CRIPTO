#!/usr/bin/env bash
# Compila informe.tex con pdflatex en un directorio privado y reemplaza informe.pdf de forma atómica.
# Uso: bash informe/build.sh      (normalmente lo invoca `make report`)
# Salida: "PASS build: informe/informe.pdf (N páginas)" o "FAIL build: ..." con código 1.
set -eu
cd "$(dirname "$0")"

if ! command -v pdflatex >/dev/null 2>&1; then
    echo "FAIL build: falta pdflatex (instalar con: sudo apt install texlive-latex-extra texlive-fonts-recommended)" >&2
    exit 1
fi
if [ ! -f generado/datos.tex ]; then
    echo "FAIL build: falta generado/datos.tex: ejecutar make report" >&2
    exit 1
fi

# Directorio de compilación propio de esta ejecución: dos compilaciones en paralelo no se pisan y una
# interrupción no deja basura (trap) ni un PDF a medio escribir (mv -f dentro del mismo directorio).
DIR=$(mktemp -d .compilacion-XXXXXX)
cleanup() { rm -rf "$DIR"; }
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

fail_build() {
    if [ -f "$DIR/informe.log" ]; then
        cp -f "$DIR/informe.log" informe-error.log
    else
        cp -f "$DIR/salida.txt" informe-error.log
    fi
    echo "FAIL build: pdflatex (ver informe/informe-error.log)"
    grep -E '^!|^\./.*:[0-9]+:' informe-error.log | head -20 || true
    exit 1
}

pasada=0
while :; do
    pasada=$((pasada + 1))
    if ! pdflatex -interaction=nonstopmode -halt-on-error -file-line-error -no-shell-escape \
            -output-directory="$DIR" informe.tex >"$DIR/salida.txt" 2>&1; then
        fail_build
    fi
    [ "$pasada" -ge 4 ] && break
    if [ "$pasada" -ge 2 ] && ! grep -Eq 'Rerun to get|Label\(s\) may have changed' "$DIR/informe.log"; then
        break
    fi
done

if grep -Eq 'LaTeX Warning: Reference .* undefined|LaTeX Warning: Citation .* undefined|There were undefined references|Missing character: There is no' "$DIR/informe.log"; then
    echo "FAIL build: referencias o caracteres sin resolver"
    cp -f "$DIR/informe.log" informe-error.log
    grep -E 'undefined|Missing character' informe-error.log | head -20 || true
    exit 1
fi

paginas=$(tr -d '\n' <"$DIR/informe.log" | grep -o 'Output written on [^)]*)' | tail -1 | sed -n 's/.*(\([0-9][0-9]*\) page.*/\1/p')
mv -f "$DIR/informe.log" informe.log
mv -f "$DIR/informe.pdf" informe.pdf
rm -f informe-error.log
echo "PASS build: informe/informe.pdf (${paginas:-?} páginas)"

# El validador falla el build si falta estructura, hay cifras a mano o el PDF no contiene lo medido.
python3 scripts/check_informe.py
