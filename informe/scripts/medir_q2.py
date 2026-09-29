#!/usr/bin/env python3
"""medir_q2: mide LSB1, LSB4 y LSBI con ./stegobmp y las herramientas de tools/ para el informe.

Uso: python3 informe/scripts/medir_q2.py      (desde cualquier directorio; normalmente `make report`)

Oculta tres cargas (el PNG de la cátedra, el mensaje del paper y datos aleatorios) en Ejemplo/lado.bmp
con cada método, extrae de nuevo, mide con bmpdiff/lsbstats/lsbi probe y escribe en informe/generado/:
CSV, tablas LaTeX (solo `tabular`), datos.tex (macros \\definirdato), figuras PNG y la lista de cifras
que deben aparecer en el PDF. Todo se escribe con archivo temporal + os.replace. No modifica Ejemplo/.
Solo biblioteca estándar. Errores: "medir_q2: error: <mensaje>" en stderr, código 1.
"""
import sys
sys.dont_write_bytecode = True
import binascii
import csv
import hashlib
import io
import math
import os
import re
import shutil
import struct
import subprocess
import tempfile
import zlib

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
TOOLS = os.path.join(ROOT, 'tools')
GEN = os.path.join(ROOT, 'informe', 'generado')
sys.path.insert(0, TOOLS)
import bmplib  # noqa: E402

STEGO = os.path.join(ROOT, 'stegobmp')
CARRIER_REL = 'Ejemplo/lado.bmp'
CARRIER = os.path.join(ROOT, CARRIER_REL)
PNG_SHA256 = 'b93be15382f35f099ca286241dd7bb6e681d5bce8d315ac0b6240f0b516f549d'
METHODS = ['LSB1', 'LSB4', 'LSBI']
CATEDRA = {'LSB1': 'Ejemplo/ladoLSB1.bmp', 'LSB4': 'Ejemplo/ladoLSB4.bmp', 'LSBI': 'Ejemplo/ladoLSBI.bmp'}
NOMBRE_CARGA = {'png': 'Imagen PNG', 'paper': 'Mensaje del paper', 'azar': 'Datos aleatorios'}
CASOS = [('png', 'PNG (sin encripción)'), ('paper', 'Mensaje del paper'), ('azar', 'Datos aleatorios'),
         ('aes256ofb', 'PNG aes256-ofb (cátedra)'), ('descfb', 'PNG 3des-cfb (cátedra)')]
VECTORES = {'aes256ofb': 'Ejemplo/ladoLSBIaes256ofb.bmp', 'descfb': 'Ejemplo/ladoLSBIdescfb.bmp'}


class MedirError(Exception):
    pass


# ------------------------------------------------------------------ utilidades

def run(args):
    """Ejecuta un programa (lista de argumentos, sin shell). Devuelve (rc, stdout, stderr) como texto."""
    try:
        p = subprocess.Popen(args, stdout=subprocess.PIPE, stderr=subprocess.PIPE, cwd=ROOT)
        out, err = p.communicate()
    except OSError as e:
        raise MedirError('no se pudo ejecutar %s: %s' % (args[0], e))
    return p.returncode, out.decode('utf-8', 'replace'), err.decode('utf-8', 'replace')


def py_tool(name, *args):
    rc, out, err = run([sys.executable, '-B', os.path.join(TOOLS, name)] + list(args))
    if rc != 0:
        raise MedirError('%s falló (código %d): %s' % (name, rc, err.strip() or out.strip()))
    return out


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, 'rb') as f:
        for blk in iter(lambda: f.read(1 << 20), b''):
            h.update(blk)
    return h.hexdigest()


def hash_dir(path):
    return dict((n, sha256_file(os.path.join(path, n))) for n in sorted(os.listdir(path))
                if os.path.isfile(os.path.join(path, n)))


