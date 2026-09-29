#include <inttypes.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <sys/stat.h>

#include "bmp.h"
#include "cli.h"
#include "crypto.h"
#include "fileio.h"
#include "payload.h"
#include "steg.h"

#define EXIT_USAGE 1
#define EXIT_DATA 2
#define EXIT_IO 3

#define ERRBUF 512

static int fail(int code, const char *fmt, ...)
{
    va_list ap;

    fputs("stegobmp: error: ", stderr);
    va_start(ap, fmt);
    vfprintf(stderr, fmt, ap);
    va_end(ap);
    fputc('\n', stderr);
    cli_print_usage(stderr);
    return code;
}

static int bmp_fail(int rc, const char *msg) { return fail(rc == BMP_ERR_IO ? EXIT_IO : EXIT_DATA, "%s", msg); }

/* -a/-m without -pass: stego only, but tell the user nothing was encrypted. */
static void note_no_pass(const cli_options_t *o)
{
    if (o->password == NULL && (o->alg != CIPHER_NONE || o->cipher_mode != CIPHER_MODE_NONE))
        fputs("stegobmp: note: -a/-m ignored because no -pass was given (no encryption)\n", stderr);
}

static int decrypt_fail(const cli_options_t *o, const char *detail)
{
    return fail(EXIT_DATA,
                "cannot decrypt the hidden data with %s-%s (wrong password, algorithm or mode, or "
                "'%s' holds no encrypted payload): %s",
                crypto_alg_name(o->alg), crypto_mode_name(o->cipher_mode), o->carrier_path, detail);
}

/*
 * Read the hidden file out of the carrier. With a password the hidden stream is always
 * BE32(cipher size) || ciphertext for exactly the resolved algorithm and mode: it is decrypted
 * and its framing validated entirely in memory, so a failure never leaves a partial output.
 */
static int read_hidden(const cli_options_t *o, const bmp_image_t *img, uint8_t **data,
                       size_t *data_len, char *ext, size_t ext_cap)
{
    steg_reader_t rd;
    char err[ERRBUF];
    uint8_t *cipher = NULL, *plain = NULL;
    size_t cipher_len = 0, plain_len = 0;
    int rc = 0;

    steg_reader_init(&rd, o->steg, img->data + img->pixel_offset, img->pixel_len);
    if (o->password == NULL) {
        if (payload_extract(&rd, data, data_len, ext, ext_cap, err, sizeof err) != 0)
            return fail(EXIT_DATA, "no hidden file found in '%s' with %s: %s", o->carrier_path,
                        steg_method_name(o->steg), err);
        return 0;
    }
    if (payload_read_cipher(&rd, &cipher, &cipher_len, err, sizeof err) != 0)
        return fail(EXIT_DATA, "no hidden file found in '%s' with %s: %s", o->carrier_path,
                    steg_method_name(o->steg), err);
    if (crypto_decrypt(o->alg, o->cipher_mode, o->password, cipher, cipher_len, &plain, &plain_len,
                       err, sizeof err) != 0) {
        crypto_wipe(cipher, cipher_len);
        free(cipher);
        return decrypt_fail(o, err);
    }
    crypto_wipe(cipher, cipher_len);
    free(cipher);
    if (payload_parse(plain, plain_len, data, data_len, ext, ext_cap, err, sizeof err) != 0)
        rc = decrypt_fail(o, err);
    crypto_wipe(plain, plain_len);
    free(plain);
    return rc;
}

