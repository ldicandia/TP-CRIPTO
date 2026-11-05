#!/usr/bin/env python3
"""medir_estegoanalisis: reproduce el estegoanálisis de los 4 archivos de la cátedra (grupo 5).

Uso: python3 informe/scripts/medir_estegoanalisis.py [directorio]   (normalmente `make report`)
El directorio por defecto es "imagenes catedra/grupo5" (avatar.bmp, madrid.bmp, montevideo.bmp, secreto1.bmp).

Para cada BMP: lee la cabecera, prueba los tres métodos con ./stegobmp, mira el campo de tamaño de LSB1 y
LSB4 con una lectura independiente en Python, busca datos después del último píxel, y examina lo extraído
(PDF: texto de la página; PNG: chunks y datos después de IEND; ZIP: contenido). Escribe en informe/generado/:
datos-analisis.tex (macros \\definirdato), analisis-tabla-metodos.tex y analisis-tabla-archivos.tex.
Solo biblioteca estándar. Errores: "medir_estegoanalisis: error: <mensaje>" en stderr, código 1.
"""
import sys
sys.dont_write_bytecode = True
import io
import os
import re
import struct
import subprocess
import tempfile
import zipfile
import zlib

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
GEN = os.path.join(ROOT, 'informe', 'generado')
STEGO = os.path.join(ROOT, 'stegobmp')
DIR_DEFECTO = os.path.join(ROOT, 'imagenes catedra', 'grupo5')
ARCHIVOS = ['avatar', 'madrid', 'montevideo', 'secreto1']
METODOS = ['LSB1', 'LSB4', 'LSBI']
ALGS = ['aes128', 'aes192', 'aes256', '3des']
MODOS = ['ecb', 'cfb', 'ofb', 'cbc']
PASSWORD_PISTA = 'metadata'


class Error(Exception):
    pass


def tex_int(n):
    s = '{:,}'.format(n)
    return s.replace(',', '\\,')


def run(args):
    p = subprocess.Popen(args, stdout=subprocess.PIPE, stderr=subprocess.PIPE, cwd=ROOT)
    out, err = p.communicate()
    return p.returncode, out.decode('utf-8', 'replace'), err.decode('utf-8', 'replace')


def cabecera_bmp(datos):
    if len(datos) < 54 or datos[:2] != b'BM':
        raise Error('no es un BMP')
    cb, = struct.unpack_from('<I', datos, 2)
    off, = struct.unpack_from('<I', datos, 10)
    ancho, alto = struct.unpack_from('<ii', datos, 18)
    bpp, = struct.unpack_from('<H', datos, 28)
    size_img, = struct.unpack_from('<I', datos, 34)
    fila = (ancho * 3 + 3) // 4 * 4
    pix = fila * abs(alto)
    return dict(cbsize=cb, offset=off, ancho=ancho, alto=alto, bpp=bpp, size_img=size_img,
                pixeles=pix, agregados=len(datos) - (off + pix))


