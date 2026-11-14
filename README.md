# stegobmp

`stegobmp` es la implementación del TP de Esteganografía de Criptografía y Seguridad (72.04, ITBA): oculta cualquier archivo dentro de un BMP de 24 bits sin compresión (versión 3) y lo vuelve a extraer. Soporta los métodos LSB1, LSB4 y LSBI, con encripción previa opcional (AES-128, AES-192, AES-256 y 3DES en los modos ECB, CFB, OFB y CBC).

## Guía rápida

Todo se ejecuta desde la raíz del repositorio, en Linux (Ubuntu 22.04 o pampero):

1. Instalar dependencias y compilar: ver [Requisitos](#requisitos) y [Compilación](#compilación) (`make`).
2. Probar ocultar y extraer con cada método, con y sin encripción: ver [Ejemplos](#ejemplos).
3. Extraer lo oculto en los 4 archivos de la cátedra: ver [Archivos de la cátedra](#archivos-de-la-cátedra).
4. Ver los comandos que se usaron para responder cada cuestión (I a X): [Cómo se resolvió cada punto de la consigna](#cómo-se-resolvió-cada-punto-de-la-consigna).
5. Leer el estegoanálisis y las respuestas completas: `informe/informe.pdf`.

| Lo que pide la consigna | Dónde |
|-------------------------|-------|
| Ejecutable con los archivos para obtenerlo (Makefile) y pasos en el README | [Compilación](#compilación) |
| Recuperar lo oculto en cada archivo entregado por la cátedra | [Archivos de la cátedra](#archivos-de-la-cátedra) |
| Ocultar en `.bmp` con y sin encripción, con LSB1, LSB4 y LSBI | [Ejemplos](#ejemplos) (cuadro al final de la sección) |
| Informe con el estegoanálisis y las cuestiones I–X | `informe/informe.pdf`; comandos usados en [Cómo se resolvió cada punto](#cómo-se-resolvió-cada-punto-de-la-consigna) |

## Requisitos

Se necesitan `gcc`, `make` y la biblioteca OpenSSL libcrypto con sus headers (paquete `libssl-dev`). No se necesita nada más para compilar ni para usar `stegobmp`. En Ubuntu 22.04:

<!-- check_readme:install -->
```sh
sudo apt update && sudo apt install -y gcc make libssl-dev
```

El programa usa solamente llamadas de OpenSSL presentes en las versiones 1.0.2, 1.1.1 y 3.x, y se enlaza únicamente con `-lcrypto`.

## Compilación

<!-- check_readme:build -->
```sh
make
```

El resultado es el ejecutable `./stegobmp` en la raíz del repositorio. `make clean` elimina el ejecutable, los objetos y las salidas de los tests.

### pampero

Copiar el directorio del proyecto a pampero (como mínimo `Makefile`, `src/` e `include/`; además `Ejemplo/` e `imagenes catedra/` para correr los ejemplos y extraer los archivos de la cátedra), conectarse por ssh y ejecutar `make` dentro de ese directorio. Por ejemplo:

```sh
scp -r TP-CRIPTO usuario@pampero.itba.edu.ar:
ssh usuario@pampero.itba.edu.ar
cd TP-CRIPTO && make
```

Deben estar disponibles `gcc`, `make` y los headers de OpenSSL (`openssl/evp.h`); la versión instalada se consulta con `openssl version`.

## Uso

```
stegobmp -embed -in <file> -p <bitmapfile> -out <bitmapfile> -steg <LSB1 | LSB4 | LSBI> [-a <aes128 | aes192 | aes256 | 3des>] [-m <ecb | cfb | ofb | cbc>] [-pass <password>]
stegobmp -extract -p <bitmapfile> -out <file> -steg <LSB1 | LSB4 | LSBI> [-a <aes128 | aes192 | aes256 | 3des>] [-m <ecb | cfb | ofb | cbc>] [-pass <password>]
```

Los parámetros distinguen mayúsculas y minúsculas: los valores de `-steg` se escriben `LSB1`, `LSB4`, `LSBI`; los de `-a` y `-m` en minúsculas.

| Parámetro | Significado |
|-----------|-------------|
| `-embed` | Oculta un archivo en un BMP |
| `-extract` | Extrae el archivo oculto de un BMP |
| `-in <file>` | Archivo a ocultar (solo con `-embed`) |
| `-p <bitmapfile>` | BMP portador (con `-embed`) o BMP con el archivo oculto (con `-extract`) |
| `-out <bitmapfile>` | Con `-embed`: BMP resultante. Con `-extract`: nombre base del archivo extraído; se le agrega la extensión guardada (por ejemplo `.png`) |
| `-steg <LSB1 \| LSB4 \| LSBI>` | Método de esteganografía |
| `-a <aes128 \| aes192 \| aes256 \| 3des>` | Algoritmo de encripción |
| `-m <ecb \| cfb \| ofb \| cbc>` | Modo de encadenamiento |
| `-pass <password>` | Contraseña; es lo que activa la encripción |

### Encripción

`-pass` es el único parámetro que activa la encripción. Para lo demás valen estos defaults:

1. Solo `-pass`: se usa `aes128` en modo `cbc`.
2. `-a` y `-pass` (sin `-m`): se usa modo `cbc`.
3. `-m` y `-pass` (sin `-a`): se usa `aes128`.
4. `-a` y/o `-m` sin `-pass`: no se encripta, se oculta o extrae el archivo tal cual y se imprime una nota por stderr indicando que `-a`/`-m` se ignoran.

La clave y el IV se derivan de la contraseña con PBKDF2-HMAC-SHA256, 10000 iteraciones y sal de 8 bytes en cero. Se hace una única derivación de (largo de clave + largo de IV) bytes: los primeros bytes son la clave y los siguientes el IV.

Los modos son: `cfb` con realimentación de 8 bits (cfb8), `ofb` con realimentación de bloque completo, y relleno PKCS5 solamente en `ecb` y `cbc`. `3des` es des-ede3 con tres claves independientes.

Advertencia: la contraseña se pasa en la línea de comandos, por lo que es visible en la lista de procesos y queda en el historial del shell. La sintaxis la impone la consigna.

### Formato oculto

Sin encripción se oculta:

```
tamaño (4 bytes big endian) || datos || extensión\0
```

Con encripción se oculta:

```
tamaño del cifrado (4 bytes big endian) || Enc(tamaño (4 bytes big endian) || datos || extensión\0)
```

La extensión incluye el punto (por ejemplo `.png`) y termina con un byte nulo.

### Capacidad

Sea `n` la cantidad de bytes del área de píxeles del BMP, incluyendo el relleno de cada fila. La capacidad en bytes para ocultar (tamaño incluido) es:

| Método | Capacidad | `Ejemplo/lado.bmp` |
|--------|-----------|--------------------|
| LSB1 | `n / 8` | 115200 |
| LSB4 | `n / 2` | 460800 |
| LSBI | `(n - floor(n / 3) - 3) / 8` | 76799 |

Si el archivo (o su versión encriptada) no entra, el programa falla con código 2 y no escribe la salida.

### Códigos de salida

| Código | Significado |
|--------|-------------|
| 0 | Éxito |
| 1 | Parámetros inválidos (se imprime el uso) |
| 2 | Error de datos: no entra en el portador, no hay archivo oculto, no se pudo desencriptar, BMP inválido |
| 3 | Error de entrada/salida (archivo inexistente o no escribible) |

## Ejemplos

Los ejemplos se ejecutan desde la raíz del repositorio, con `./stegobmp` ya compilado, **en el orden en que aparecen**: los de `-embed` ocultan `salida_lsb1.png`, que genera el primero, y cada extracción posterior lee el BMP generado por el ejemplo anterior. Cada uno escribe el archivo indicado en el comentario que lo precede; se pueden copiar y pegar todos juntos en la terminal.

<!-- check_readme:examples -->
```sh
# escribe salida_lsb1.png
./stegobmp -extract -p Ejemplo/ladoLSB1.bmp -out salida_lsb1 -steg LSB1
# escribe salida_lsb4.png
./stegobmp -extract -p Ejemplo/ladoLSB4.bmp -out salida_lsb4 -steg LSB4
# escribe salida_lsbi.png
./stegobmp -extract -p Ejemplo/ladoLSBI.bmp -out salida_lsbi -steg LSBI
# escribe salida_aes128cbc.png
./stegobmp -extract -p Ejemplo/ladoLSB1aes128cbc.bmp -out salida_aes128cbc -steg LSB1 -a aes128 -m cbc -pass margarita
# escribe salida_aes256ofb.png
./stegobmp -extract -p Ejemplo/ladoLSBIaes256ofb.bmp -out salida_aes256ofb -steg LSBI -a aes256 -m ofb -pass margarita
# escribe salida_3descfb.png
./stegobmp -extract -p Ejemplo/ladoLSBIdescfb.bmp -out salida_3descfb -steg LSBI -a 3des -m cfb -pass margarita
# oculta con LSBI, 3des, cbc y contraseña oculto; escribe salida_stego.bmp
./stegobmp -embed -in salida_lsb1.png -p Ejemplo/lado.bmp -out salida_stego.bmp -steg LSBI -a 3des -m cbc -pass oculto
# extrae lo anterior; escribe salida_recuperado.png
./stegobmp -extract -p salida_stego.bmp -out salida_recuperado -steg LSBI -a 3des -m cbc -pass oculto
# oculta sin encripción; escribe salida_sin_encripcion.bmp
./stegobmp -embed -in salida_lsb1.png -p Ejemplo/lado.bmp -out salida_sin_encripcion.bmp -steg LSB4
# extrae lo anterior; escribe salida_sin_encripcion.png
./stegobmp -extract -p salida_sin_encripcion.bmp -out salida_sin_encripcion -steg LSB4
# oculta con LSB4, aes192 y ecb; escribe salida_aes192ecb.bmp
./stegobmp -embed -in salida_lsb1.png -p Ejemplo/lado.bmp -out salida_aes192ecb.bmp -steg LSB4 -a aes192 -m ecb -pass secreto
# extrae lo anterior; escribe salida_aes192ecb.png
./stegobmp -extract -p salida_aes192ecb.bmp -out salida_aes192ecb -steg LSB4 -a aes192 -m ecb -pass secreto
# solo -pass: aes128 y cbc por defecto; escribe salida_defaults.bmp
./stegobmp -embed -in salida_lsb1.png -p Ejemplo/lado.bmp -out salida_defaults.bmp -steg LSB1 -pass margarita
```

Los seis primeros ejemplos extraen los seis archivos de `Ejemplo/`, y todos producen la misma imagen PNG. El último ejemplo genera un archivo idéntico a `Ejemplo/ladoLSB1aes128cbc.bmp`, lo que muestra que el ocultamiento es compatible byte a byte con el de la cátedra.

Entre todos cubren los tres métodos, con y sin encripción, y todos los algoritmos y modos:

| | Sin encripción | Con encripción |
|-|----------------|----------------|
| LSB1 | extraer `ladoLSB1.bmp` | extraer `ladoLSB1aes128cbc.bmp` (aes128 cbc); ocultar `salida_defaults.bmp` (aes128 cbc por defecto) |
| LSB4 | extraer `ladoLSB4.bmp`; ocultar y extraer `salida_sin_encripcion.bmp` | ocultar y extraer `salida_aes192ecb.bmp` (aes192 ecb) |
| LSBI | extraer `ladoLSBI.bmp` | extraer `ladoLSBIaes256ofb.bmp` (aes256 ofb) y `ladoLSBIdescfb.bmp` (3des cfb); ocultar y extraer `salida_stego.bmp` (3des cbc) |

Cualquier otra combinación se arma igual cambiando `-steg`, `-a` y `-m`; para extraer hay que usar el mismo método, algoritmo, modo y contraseña que al ocultar.

Para borrar los archivos que generan los ejemplos y los comandos de las secciones siguientes:

```sh
rm -f salida_* sol5.txt
```

## Archivos de la cátedra

Los 4 archivos entregados a este grupo están en `imagenes catedra/grupo5/` (la ruta tiene un espacio, por eso va entre comillas). Estos comandos recuperan lo oculto en cada uno; la sección siguiente muestra cómo se llegó a cada método y parámetro.

```sh
# avatar.bmp: LSBI sin encripción; escribe salida_avatar.pdf (dice que la contraseña es "metadata")
./stegobmp -extract -p "imagenes catedra/grupo5/avatar.bmp" -out salida_avatar -steg LSBI
# montevideo.bmp: LSB1 sin encripción; escribe salida_montevideo.png (un buscaminas)
./stegobmp -extract -p "imagenes catedra/grupo5/montevideo.bmp" -out salida_montevideo -steg LSB1
# el PNG tiene un ZIP agregado al final; escribe sol5.txt (pistas para deducir algoritmo y modo)
unzip -o salida_montevideo.png
# secreto1.bmp: LSB4 con aes256 ofb; escribe salida_secreto1.wmv (el video)
./stegobmp -extract -p "imagenes catedra/grupo5/secreto1.bmp" -out salida_secreto1 -steg LSB4 -a aes256 -m ofb -pass $'metadata\r'
# madrid.bmp: no usa LSB, el mensaje son 49 bytes de texto agregados al final del archivo
tail -c 49 "imagenes catedra/grupo5/madrid.bmp"; echo
```

Notas:

- La contraseña de `secreto1.bmp` es `metadata` seguida de un retorno de carro (byte `0x0d`). `$'metadata\r'` es la sintaxis de bash para escribir ese carácter; con `-pass metadata` el desencriptado falla.
- `unzip` avisa que hay bytes extra al principio (los del PNG) y termina con código 1, pero descomprime `sol5.txt` igual. Si no está instalado, sirve `python3 -m zipfile -e salida_montevideo.png .`.
- `madrid.bmp` usa un método que no es LSB1, LSB4 ni LSBI (Cuestión VI del informe), así que no se extrae con `stegobmp`.

## Cómo se resolvió cada punto de la consigna

Los comandos que se usaron para responder cada cuestión del punto 7, en el orden del informe. Se ejecutan desde la raíz del repositorio con `./stegobmp` compilado. Los scripts de `tools/` e `informe/scripts/` necesitan `python3` (solo biblioteca estándar). Todo lo que se genera empieza con `salida_` y se borra con `rm -f salida_* sol5.txt`.

Para reproducir de una vez todas las mediciones y tablas del informe y recompilarlo (requiere además `pdflatex` y `mutool`):

```sh
make report
```

`make report` corre `informe/scripts/medir_q2.py` (cuestiones II y VII), `informe/scripts/medir_estegoanalisis.py` (cuestiones III a VI) y compila `informe/informe.pdf`. Los comandos de abajo muestran los mismos pasos uno por uno.

### Cuestión I: el paper de LSBI

Se leyó el paper (`docs/16Vol80No2.pdf`) y cada ambigüedad se resolvió contra el ejemplo de la cátedra con el modelo en Python `tools/lsbi.py`. La interpretación implementada reproduce `Ejemplo/ladoLSBI.bmp` byte a byte; otras variantes, por ejemplo usar también los bytes rojos, no lo reproducen:

```sh
# interpretación implementada: termina con match=yes y reembed_identical=yes
python3 tools/lsbi.py probe Ejemplo/lado.bmp Ejemplo/ladoLSBI.bmp
# usando también los bytes rojos: termina con match=no
python3 tools/lsbi.py probe Ejemplo/lado.bmp Ejemplo/ladoLSBI.bmp --use-red
```

`python3 tools/lsbi.py probe -h` lista las demás variantes que se probaron.

### Cuestión II: comparación de LSB1, LSB4 y LSBI

Se ocultó el mismo archivo con los tres métodos en `Ejemplo/lado.bmp` y se midieron los bytes y bits cambiados, la distorsión (PSNR) y la estadística de los bits bajos:

```sh
# carga: el PNG de la cátedra; escribe salida_q2.png
./stegobmp -extract -p Ejemplo/ladoLSB1.bmp -out salida_q2 -steg LSB1
# lo oculta con cada método; escribe salida_q2_LSB1.bmp, salida_q2_LSB4.bmp y salida_q2_LSBI.bmp
for m in LSB1 LSB4 LSBI; do ./stegobmp -embed -in salida_q2.png -p Ejemplo/lado.bmp -out salida_q2_$m.bmp -steg $m; done
# bytes y bits cambiados, canales, PSNR (una fila CSV por método)
for m in LSB1 LSB4 LSBI; do python3 tools/bmpdiff.py Ejemplo/lado.bmp salida_q2_$m.bmp --csv; done
# proporción de LSB en 1 por canal: portador y los tres estegos, lado a lado
python3 tools/lsbstats.py Ejemplo/lado.bmp salida_q2_LSB1.bmp salida_q2_LSB4.bmp salida_q2_LSBI.bmp
```

`informe/scripts/medir_q2.py` repite esto con otras dos cargas (el mensaje del paper y datos al azar) y genera las tablas y mapas de bytes cambiados del informe.

### Cuestión III: procedimiento sobre los archivos de la cátedra

1. Tamaño real del archivo comparado con el de la cabecera: el campo `appended` dice cuántos bytes sobran después del último píxel. Solo `madrid.bmp` da distinto de 0 (`appended=49`).

   ```sh
   for f in avatar madrid montevideo secreto1; do python3 tools/sigsearch.py "imagenes catedra/grupo5/$f.bmp" | sed -n 2p; done
   ```

2. Extracción con los tres métodos, sin contraseña. Con el método equivocado `stegobmp` informa que el campo de tamaño no entra en el portador; con el correcto extrae un archivo con extensión válida (`avatar`: LSBI, `montevideo`: LSB1). En `secreto1` LSB4 da un tamaño que entra pero no hay extensión, señal de que está encriptado; en `madrid` ningún método da un tamaño coherente. Cada intento fallido imprime el error seguido del texto de uso; es lo esperado.

   ```sh
   for f in avatar madrid montevideo secreto1; do for m in LSB1 LSB4 LSBI; do ./stegobmp -extract -p "imagenes catedra/grupo5/$f.bmp" -out salida_${f}_$m -steg $m; done; done
   ```

3. Tipo de lo extraído por su firma, y búsqueda de datos agregados después del final del formato:

   ```sh
   python3 tools/sigsearch.py salida_avatar_LSBI.pdf
   python3 tools/sigsearch.py salida_montevideo_LSB1.png
   ```

### Cuestión IV: mensajes ocultos dentro de mensajes ocultos

```sh
# el PNG de montevideo tiene un ZIP después del final del PNG (hits ZIP en offset 42586 y ZIP-EOCD)
python3 tools/sigsearch.py salida_montevideo_LSB1.png
# se descomprime tal cual (también vale renombrarlo a .zip); escribe sol5.txt
unzip -o salida_montevideo_LSB1.png
cat sol5.txt
# texto del PDF de avatar: "La password es metadata" (o abrir el PDF con cualquier visor)
mutool draw -q -F txt salida_avatar_LSBI.pdf
```

El tablero de buscaminas del PNG se resolvió a mano siguiendo `sol5.txt` (cada mina es un 1, cada fila una letra): da `AesOfb`, es decir `aes256` y `ofb`. La lectura fila por fila está en el informe.

### Cuestión V: el video oculto en `secreto1.bmp`

Con método, algoritmo y modo de las pistas, la contraseña literal `metadata` falla. Funciona con un retorno de carro al final; probablemente la cátedra generó el archivo con un script con finales de línea de Windows:

```sh
# falla: "cannot decrypt the hidden data with aes256-ofb"
./stegobmp -extract -p "imagenes catedra/grupo5/secreto1.bmp" -out salida_secreto1 -steg LSB4 -a aes256 -m ofb -pass metadata
# funciona; escribe salida_secreto1.wmv
./stegobmp -extract -p "imagenes catedra/grupo5/secreto1.bmp" -out salida_secreto1 -steg LSB4 -a aes256 -m ofb -pass $'metadata\r'
```

`informe/scripts/medir_estegoanalisis.py` prueba además `metadata` sin `\r` con las 48 combinaciones de método, algoritmo y modo, y verifica que ninguna descifre.

### Cuestión VI: el método desconocido (`madrid.bmp`)

```sh
# appended=49: hay 49 bytes después del último píxel
python3 tools/sigsearch.py "imagenes catedra/grupo5/madrid.bmp" | sed -n 2p
# esos bytes son texto en claro
tail -c 49 "imagenes catedra/grupo5/madrid.bmp"; echo
```

### Cuestión VII: mejora de LSBI

Cuántos bytes cambian en cada uno de los 4 patrones y si conviene invertirlos (líneas `counts pattern=...`):

```sh
python3 tools/lsbi.py probe Ejemplo/lado.bmp salida_q2_LSBI.bmp
```

`informe/scripts/medir_q2.py` hace lo mismo con las tres cargas y genera los cuadros de la cuestión.

### Cuestiones VIII, IX y X

Son preguntas de análisis (registro de patrones, dificultades de la implementación y mejoras posibles); no requieren comandos. Las respuestas están en `informe/informe.pdf`.

## Verificación (herramientas internas)

Estas herramientas no son necesarias para compilar ni usar `stegobmp`.

- `make test` corre la suite completa (requiere `python3` y el comando `openssl`).
- `bash tests/check_readme.sh` copia `Makefile`, `README.md`, `src/`, `include/` y `Ejemplo/` a un directorio temporal, compila con la línea de este README y ejecuta literalmente cada ejemplo (solo requiere bash, make y gcc).
- `make report` regenera las mediciones y compila el informe a `informe/informe.pdf` (requiere `python3`, `pdflatex` y `mutool`; no hace falta para compilar ni usar `stegobmp`).

## Estructura

El código está en `src/` y los headers en `include/`:

- `src/main.c`: flujo de `-embed` y `-extract`, mensajes y códigos de salida.
- `src/cli.c`, `include/cli.h`: parseo de parámetros, defaults de encripción y texto de uso.
- `src/bmp.c`, `include/bmp.h`: lectura y validación de BMP de 24 bits.
- `src/steg.c`, `include/steg.h`: métodos LSB1, LSB4 y LSBI.
- `src/crypto.c`, `include/crypto.h`: PBKDF2 y encripción/desencripción con OpenSSL.
- `src/payload.c`, `include/payload.h`: armado y lectura del formato oculto.
- `src/fileio.c`, `include/fileio.h`: lectura de archivos y escritura atómica.
- `Ejemplo/`: los BMP de ejemplo de la cátedra, usados en [Ejemplos](#ejemplos).
- `imagenes catedra/grupo5/`: los 4 archivos para el estegoanálisis.
- `tests/`, `tools/`: suite de tests y scripts de análisis (no hacen falta para usar `stegobmp`).
- `docs/LSBI-NOTES.md`: notas sobre el modelo de LSBI.
- `docs/CRYPTO-NOTES.md`: notas sobre la derivación de clave e IV y los modos.
- `informe/`: fuente LaTeX del informe, scripts de medición y datos generados.
