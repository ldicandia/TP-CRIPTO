# stegobmp

`stegobmp` es la implementación del TP de Esteganografía de Criptografía y Seguridad (72.04, ITBA): oculta cualquier archivo dentro de un BMP de 24 bits sin compresión (versión 3) y lo vuelve a extraer. Soporta los métodos LSB1, LSB4 y LSBI, con encripción previa opcional (AES-128, AES-192, AES-256 y 3DES en los modos ECB, CFB, OFB y CBC).

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

Copiar el directorio del proyecto a pampero (como mínimo `src/` y `Makefile`, más `README.md`, `Ejemplo/` y `tests/check_readme.sh` para correr los ejemplos), conectarse por ssh y ejecutar `make` dentro de ese directorio. Deben estar disponibles `gcc`, `make` y los headers de OpenSSL (`openssl/evp.h`); la versión instalada se consulta con `openssl version`.

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

Los ejemplos se ejecutan desde la raíz del repositorio, con `./stegobmp` ya compilado. Cada uno escribe el archivo indicado en el comentario que lo precede.

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
# solo -pass: aes128 y cbc por defecto; escribe salida_defaults.bmp
./stegobmp -embed -in salida_lsb1.png -p Ejemplo/lado.bmp -out salida_defaults.bmp -steg LSB1 -pass margarita
```

Los seis primeros ejemplos extraen los seis archivos de `Ejemplo/`, y todos producen la misma imagen PNG. El último ejemplo genera un archivo idéntico a `Ejemplo/ladoLSB1aes128cbc.bmp`.

## Verificación (herramientas internas)

Estas herramientas no son necesarias para compilar ni usar `stegobmp`.

- `make test` corre la suite completa (requiere `python3` y el comando `openssl`).
- `bash tests/check_readme.sh` copia `Makefile`, `README.md`, `src/` y `Ejemplo/` a un directorio temporal, compila con la línea de este README y ejecuta literalmente cada ejemplo (solo requiere bash, make y gcc).

## Estructura

- `src/main.c`: flujo de `-embed` y `-extract`, mensajes y códigos de salida.
- `src/cli.c`, `src/cli.h`: parseo de parámetros, defaults de encripción y texto de uso.
- `src/bmp.c`, `src/bmp.h`: lectura y validación de BMP de 24 bits.
- `src/steg.c`, `src/steg.h`: métodos LSB1, LSB4 y LSBI.
- `src/crypto.c`, `src/crypto.h`: PBKDF2 y encripción/desencripción con OpenSSL.
- `src/payload.c`, `src/payload.h`: armado y lectura del formato oculto.
- `src/fileio.c`, `src/fileio.h`: lectura de archivos y escritura atómica.
- `docs/LSBI-NOTES.md`: notas sobre el modelo de LSBI.
- `docs/CRYPTO-NOTES.md`: notas sobre la derivación de clave e IV y los modos.