def tam_lsb(pix, k):
    """Campo de tamaño (32 bits big endian) de LSB1 (k=1) o LSB4 (k=4)."""
    n = 0
    for i in range(32 // k):
        n = (n << k) | (pix[i] & ((1 << k) - 1))
    return n


def texto_pdf(datos):
    """Texto de las cadenas TJ del contenido de la página (suficiente para un PDF de Word de una hoja)."""
    trozos = []
    for m in re.finditer(rb'stream\r?\n(.*?)endstream', datos, re.S):
        try:
            u = zlib.decompress(m.group(1))
        except zlib.error:
            continue
        for arr in re.findall(rb'\[(.*?)\]\s*TJ', u, re.S):
            trozos.append(b''.join(re.findall(rb'\(((?:\\.|[^\\)])*)\)', arr)))
    return b''.join(trozos).decode('latin-1').strip()


def chunks_png(datos):
    p, res = 8, []
    while p + 12 <= len(datos):
        n, t = struct.unpack_from('>I4s', datos, p)
        res.append((t.decode('latin-1'), n))
        p += 12 + n
        if t == b'IEND':
            break
    return res, p


def analizar(dirsal, base, d):
    """Resumen de lo extraído de un archivo; claves para \\definirdato."""
    r = {}
    for nombre in sorted(os.listdir(dirsal)):
        if not nombre.startswith(base + '.'):
            continue
        ruta = os.path.join(dirsal, nombre)
        with open(ruta, 'rb') as f:
            c = f.read()
        r['ext'] = nombre[len(base):]
        r['bytes'] = len(c)
        if c[:4] == b'%PDF':
            r['tipo'] = 'PDF'
            r['texto'] = texto_pdf(c)
        elif c[:8] == b'\x89PNG\r\n\x1a\n':
            r['tipo'] = 'PNG'
            ch, fin = chunks_png(c)
            r['ancho'], r['alto'] = struct.unpack_from('>II', c, 16)
            r['restantes'] = len(c) - fin
            r['png'] = c[:fin]
            if r['restantes']:
                r['restos_inicio'] = fin
                z = c[fin:]
                r['restos_firma'] = z[:4]
                try:
                    zf = zipfile.ZipFile(io.BytesIO(z))
                    r['zip'] = [(i.filename, i.file_size, zf.read(i.filename).decode('utf-8', 'replace'))
                                for i in zf.infolist()]
                except zipfile.BadZipFile:
                    r['zip'] = None
        else:
            r['tipo'] = '?'
        break
    return r


def medir(directorio):
    if not os.path.isfile(STEGO):
        raise Error('falta ./stegobmp (ejecutar make)')
    res = {}
    for base in ARCHIVOS:
        ruta = os.path.join(directorio, base + '.bmp')
        if not os.path.isfile(ruta):
            raise Error('falta %s' % ruta)
        with open(ruta, 'rb') as f:
            datos = f.read()
        h = cabecera_bmp(datos)
        pix = datos[h['offset']:h['offset'] + h['pixeles']]
        info = dict(h=h, tam1=tam_lsb(pix, 1), tam4=tam_lsb(pix, 4), bytes=len(datos),
                    appended=datos[h['offset'] + h['pixeles']:], metodos={})
        rel = os.path.relpath(ruta, ROOT)
        for m in METODOS:
            with tempfile.TemporaryDirectory() as t:
                rc, _o, err = run([STEGO, '-extract', '-p', rel, '-out', os.path.join(t, base), '-steg', m])
                if rc == 0:
                    info['metodos'][m] = ('ok', analizar(t, base, datos))
                else:
                    linea = err.split('\n')[0]
                    info['metodos'][m] = ('no', linea)
        res[base] = info
    # secreto1: ningún método sin contraseña; se prueba la pista con las 3 x 16 combinaciones
    exitos = []
    for m in METODOS:
        for a in ALGS:
            for mo in MODOS:
                with tempfile.TemporaryDirectory() as t:
                    rc, _o, _e = run([STEGO, '-extract', '-p', os.path.relpath(
                        os.path.join(directorio, 'secreto1.bmp'), ROOT), '-out', os.path.join(t, 's'),
                        '-steg', m, '-a', a, '-m', mo, '-pass', PASSWORD_PISTA])
                    if rc == 0:
                        exitos.append((m, a, mo))
    res['_pista'] = exitos
    return res


def escribir(res):
    os.makedirs(GEN, exist_ok=True)
    av, mad, mon, sec = res['avatar'], res['madrid'], res['montevideo'], res['secreto1']
    D = {}

    def d(k, v):
        D[k] = v

    for base in ARCHIVOS:
        i = res[base]
        h = i['h']
        d('an-%s-ancho' % base, str(h['ancho']))
        d('an-%s-alto' % base, str(h['alto']))
        d('an-%s-bytes' % base, tex_int(i['bytes']))
        d('an-%s-pixeles' % base, tex_int(h['pixeles']))
        d('an-%s-cap1' % base, tex_int(h['pixeles'] // 8 - 4))
        d('an-%s-cap4' % base, tex_int(h['pixeles'] // 2 - 4))
        d('an-%s-tam1' % base, tex_int(i['tam1']))
        d('an-%s-tam4' % base, tex_int(i['tam4']))
    d('an-madrid-agregados', str(len(mad['appended'])))
    d('an-madrid-bfsize', tex_int(mad['h']['cbsize']))
    d('an-madrid-sizeimg', tex_int(mad['h']['size_img']))
    d('an-madrid-pixeles-reales', tex_int(mad['h']['pixeles']))
    d('an-madrid-texto', mad['appended'].decode('latin-1'))
    # avatar -> LSBI -> PDF
    st, r = av['metodos']['LSBI']
    if st != 'ok' or r.get('tipo') != 'PDF':
        raise Error('avatar.bmp ya no extrae un PDF con LSBI')
    d('an-avatar-pdf-bytes', tex_int(r['bytes']))
    d('an-avatar-pdf-texto', r['texto'])
    # montevideo -> LSB1 -> PNG con ZIP
    st, r = mon['metodos']['LSB1']
    if st != 'ok' or r.get('tipo') != 'PNG' or not r.get('zip'):
        raise Error('montevideo.bmp ya no extrae un PNG con un ZIP detrás con LSB1')
    d('an-mon-png-bytes', tex_int(r['bytes']))
    d('an-mon-png-ancho', str(r['ancho']))
    d('an-mon-png-alto', str(r['alto']))
    d('an-mon-png-resto', tex_int(r['restantes']))
    d('an-mon-png-restoini', tex_int(r['restos_inicio']))
    nombre, tam, texto = r['zip'][0]
    os.makedirs(GEN, exist_ok=True)
    with open(os.path.join(GEN, 'an-montevideo-oculto.png'), 'wb') as f:
        f.write(r['png'])
    d('an-mon-zip-nombre', nombre)
    d('an-mon-zip-bytes', tex_int(tam))
    d('an-mon-zip-texto', texto)
    d('an-pista-exitos', str(len(res['_pista'])))
    if res['_pista']:
        raise Error('la pista "%s" ya descifra secreto1: %r (actualizar el informe)' % (PASSWORD_PISTA, res['_pista']))
    # contenidos para listados
    with open(os.path.join(GEN, 'datos-analisis.tex'), 'w', encoding='utf-8') as f:
        f.write('% Generado por informe/scripts/medir_estegoanalisis.py: no editar a mano.\n')
        for k, v in D.items():
            if k in ('an-madrid-texto', 'an-avatar-pdf-texto', 'an-mon-zip-texto'):
                continue
            f.write('\\definirdato{%s}{%s}\n' % (k, v))
    # textos largos van a archivos aparte (se incluyen con \lstinputlisting)
    for clave, nombre in (('an-madrid-texto', 'an-madrid-texto.txt'), ('an-mon-zip-texto', 'an-sol5.txt'),
                          ('an-avatar-pdf-texto', 'an-avatar-texto.txt')):
        with open(os.path.join(GEN, nombre), 'w', encoding='utf-8', newline='\n') as f:
            f.write(D[clave].rstrip('\n') + '\n')

    def breve(info):
        st, v = info
        if st == 'ok':
            return '\\textbf{%s}, %s bytes' % (v.get('tipo', '?') if v.get('tipo') != '?' else 'datos',
                                               tex_int(v['bytes']))
        v = re.sub(r"^stegobmp: error: no hidden file found in '[^']*' with \w+: ", '', v)
        if v.startswith('the hidden size field says'):
            n = re.search(r'says (\d+) bytes', v).group(1)
            return 'tamaño %s no cabe' % tex_int(int(n))
        if v.startswith('malformed extension'):
            return 'tamaño válido, extensión malformada'
        return 'sin mensaje'

    with open(os.path.join(GEN, 'analisis-tabla-metodos.tex'), 'w', encoding='utf-8') as f:
        f.write('\\begin{tabularx}{\\textwidth}{@{}>{\\raggedright\\arraybackslash}p{2.6cm}'
                '>{\\raggedright\\arraybackslash}X>{\\raggedright\\arraybackslash}X'
                '>{\\raggedright\\arraybackslash}X@{}}\n\\toprule\n')
        f.write('Archivo & LSB1 & LSB4 & LSBI \\\\\n\\midrule\n')
        for base in ARCHIVOS:
            i = res[base]
            f.write('\\texttt{%s.bmp} & %s & %s & %s \\\\\n' % (
                base, breve(i['metodos']['LSB1']), breve(i['metodos']['LSB4']), breve(i['metodos']['LSBI'])))
        f.write('\\bottomrule\n\\end{tabularx}\n')


def main():
    dirs = sys.argv[1] if len(sys.argv) > 1 else DIR_DEFECTO
    try:
        res = medir(dirs)
        escribir(res)
    except Error as e:
        sys.stderr.write('medir_estegoanalisis: error: %s\n' % e)
        return 1
    print('PASS medir_estegoanalisis: 4 archivos analizados -> informe/generado/datos-analisis.tex')
    return 0


if __name__ == '__main__':
    sys.exit(main())