static int run_extract(const cli_options_t *o)
{
    bmp_image_t img;
    uint8_t *data = NULL;
    size_t data_len = 0;
    char err[ERRBUF], ext[PAYLOAD_MAX_EXT_LEN + 1];
    char *path;
    int rc;

    rc = bmp_load(o->carrier_path, &img, err, sizeof err);
    if (rc != BMP_OK)
        return bmp_fail(rc, err);
    rc = read_hidden(o, &img, &data, &data_len, ext, sizeof ext);
    bmp_free(&img);
    if (rc != 0)
        return rc;
    path = malloc(strlen(o->out_path) + strlen(ext) + 1);
    if (!path) {
        if (o->password)
            crypto_wipe(data, data_len);
        free(data);
        return fail(EXIT_IO, "out of memory");
    }
    strcpy(path, o->out_path);
    strcat(path, ext);
    if (fileio_write_atomic(path, data, data_len, err, sizeof err) != 0) {
        rc = fail(EXIT_IO, "%s", err);
        goto out;
    }
    if (o->password)
        printf("stegobmp: extracted %zu bytes to '%s' (decrypted with %s-%s)\n", data_len, path,
               crypto_alg_name(o->alg), crypto_mode_name(o->cipher_mode));
    else
        printf("stegobmp: extracted %zu bytes to '%s'\n", data_len, path);
    note_no_pass(o);
    rc = 0;
out:
    free(path);
    if (o->password)
        crypto_wipe(data, data_len);
    free(data);
    return rc;
}

static int too_big_encrypted(const cli_options_t *o, uint64_t clen, uint64_t plain_len,
                             uint64_t capacity)
{
    return fail(EXIT_DATA,
                "the file to hide does not fit in the carrier: the payload needs %" PRIu64
                " bytes (4-byte ciphertext size + %" PRIu64 "-byte %s-%s ciphertext of a %" PRIu64
                "-byte plaintext) but the maximum capacity of '%s' with %s is %" PRIu64 " bytes",
                PAYLOAD_SIZE_LEN + clen, clen, crypto_alg_name(o->alg),
                crypto_mode_name(o->cipher_mode), plain_len, o->carrier_path,
                steg_method_name(o->steg), capacity);
}