def atomic_write(path, data):
    if isinstance(data, str):
        data = data.encode('utf-8')
    fd, tmp = tempfile.mkstemp(prefix='.tmp-', dir=os.path.dirname(path))
    try:
        with os.fdopen(fd, 'wb') as f:
            f.write(data)
        os.chmod(tmp, 0o644)
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def read_file(path):
    with open(path, 'rb') as f:
        return f.read()


def csv_text(header, rows):
    buf = io.StringIO(newline='')
    w = csv.writer(buf, lineterminator='\n')
    w.writerow(header)
    for r in rows:
        w.writerow(r)
    return buf.getvalue()


def tex_int(n):
    return '{:,}'.format(int(n)).replace(',', '\\,')


def tex_dec(x, d):
    return ('%.*f' % (d, float(x))).replace('.', '{,}')


def tex_psnr(text):
    return '$\\infty$' if text == 'inf' else tex_dec(text, 2)


def sino(b):
    return 'sí' if b else 'no'


# ------------------------------------------------------------------ programas medidos

def embed(payload, out, steg):
    return run([STEGO, '-embed', '-in', payload, '-p', CARRIER, '-out', out, '-steg', steg])


def capacidad(work, steg):
    zeros = os.path.join(work, 'ceros.bin')
    with open(zeros, 'wb') as f:
        f.write(b'\x00' * 500000)
    rc, _out, err = embed(zeros, os.path.join(work, 'cap.bmp'), steg)
    if rc != 2:
        raise MedirError('se esperaba el error de capacidad de stegobmp (código 2) con %s, código %d' % (steg, rc))
    m = re.search(r'maximum capacity of .* with %s is (\d+) bytes' % steg, err)
    if not m:
        raise MedirError('no se pudo leer la capacidad de %s en: %s' % (steg, err.strip()))
    return int(m.group(1))


def bmpdiff(a, b):
    out = py_tool('bmpdiff.py', a, b, '--limit', '1')
    m = re.search(r'^summary changed_bytes=(\d+) changed_bits=(\d+) mask=0x([0-9a-f]+) first=(\S+) last=(\S+)', out, re.M)
    c = re.search(r'^channels B=(\d+) G=(\d+) R=(\d+)', out, re.M)
    bp = re.search(r'^bitpos (.*)$', out, re.M)
    d = re.search(r'^distortion mse=(\S+) psnr=(\S+) samples=(\d+) basis=(\S+)', out, re.M)
    if not (m and c and bp and d):
        raise MedirError('salida inesperada de bmpdiff.py')
    bits = [int(x.split('=')[1]) for x in bp.group(1).split()]
    return {'cambiados': int(m.group(1)), 'bits': int(m.group(2)), 'mascara': int(m.group(3), 16),
            'ultimo': int(m.group(5)) if m.group(5) != '-' else 0,
            'B': int(c.group(1)), 'G': int(c.group(2)), 'R': int(c.group(3)), 'bitpos': bits,
            'mse': d.group(1), 'psnr': d.group(2)}


def probe(stego):
    out = py_tool('lsbi.py', 'probe', CARRIER_REL, stego)
    fl = re.search(r'^flags=([01]{4})$', out, re.M)
    cnt = re.findall(r'^counts pattern=([01]{2}) changed=(\d+) unchanged=(\d+) invert=([01])$', out, re.M)
    re_ok = re.search(r'^reembed_identical=(yes|no)$', out, re.M)
    if not fl or len(cnt) != 4 or not re_ok:
        raise MedirError('salida inesperada de lsbi.py probe para %s' % stego)
    if re_ok.group(1) != 'yes':
        raise MedirError('lsbi.py probe: reembed_identical=no para %s' % stego)
    pats = [(p, int(c), int(u), int(i)) for p, c, u, i in cnt]
    return {'flags': fl.group(1), 'patrones': pats}


