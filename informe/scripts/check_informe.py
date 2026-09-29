#!/usr/bin/env python3
"""check_informe: valida informe.pdf y las fuentes LaTeX del informe.

Uso: python3 informe/scripts/check_informe.py [--pdf PDF] [--respondidas I,II,...]
                                              [--max-overfull-pt N] [--fase4]

Siempre: el PDF existe y empieza con %PDF-; los diez encabezados "Cuestión I:" ... "Cuestión X:" aparecen
al menos dos veces (índice y cuerpo); la frase de "pendiente" aparece exactamente 4 veces (Cuestiones
III a VI, Fase 5); no hay "??" en el texto; cada cifra de generado/esperado-en-pdf.txt aparece en el PDF;
y las secciones q02-comparacion.tex y q07-mejora-lsbi.tex no contienen cifras medidas escritas a mano
(deben venir de \\dato o de las tablas generadas).
--respondidas: exige el cuerpo de cada cuestión listada (sin \\pendienteEstegoanalisis, con un mínimo
de palabras de prosa). --max-overfull-pt: tope para los "Overfull \\hbox" de informe.log.
--fase4: --respondidas I,II,VII,VIII,IX,X --max-overfull-pt 10 y sin entradas de bibliografía sin citar.

Salida: "PASS check_informe: <resumen>" (código 0) o una línea "FAIL check_informe: <motivo>" por
problema (código 1). Resuelve todas las rutas desde la raíz del repositorio (no depende del cwd).
"""
import sys
sys.dont_write_bytecode = True
import argparse
import os
import re
import subprocess

HERE = os.path.dirname(os.path.abspath(__file__))
INF = os.path.dirname(HERE)
SEC = os.path.join(INF, 'secciones')
GEN = os.path.join(INF, 'generado')

ROMANOS = ['I', 'II', 'III', 'IV', 'V', 'VI', 'VII', 'VIII', 'IX', 'X']
PENDIENTE = 'Pendiente: esta cuestión requiere los archivos de estegoanálisis de la cátedra'
MINIMOS = {'I': ('q01-paper', 1500), 'II': ('q02-comparacion', 700), 'VII': ('q07-mejora-lsbi', 600),
           'VIII': ('q08-registro-patrones', 500), 'IX': ('q09-dificultades', 1000), 'X': ('q10-mejoras', 500)}
MEDIDAS = ['q02-comparacion.tex', 'q07-mejora-lsbi.tex']

fallas = []


def falla(msg):
    fallas.append(msg)


def leer(path):
    with open(path, 'rb') as f:
        return f.read().decode('utf-8', 'replace')