static int run_embed(const cli_options_t *o)
{
    bmp_image_t img;
    struct stat st;
    char err[ERRBUF], ext[PAYLOAD_MAX_EXT_LEN + 1];
    uint8_t *file = NULL, *payload = NULL, *cipher = NULL, *framed = NULL;
    size_t file_len = 0, payload_len = 0, cipher_len = 0, framed_len = 0, ext_len;
    const uint8_t *stream;
    size_t stream_len;
    uint64_t capacity, need, clen;
    int rc;

    rc = bmp_load(o->carrier_path, &img, err, sizeof err);
    if (rc != BMP_OK)
        return bmp_fail(rc, err);
    if (payload_extension_of(o->in_path, ext, sizeof ext) != 0) {
        rc = fail(EXIT_DATA,
                  "cannot hide '%s': unsupported file extension (it must start with '.', be at "
                  "most 32 bytes and use printable ASCII without path separators)",
                  o->in_path);
        goto out;
    }
    ext_len = strlen(ext);
    capacity = steg_capacity(o->steg, img.pixel_len);
    if (stat(o->in_path, &st) != 0) {
        rc = fail(EXIT_IO, "cannot read '%s': %s", o->in_path, strerror(errno));
        goto out;
    }
    if (!S_ISREG(st.st_mode)) {
        rc = fail(EXIT_IO, "cannot read '%s': not a regular file", o->in_path);
        goto out;
    }
    need = payload_total_len((uint64_t)st.st_size, ext_len);
    if (o->password) {
        clen = crypto_ciphertext_len(o->alg, o->cipher_mode, need);
        if (PAYLOAD_SIZE_LEN + clen > capacity) {
            rc = too_big_encrypted(o, clen, need, capacity);
            goto out;
        }
    } else if (need > capacity) {
        rc = fail(EXIT_DATA,
                  "the file to hide does not fit in the carrier: the payload needs %" PRIu64
                  " bytes (4-byte size + %" PRIu64 "-byte file + %zu-byte extension) but the "
                  "maximum capacity of '%s' with %s is %" PRIu64 " bytes",
                  need, (uint64_t)st.st_size, ext_len + 1, o->carrier_path,
                  steg_method_name(o->steg), capacity);
        goto out;
    }
    if ((uint64_t)st.st_size > UINT32_MAX) {
        rc = fail(EXIT_DATA,
                  "the file to hide is larger than the 4-byte size field allows (4294967295 bytes)");
        goto out;
    }
    rc = fileio_read_all(o->in_path, (size_t)(capacity - 5 - ext_len), &file, &file_len, err,
                         sizeof err);
    if (rc == -2) {
        rc = fail(EXIT_DATA,
                  "the file to hide does not fit in the carrier: the payload needs more than %" PRIu64
                  " bytes but the maximum capacity of '%s' with %s is %" PRIu64 " bytes",
                  capacity, o->carrier_path, steg_method_name(o->steg), capacity);
        goto out;
    }
    if (rc != 0) {
        rc = fail(EXIT_IO, "%s", err);
        goto out;
    }
    if (payload_build(file, file_len, ext, &payload, &payload_len) != 0) {
        rc = fail(EXIT_DATA, "cannot embed the payload");
        goto out;
    }
    stream = payload;
    stream_len = payload_len;
    if (o->password) {
        /* The file may have grown since stat(): recompute from the bytes actually read. */
        clen = crypto_ciphertext_len(o->alg, o->cipher_mode, payload_len);
        if (PAYLOAD_SIZE_LEN + clen > capacity) {
            rc = too_big_encrypted(o, clen, payload_len, capacity);
            goto out;
        }
        if (crypto_encrypt(o->alg, o->cipher_mode, o->password, payload, payload_len, &cipher,
                           &cipher_len, err, sizeof err) != 0) {
            rc = fail(EXIT_DATA, "cannot encrypt the file with %s-%s: %s", crypto_alg_name(o->alg),
                      crypto_mode_name(o->cipher_mode), err);
            goto out;
        }
        if (payload_build_encrypted(cipher, cipher_len, &framed, &framed_len) != 0) {
            rc = fail(EXIT_DATA, "cannot embed the payload");
            goto out;
        }
        stream = framed;
        stream_len = framed_len;
    }
    if (steg_embed(o->steg, img.data + img.pixel_offset, img.pixel_len, stream, stream_len) != 0) {
        rc = fail(EXIT_DATA, "cannot embed the payload");
        goto out;
    }
    if (bmp_save(o->out_path, &img, err, sizeof err) != 0) {
        rc = fail(EXIT_IO, "%s", err);
        goto out;
    }
    if (o->password)
        printf("stegobmp: hid '%s' (%zu bytes, extension '%s') in '%s' using %s with %s-%s "
               "encryption\n",
               o->in_path, file_len, ext, o->out_path, steg_method_name(o->steg),
               crypto_alg_name(o->alg), crypto_mode_name(o->cipher_mode));
    else
        printf("stegobmp: hid '%s' (%zu bytes, extension '%s') in '%s' using %s\n", o->in_path,
               file_len, ext, o->out_path, steg_method_name(o->steg));
    note_no_pass(o);
    rc = 0;
out:
    if (o->password) {
        crypto_wipe(file, file_len);
        crypto_wipe(payload, payload_len);
        crypto_wipe(cipher, cipher_len);
        crypto_wipe(framed, framed_len);
    }
    free(file);
    free(payload);
    free(cipher);
    free(framed);
    bmp_free(&img);
    return rc;
}

int main(int argc, char **argv)
{
    cli_options_t opts;
    char err[ERRBUF];

    if (cli_parse(argc, argv, &opts, err, sizeof err) != 0)
        return fail(EXIT_USAGE, "%s", err);
    if (!steg_method_supported(opts.steg))
        return fail(EXIT_USAGE, "steganography method %s is not supported by this build (supported: LSB1, LSB4, LSBI)",
                    steg_method_name(opts.steg));
    return opts.mode == CLI_MODE_EXTRACT ? run_extract(&opts) : run_embed(&opts);
}