def estadisticas(paths):
    out = py_tool('lsbstats.py', '--csv', *paths)
    rows = [l.split(',') for l in out.strip().split('\n')[1:]]
    chans = ['B', 'G', 'R', 'PAD', 'ALL']
    if len(rows) != 5 * len(paths):
        raise MedirError('salida inesperada de lsbstats.py')
    res = []
    for i in range(len(paths)):
        d = {}
        for k, ch in enumerate(chans):
            r = rows[i * 5 + k]
            if r[1] != ch:
                raise MedirError('orden inesperado en lsbstats.py')
            if ch in ('B', 'G', 'R'):
                d[ch] = (r[4], r[-1])
        res.append(d)
    return res


# ------------------------------------------------------------------ imágenes PNG

def png_encode(w, h, rows):
    raw = b''.join(b'\x00' + r for r in rows)

    def chunk(t, d):
        return struct.pack('>I', len(d)) + t + d + struct.pack('>I', binascii.crc32(t + d) & 0xffffffff)
    return (b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 2, 0, 0, 0)) +
            chunk(b'IDAT', zlib.compress(raw, 9)) + chunk(b'IEND', b''))


def bmp_rows(data, info):
    """Filas del BMP en orden de visualización (arriba a abajo), cada una con bytes B,G,R."""
    h = abs(info.height)
    rows = []
    for r in range(h):
        src = r if info.top_down else h - 1 - r
        s = info.pixel_offset + src * info.stride
        rows.append(bytes(data[s:s + info.width * 3]))
    return rows


def bgr_to_rgb(row):
    out = bytearray(len(row))
    out[0::3] = row[2::3]
    out[1::3] = row[1::3]
    out[2::3] = row[0::3]
    return bytes(out)


def imagen(data, info):
    return png_encode(info.width, abs(info.height), [bgr_to_rgb(r) for r in bmp_rows(data, info)])


def mapa(cdata, cinfo, sdata, sinfo):
    rows = []
    for a, b in zip(bmp_rows(cdata, cinfo), bmp_rows(sdata, sinfo)):
        d = bytes(255 if x != y else 0 for x, y in zip(a, b))
        rows.append(bgr_to_rgb(d))
    return png_encode(cinfo.width, abs(cinfo.height), rows)


# ------------------------------------------------------------------ programa principal

def azar_bytes(n):
    out = b''
    c = 0
    while len(out) < n:
        out += hashlib.sha256(b'stegobmp-informe-q2' + struct.pack('>I', c)).digest()
        c += 1
    return out[:n]


