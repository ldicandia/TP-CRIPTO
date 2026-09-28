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

static int run_extract(const cli_options_t *o)
{
    bmp_image_t img;
    steg_reader_t rd;
    uint8_t *data = NULL;
    size_t data_len = 0;
    char err[ERRBUF], ext[PAYLOAD_MAX_EXT_LEN + 1];
    char *path;
    int rc;

    rc = bmp_load(o->carrier_path, &img, err, sizeof err);
    if (rc != BMP_OK)
        return bmp_fail(rc, err);
    steg_reader_init(&rd, o->steg, img.data + img.pixel_offset, img.pixel_len);
    if (payload_extract(&rd, &data, &data_len, ext, sizeof ext, err, sizeof err) != 0) {
        rc = fail(EXIT_DATA, "no hidden file found in '%s' with %s: %s", o->carrier_path,
                  steg_method_name(o->steg), err);
        bmp_free(&img);
        return rc;
    }
    bmp_free(&img);
    path = malloc(strlen(o->out_path) + strlen(ext) + 1);
    if (!path) {
        free(data);
        return fail(EXIT_IO, "out of memory");
    }
    strcpy(path, o->out_path);
    strcat(path, ext);
    if (fileio_write_atomic(path, data, data_len, err, sizeof err) != 0) {
        rc = fail(EXIT_IO, "%s", err);
        free(path);
        free(data);
        return rc;
    }
    printf("stegobmp: extracted %zu bytes to '%s'\n", data_len, path);
    free(path);
    free(data);
    return 0;
}

static int run_embed(const cli_options_t *o)
{
    bmp_image_t img;
    struct stat st;
    char err[ERRBUF], ext[PAYLOAD_MAX_EXT_LEN + 1];
    uint8_t *file = NULL, *payload = NULL;
    size_t file_len = 0, payload_len = 0, ext_len;
    uint64_t capacity, need;
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
    if (need > capacity) {
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
    if (payload_build(file, file_len, ext, &payload, &payload_len) != 0 ||
        steg_embed(o->steg, img.data + img.pixel_offset, img.pixel_len, payload,
                   payload_len) != 0) {
        rc = fail(EXIT_DATA, "cannot embed the payload");
        goto out;
    }
    if (bmp_save(o->out_path, &img, err, sizeof err) != 0) {
        rc = fail(EXIT_IO, "%s", err);
        goto out;
    }
    printf("stegobmp: hid '%s' (%zu bytes, extension '%s') in '%s' using %s\n", o->in_path,
           file_len, ext, o->out_path, steg_method_name(o->steg));
    rc = 0;
out:
    free(file);
    free(payload);
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
    if (opts.password != NULL)
        return fail(EXIT_USAGE,
                    "encryption (-pass) is not supported by this build; nothing was written");
    return opts.mode == CLI_MODE_EXTRACT ? run_extract(&opts) : run_embed(&opts);
}