def texto_pdf(pdf):
    try:
        p = subprocess.Popen(['mutool', 'draw', '-F', 'txt', '-o', '-', pdf],
                             stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        out, _err = p.communicate()
    except OSError:
        falla('no se pudo ejecutar mutool (instalar el paquete mupdf-tools)')
        return None
    if p.returncode != 0:
        falla('mutool no pudo leer %s' % pdf)
        return None
    return out.decode('utf-8', 'replace')


def sin_comentarios(tex):
    return '\n'.join(re.sub(r'(?<!\\)%.*', '', l) for l in tex.split('\n'))


def borrar(pat, tex, flags=0):
    """Elimina las coincidencias conservando los saltos de línea (para informar números de línea)."""
    return re.sub(pat, lambda m: '\n' * m.group(0).count('\n'), tex, flags=flags)


def palabras_de_prosa(tex):
    tex = sin_comentarios(tex)
    for env in ('enunciado', 'tabular', 'tabularx', 'tabular\\*', 'lstlisting', 'equation', 'align', 'align\\*'):
        tex = re.sub(r'\\begin\{%s\}.*?\\end\{%s\}' % (env, env), ' ', tex, flags=re.S)
    tex = re.sub(r'\$\$.*?\$\$|\$[^$]*\$|\\\[.*?\\\]|\\\(.*?\\\)', ' ', tex, flags=re.S)
    tex = re.sub(r'\\(?:label|ref|eqref|pageref|cite|input|includegraphics|url|href|dato)(?:\[[^\]]*\])?\{[^}]*\}', ' ', tex)
    tex = re.sub(r'\\hyperref\[[^\]]*\]', ' ', tex)
    tex = re.sub(r'\\(?:begin|end)\{[^}]*\}(?:\[[^\]]*\])?', ' ', tex)
    tex = re.sub(r'\\[A-Za-z]+\*?', ' ', tex)
    tex = re.sub(r'[{}\[\]\\&~]', ' ', tex)
    return sum(1 for t in tex.split() if re.search(r'[^\W\d_]', t))


def cifras_a_mano(nombre):
    """Lista (línea, texto) de cifras medidas escritas a mano en una sección."""
    ruta = os.path.join(SEC, nombre)
    if not os.path.isfile(ruta):
        return []
    tex = sin_comentarios(leer(ruta))
    tex = borrar(r'\\begin\{lstlisting\}.*?\\end\{lstlisting\}', tex, re.S)
    tex = borrar(r'\\definirdato\{[^}]*\}\{[^}]*\}', tex)
    tex = borrar(r'\\(?:dato|cite|label|ref|eqref|pageref|input|includegraphics|url|href)(?:\[[^\]]*\])?\{[^}]*\}', tex)
    tex = borrar(r'\\hyperref\[[^\]]*\]', tex)
    tex = borrar(r'\d*\.?\d+\s*\\(?:linewidth|textwidth|columnwidth)', tex)
    malas = []
    for n, linea in enumerate(tex.split('\n'), 1):
        for m in re.finditer(r'\d{5,}|\d+[.,]\d{2,}', linea):
            malas.append((n, m.group(0)))
    return malas


def cuerpos_faltantes():
    ruta = os.path.join(INF, 'informe.tex')
    if not os.path.isfile(ruta):
        return []
    nombres = re.findall(r'^\\respuesta\{([^}]*)\}', sin_comentarios(leer(ruta)), re.M)
    return [n for n in nombres if not os.path.isfile(os.path.join(SEC, n + '.tex'))]


def main():
    ap = argparse.ArgumentParser(prog='check_informe.py', description='Valida informe.pdf y sus fuentes.')
    ap.add_argument('--pdf', default=os.path.join(INF, 'informe.pdf'))
    ap.add_argument('--respondidas', default='')
    ap.add_argument('--max-overfull-pt', type=float, default=None)
    ap.add_argument('--fase4', action='store_true')
    a = ap.parse_args()
    respondidas = [r.strip() for r in a.respondidas.split(',') if r.strip()]
    maxof = a.max_overfull_pt
    if a.fase4:
        respondidas = ['I', 'II', 'VII', 'VIII', 'IX', 'X']
        maxof = 10.0 if maxof is None else maxof

    resumen = []
    pdf = a.pdf
    texto = None
    if not os.path.isfile(pdf):
        falla('no existe %s' % pdf)
    else:
        with open(pdf, 'rb') as f:
            cabecera = f.read(5)
        if cabecera != b'%PDF-':
            falla('%s no empieza con %%PDF-' % pdf)
        else:
            texto = texto_pdf(pdf)

    if texto is not None:
        plano = re.sub(r'\s+', ' ', texto)
        sinesp = re.sub(r'\s+', '', texto)
        for r in ROMANOS:
            n = len(re.findall(r'Cuestión %s:' % r, plano))
            if n < 2:
                falla('el encabezado "Cuestión %s:" aparece %d vez/veces en el PDF (se esperan al menos 2: índice y cuerpo)' % (r, n))
        n = plano.count(PENDIENTE)
        if n != 4:
            falla('la nota de pendiente aparece %d veces en el PDF (se esperan exactamente 4: Cuestiones III a VI)' % n)
        if '??' in texto:
            falla('el PDF contiene "??" (referencia sin resolver)')
        esp = os.path.join(GEN, 'esperado-en-pdf.txt')
        if not os.path.isfile(esp):
            falla('falta generado/esperado-en-pdf.txt (ejecutar medir_q2.py)')
        else:
            cifras = [l.strip() for l in leer(esp).split('\n') if l.strip()]
            for c in cifras:
                if c not in sinesp:
                    falla('la cifra medida %s no aparece en el PDF' % c)
            resumen.append('%d cifras medidas presentes' % len(cifras))

    for nombre in MEDIDAS:
        for n, tok in cifras_a_mano(nombre):
            falla('%s:%d cifra medida escrita a mano (%s): usar \\dato o una tabla generada' % (nombre, n, tok))

    for r in respondidas:
        if r not in MINIMOS:
            falla('la Cuestión %s no tiene cuerpo propio (no está en la lista de respondibles)' % r)
            continue
        nombre, minimo = MINIMOS[r]
        ruta = os.path.join(SEC, nombre + '.tex')
        if not os.path.isfile(ruta):
            falla('Cuestión %s: falta secciones/%s.tex' % (r, nombre))
            continue
        tex = leer(ruta)
        if '\\pendienteEstegoanalisis' in sin_comentarios(tex):
            falla('Cuestión %s: %s.tex contiene \\pendienteEstegoanalisis' % (r, nombre))
        n = palabras_de_prosa(tex)
        if n < minimo:
            falla('Cuestión %s: %s.tex tiene %d palabras de prosa (mínimo %d)' % (r, nombre, n, minimo))
        else:
            resumen.append('%s %d palabras' % (r, n))

    if maxof is not None:
        log = os.path.join(INF, 'informe.log')
        if not os.path.isfile(log):
            falla('falta informe.log para medir los Overfull')
        else:
            peor = 0.0
            for m in re.finditer(r'Overfull \\hbox \(([\d.]+)pt too wide\)', leer(log)):
                peor = max(peor, float(m.group(1)))
            if peor > maxof:
                falla('hay un Overfull \\hbox de %.1fpt (máximo %.1fpt)' % (peor, maxof))
            else:
                resumen.append('overfull máx %.1fpt' % peor)

    if a.fase4:
        fuentes = [os.path.join(INF, 'informe.tex')]
        if os.path.isdir(SEC):
            fuentes += [os.path.join(SEC, f) for f in sorted(os.listdir(SEC)) if f.endswith('.tex')]
        citadas = set()
        for f in fuentes:
            for m in re.finditer(r'\\cite[pt]?(?:\[[^\]]*\])?\{([^}]*)\}', sin_comentarios(leer(f))):
                citadas.update(k.strip() for k in m.group(1).split(','))
        principal = sin_comentarios(leer(fuentes[0]))
        for k in re.findall(r'\\bibitem\{([^}]*)\}', principal):
            if k not in citadas:
                falla('la entrada de bibliografía %s no se cita en ninguna parte' % k)

    faltan = cuerpos_faltantes()
    if faltan:
        print('NOTA check_informe: todavía no existen los cuerpos: %s' % ', '.join(faltan))
    if fallas:
        for f in fallas:
            print('FAIL check_informe: %s' % f)
        return 1
    print('PASS check_informe: 10 encabezados, 4 pendientes%s' % (
        ''.join('; ' + r for r in resumen)))
    return 0


if __name__ == '__main__':
    try:
        sys.exit(main())
    except SystemExit:
        raise
    except Exception as e:  # nunca un traceback
        print('FAIL check_informe: error interno: %s: %s' % (type(e).__name__, e))
        sys.exit(1)