def medir(work):
    if not (os.path.isfile(STEGO) and os.access(STEGO, os.X_OK)):
        raise MedirError('falta ./stegobmp: ejecutar make')
    cdata = read_file(CARRIER)
    cinfo = bmplib.parse_bmp(cdata)
    if not cinfo.is_bmp or cinfo.bpp != 24:
        raise MedirError('Ejemplo/lado.bmp no es un BMP de 24 bits')

    # Cargas.
    rc, _o, err = run([STEGO, '-extract', '-p', os.path.join(ROOT, CATEDRA['LSB1']),
                       '-out', os.path.join(work, 'catedra'), '-steg', 'LSB1'])
    png_path = os.path.join(work, 'catedra.png')
    if rc != 0 or not os.path.isfile(png_path) or sha256_file(png_path) != PNG_SHA256:
        raise MedirError('no se pudo extraer el PNG de la cátedra de ladoLSB1.bmp (%s)' % err.strip())
    paper_path = os.path.join(ROOT, 'informe', 'datos', 'mensaje_paper.txt')
    if not os.path.isfile(paper_path) or os.path.getsize(paper_path) != 226:
        raise MedirError('informe/datos/mensaje_paper.txt debe existir y medir exactamente 226 bytes')
    azar_path = os.path.join(work, 'azar.bin')
    with open(azar_path, 'wb') as f:
        f.write(azar_bytes(40000))
    cargas = [('png', png_path, '.png'), ('paper', paper_path, '.txt'), ('azar', azar_path, '.bin')]

    caps = dict((m, capacidad(work, m)) for m in METHODS)
    pixel_block = cinfo.pixel_len

    filas = []
    stegos = {}
    for carga, path, ext in cargas:
        tam = os.path.getsize(path)
        orig = read_file(path)
        for m in METHODS:
            out = os.path.join(work, '%s-%s.bmp' % (carga, m))
            rc, _o, err = embed(path, out, m)
            if rc != 0:
                raise MedirError('stegobmp -embed (%s, %s) falló: %s' % (carga, m, err.strip()))
            base = os.path.join(work, 'ext-%s-%s' % (carga, m))
            rc, _o, err = run([STEGO, '-extract', '-p', out, '-out', base, '-steg', m])
            if rc != 0 or not os.path.isfile(base + ext):
                raise MedirError('stegobmp -extract (%s, %s) falló: %s' % (carga, m, err.strip()))
            if read_file(base + ext) != orig:
                raise MedirError('la extracción de %s con %s no devuelve el archivo original' % (carga, m))
            ident = 'n/a'
            if carga == 'png':
                if read_file(out) != read_file(os.path.join(ROOT, CATEDRA[m])):
                    raise MedirError('el estego de %s no es idéntico a %s' % (m, CATEDRA[m]))
                ident = 'si'
            d = bmpdiff(CARRIER, out)
            ocultos = 4 + tam + len(ext) + 1
            usados = {'LSB1': 8 * ocultos, 'LSB4': 2 * ocultos, 'LSBI': 4 + 8 * ocultos}[m]
            mask = d['mascara']
            filas.append({
                'carga': carga, 'metodo': m, 'archivo': tam, 'ocultos': ocultos, 'cap': caps[m],
                'uso': 100.0 * ocultos / caps[m], 'usados': usados,
                'cambiados': d['cambiados'], 'bits': d['bits'],
                'tasa': 100.0 * d['cambiados'] / usados,
                'pct': 100.0 * d['cambiados'] / pixel_block,
                'mascara': '0x%02x' % mask, 'cambiomax': 1 if mask == 1 else (15 if mask == 15 else mask),
                'bitpos': d['bitpos'][:4], 'ultimo': d['ultimo'], 'B': d['B'], 'G': d['G'], 'R': d['R'],
                'mse': d['mse'], 'psnr': d['psnr'], 'ext_ok': 'si', 'ident': ident})
            stegos[(carga, m)] = out
    return cdata, cinfo, caps, cargas, filas, stegos


def fila(filas, carga, m):
    for f in filas:
        if f['carga'] == carga and f['metodo'] == m:
            return f
    raise KeyError((carga, m))


def main_work(work):
    cdata, cinfo, caps, cargas, filas, stegos = medir(work)
    datos = []   # (clave, valor)
    salida = {}  # nombre -> contenido

    # ---- resultados
    header = ['carga', 'metodo', 'bytes_archivo', 'bytes_ocultos', 'capacidad', 'uso_pct', 'bytes_usados',
              'bytes_cambiados', 'bits_cambiados', 'tasa_cambio_pct', 'pct_portador', 'mascara', 'cambio_max',
              'b0', 'b1', 'b2', 'b3', 'ultimo_offset', 'cambios_B', 'cambios_G', 'cambios_R', 'mse', 'psnr',
              'extraccion_ok', 'identico_catedra']
    rows = []
    for f in filas:
        rows.append([f['carga'], f['metodo'], f['archivo'], f['ocultos'], f['cap'], '%.4f' % f['uso'],
                     f['usados'], f['cambiados'], f['bits'], '%.4f' % f['tasa'], '%.4f' % f['pct'],
                     f['mascara'], f['cambiomax']] + f['bitpos'] +
                    [f['ultimo'], f['B'], f['G'], f['R'], f['mse'], f['psnr'], f['ext_ok'], f['ident']])
    salida['q2-resultados.csv'] = csv_text(header, rows)

    datos.append(('portador-ancho', str(cinfo.width)))
    datos.append(('portador-alto', str(abs(cinfo.height))))
    datos.append(('portador-bytes', tex_int(cinfo.pixel_len)))
    for m in METHODS:
        datos.append(('cap-%s' % m, tex_int(caps[m])))
    for carga, path, _ext in cargas:
        datos.append(('%s-bytes' % carga, tex_int(os.path.getsize(path))))
        for m in METHODS:
            f = fila(filas, carga, m)
            p = '%s-%s-' % (carga, m)
            datos += [(p + 'ocultos', tex_int(f['ocultos'])), (p + 'uso', tex_dec(f['uso'], 2)),
                      (p + 'usados', tex_int(f['usados'])), (p + 'cambiados', tex_int(f['cambiados'])),
                      (p + 'bits', tex_int(f['bits'])), (p + 'tasa', tex_dec(f['tasa'], 2)),
                      (p + 'pctportador', tex_dec(f['pct'], 2)), (p + 'mse', tex_dec(f['mse'], 4)),
                      (p + 'psnr', tex_psnr(f['psnr'])), (p + 'rojos', tex_int(f['R'])),
                      (p + 'ultimo', tex_int(f['ultimo'])), (p + 'cambiomax', str(f['cambiomax']))]

    # ---- tabla PNG
    def col(fn):
        return ' & '.join(fn(fila(filas, 'png', m)) for m in METHODS)
    tab = [('Capacidad máxima (bytes)', lambda f: tex_int(f['cap'])),
           ('Bytes ocultados', lambda f: tex_int(f['ocultos'])),
           ('Uso de la capacidad (\\%)', lambda f: tex_dec(f['uso'], 2)),
           ('Bytes del portador usados', lambda f: tex_int(f['usados'])),
           ('Bytes modificados', lambda f: tex_int(f['cambiados'])),
           ('Bits modificados', lambda f: tex_int(f['bits'])),
           ('Tasa de cambio por byte usado (\\%)', lambda f: tex_dec(f['tasa'], 2)),
           ('Bytes modificados sobre el total (\\%)', lambda f: tex_dec(f['pct'], 2)),
           ('Cambio máximo por byte', lambda f: str(f['cambiomax'])),
           ('Bytes rojos modificados', lambda f: tex_int(f['R'])),
           ('Último offset modificado', lambda f: tex_int(f['ultimo'])),
           ('MSE', lambda f: tex_dec(f['mse'], 4)),
           ('PSNR (dB)', lambda f: tex_psnr(f['psnr'])),
           ('Idéntico al archivo de la cátedra', lambda f: sino(f['ident'] == 'si')),
           ('Extracción correcta', lambda f: sino(f['ext_ok'] == 'si'))]
    t = ['\\begin{tabular}{lrrr}', '\\toprule', 'Métrica & LSB1 & LSB4 & LSBI \\\\', '\\midrule']
    t += ['%s & %s \\\\' % (name, col(fn)) for name, fn in tab]
    t += ['\\bottomrule', '\\end{tabular}']
    salida['q2-tabla-png.tex'] = '\n'.join(t) + '\n'

    # ---- tabla de cargas
    t = ['\\begin{tabular}{llrrrrr}', '\\toprule',
         'Carga & Método & Ocultos & Uso (\\%) & Modificados & Tasa (\\%) & PSNR (dB) \\\\']
    for carga, _p, _e in cargas:
        t.append('\\midrule')
        for k, m in enumerate(METHODS):
            f = fila(filas, carga, m)
            t.append('%s & %s & %s & %s & %s & %s & %s \\\\' % (
                NOMBRE_CARGA[carga] if k == 0 else '', m, tex_int(f['ocultos']), tex_dec(f['uso'], 2),
                tex_int(f['cambiados']), tex_dec(f['tasa'], 2), tex_psnr(f['psnr'])))
    t += ['\\bottomrule', '\\end{tabular}']
    salida['q2-tabla-cargas.tex'] = '\n'.join(t) + '\n'

    # ---- estadísticas
    fuentes = [('portador', 'Portador original', CARRIER_REL)] + [
        ('png-%s' % m, 'PNG con %s' % m, stegos[('png', m)]) for m in METHODS]
    est = estadisticas([p for _k, _n, p in fuentes])
    est_rows = []
    t = ['\\begin{tabular}{lrrrrrr}', '\\toprule',
         ' & \\multicolumn{3}{c}{Proporción de LSB igual a 1} & \\multicolumn{3}{c}{$\\chi^2$ de pares de valores} \\\\',
         '\\cmidrule(lr){2-4}\\cmidrule(lr){5-7}', 'Archivo & B & G & R & B & G & R \\\\', '\\midrule']
    for (clave, nombre, _p), d in zip(fuentes, est):
        for ch in 'BGR':
            est_rows.append([clave, ch, d[ch][0], d[ch][1]])
            datos.append(('est-%s-%s-lsb' % (clave, ch), tex_dec(d[ch][0], 4)))
            datos.append(('est-%s-%s-chi' % (clave, ch), tex_dec(d[ch][1], 2)))
        t.append('%s & %s & %s \\\\' % (
            nombre, ' & '.join(tex_dec(d[ch][0], 4) for ch in 'BGR'), ' & '.join(tex_dec(d[ch][1], 2) for ch in 'BGR')))
    t += ['\\bottomrule', '\\end{tabular}']
    salida['q2-tabla-estadisticas.tex'] = '\n'.join(t) + '\n'
    salida['q2-estadisticas.csv'] = csv_text(['fuente', 'canal', 'lsb1_ratio', 'chi2_pov'], est_rows)

    # ---- inversión (Cuestión VII)
    inv = []
    for caso, nombre in CASOS:
        if caso in VECTORES:
            stego = os.path.join(ROOT, VECTORES[caso])
            total = bmpdiff(CARRIER, stego)['cambiados']
        else:
            stego = stegos[(caso, 'LSBI')]
            total = fila(filas, caso, 'LSBI')['cambiados']
        pr = probe(stego)
        pats = pr['patrones']
        n = sum(c + u for _p, c, u, _i in pats)
        sin = sum(c for _p, c, _u, _i in pats)
        con = sum(u if i else c for _p, c, u, i in pats)
        inv.append({'caso': caso, 'nombre': nombre, 'flags': pr['flags'], 'pats': pats, 'n': n, 'sin': sin,
                    'con': con, 'red': 100.0 * (sin - con) / sin if sin else 0.0, 'banderas': total - con})
    inv_rows = []
    for v in inv:
        for p, c, u, i in v['pats']:
            inv_rows.append([v['caso'], p, c, u, i, u if i else c])
        inv_rows.append([v['caso'], 'total', v['sin'], sum(u for _p, _c, u, _i in v['pats']), '-', v['con']])
        datos += [('inv-%s-n' % v['caso'], tex_int(v['n'])), ('inv-%s-sin' % v['caso'], tex_int(v['sin'])),
                  ('inv-%s-con' % v['caso'], tex_int(v['con'])), ('inv-%s-reduccion' % v['caso'], tex_dec(v['red'], 2)),
                  ('inv-%s-flags' % v['caso'], v['flags']), ('inv-%s-banderas' % v['caso'], tex_int(v['banderas']))]
    salida['q7-inversion.csv'] = csv_text(['caso', 'patron', 'cambiados', 'sin_cambio', 'invertido', 'cambios_finales'],
                                          inv_rows)
    azar = [v for v in inv if v['caso'] == 'azar'][0]
    teorico = sum(math.sqrt((c + u) / (2 * math.pi)) for _p, c, u, _i in azar['pats'])
    datos.append(('inv-azar-teorico', tex_int(round(teorico))))
    datos.append(('inv-azar-teoricopct', tex_dec(100.0 * teorico / azar['sin'], 2)))

    t = ['\\begin{tabular}{lrrrrcr}', '\\toprule',
         'Caso & Bytes con mensaje & Sin inversión & Con inversión & Reducción (\\%) & Banderas & Cambios en banderas \\\\',
         '\\midrule']
    for v in inv:
        t.append('%s & %s & %s & %s & %s & \\texttt{%s} & %s \\\\' % (
            v['nombre'], tex_int(v['n']), tex_int(v['sin']), tex_int(v['con']), tex_dec(v['red'], 2), v['flags'],
            tex_int(v['banderas'])))
    t += ['\\bottomrule', '\\end{tabular}']
    salida['q7-tabla-inversion.tex'] = '\n'.join(t) + '\n'

    png = [v for v in inv if v['caso'] == 'png'][0]
    t = ['\\begin{tabular}{crrcr}', '\\toprule',
         'Patrón & Cambiados & Sin cambio & Invertido & Cambios finales \\\\', '\\midrule']
    for p, c, u, i in png['pats']:
        t.append('\\texttt{%s} & %s & %s & %s & %s \\\\' % (p, tex_int(c), tex_int(u), sino(i), tex_int(u if i else c)))
    t += ['\\midrule', 'Total & %s & %s & & %s \\\\' % (
        tex_int(png['sin']), tex_int(sum(u for _p, _c, u, _i in png['pats'])), tex_int(png['con'])),
        '\\bottomrule', '\\end{tabular}']
    salida['q7-tabla-patrones.tex'] = '\n'.join(t) + '\n'

    # ---- datos.tex y lista de cifras esperadas
    cab = ['% Generado por informe/scripts/medir_q2.py: no editar a mano.',
           '% Claves definidas (\\dato{clave}); tex_int agrupa miles con \\, y los decimales usan {,}:']
    cab += ['%   ' + k for k, _v in datos]
    salida['datos.tex'] = '\n'.join(cab) + '\n' + ''.join('\\definirdato{%s}{%s}\n' % (k, v) for k, v in datos)
    esp = []
    for m in METHODS:
        f = fila(filas, 'png', m)
        esp += [str(f['cambiados']), tex_dec(f['psnr'], 2).replace('{,}', ','), str(f['cap'])]
    salida['esperado-en-pdf.txt'] = '\n'.join(esp) + '\n'

    # ---- figuras
    pngdata = {}
    pngdata['q2-portador.png'] = imagen(cdata, cinfo)
    for m in METHODS:
        sdata = read_file(stegos[('png', m)])
        sinfo = bmplib.parse_bmp(sdata)
        if m == 'LSB4':
            pngdata['q2-estego-LSB4.png'] = imagen(sdata, sinfo)
        pngdata['q2-mapa-%s.png' % m] = mapa(cdata, cinfo, sdata, sinfo)
    return salida, pngdata, len(filas)


def main():
    antes = hash_dir(os.path.join(ROOT, 'Ejemplo'))
    work = tempfile.mkdtemp(prefix='medir_q2-')
    try:
        salida, figuras, n = main_work(work)
        os.makedirs(GEN, exist_ok=True)
        for nombre, contenido in sorted(salida.items()):
            atomic_write(os.path.join(GEN, nombre), contenido)
        for nombre, contenido in sorted(figuras.items()):
            atomic_write(os.path.join(GEN, nombre), contenido)
    finally:
        shutil.rmtree(work, ignore_errors=True)
    if hash_dir(os.path.join(ROOT, 'Ejemplo')) != antes:
        raise MedirError('Ejemplo/ cambió durante la medición')
    print('medir_q2: OK (%d mediciones)' % n)


if __name__ == '__main__':
    try:
        main()
    except MedirError as e:
        sys.stderr.write('medir_q2: error: %s\n' % e)
        sys.exit(1)
    except Exception as e:  # nunca un traceback
        sys.stderr.write('medir_q2: error: %s: %s\n' % (type(e).__name__, e))
        sys.exit(1)
