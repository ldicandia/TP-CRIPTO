#include "payload.h"

#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static uint32_t be32_read(const uint8_t *p)
{
    return ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) | ((uint32_t)p[2] << 8) |
           (uint32_t)p[3];
}

static void be32_write(uint8_t *p, uint32_t v)
{
    p[0] = (uint8_t)(v >> 24);
    p[1] = (uint8_t)(v >> 16);
    p[2] = (uint8_t)(v >> 8);
    p[3] = (uint8_t)v;
}

static int ext_bytes_valid(const char *ext, size_t len)
{
    if (len == 0 || len > PAYLOAD_MAX_EXT_LEN || ext[0] != '.')
        return 0;
    for (size_t i = 1; i < len; i++) {
        unsigned char c = (unsigned char)ext[i];
        if (c < 0x21 || c > 0x7E || c == '/' || c == '\\')
            return 0;
    }
    return 1;
}

int payload_ext_is_valid(const char *ext) { return ext_bytes_valid(ext, strlen(ext)); }

int payload_extension_of(const char *path, char *ext, size_t ext_cap)
{
    const char *base = strrchr(path, '/');
    const char *dot;
    size_t len;

    base = base ? base + 1 : path;
    dot = strrchr(base, '.');
    if (!dot) {
        if (ext_cap < 2)
            return -1;
        ext[0] = '.';
        ext[1] = '\0';
        return 0;
    }
    len = strlen(dot);
    if (len + 1 > ext_cap || !ext_bytes_valid(dot, len))
        return -1;
    memcpy(ext, dot, len + 1);
    return 0;
}

uint64_t payload_total_len(uint64_t data_len, size_t ext_len)
{
    return PAYLOAD_SIZE_LEN + data_len + ext_len + 1;
}

int payload_build(const uint8_t *data, size_t data_len, const char *ext, uint8_t **out,
                  size_t *out_len)
{
    size_t ext_len = strlen(ext);
    size_t total;
    uint8_t *p;

    if ((uint64_t)data_len > UINT32_MAX)
        return -1;
    total = (size_t)payload_total_len(data_len, ext_len);
    p = malloc(total);
    if (!p)
        return -1;
    be32_write(p, (uint32_t)data_len);
    if (data_len)
        memcpy(p + PAYLOAD_SIZE_LEN, data, data_len);
    memcpy(p + PAYLOAD_SIZE_LEN + data_len, ext, ext_len);
    p[total - 1] = 0;
    *out = p;
    *out_len = total;
    return 0;
}

int payload_extract(steg_reader_t *r, uint8_t **data, size_t *data_len, char *ext,
                    size_t ext_cap, char *err, size_t err_cap)
{
    uint8_t sz[PAYLOAD_SIZE_LEN];
    uint32_t size;
    uint8_t *buf;
    size_t n = 0;
    int found = 0;

    if (ext_cap < PAYLOAD_MAX_EXT_LEN + 1) {
        snprintf(err, err_cap, "internal error: extension buffer too small");
        return -1;
    }
    if (steg_read(r, sz, sizeof sz) != 0) {
        snprintf(err, err_cap, "carrier too small to hold a size field");
        return -1;
    }
    size = be32_read(sz);
    if ((uint64_t)size + 2 > steg_reader_remaining(r)) {
        snprintf(err, err_cap,
                 "the hidden size field says %" PRIu32
                 " bytes but at most %" PRIu64 " payload bytes fit in this carrier",
                 size, steg_reader_remaining(r));
        return -1;
    }
    buf = malloc(size ? size : 1);
    if (!buf) {
        snprintf(err, err_cap, "out of memory");
        return -1;
    }
    if (steg_read(r, buf, size) != 0) {
        free(buf);
        snprintf(err, err_cap, "carrier ends inside the hidden data");
        return -1;
    }
    while (n < PAYLOAD_MAX_EXT_LEN + 1) {
        uint8_t c;
        if (steg_read(r, &c, 1) != 0)
            break;
        ext[n] = (char)c;
        if (c == 0) {
            found = 1;
            break;
        }
        n++;
    }
    if (!found) {
        free(buf);
        snprintf(err, err_cap, "malformed extension field (no terminating NUL within 32 bytes)");
        return -1;
    }
    if (!ext_bytes_valid(ext, n)) {
        free(buf);
        snprintf(err, err_cap,
                 "malformed extension field (must start with '.' and contain only printable "
                 "ASCII without path separators)");
        return -1;
    }
    *data = buf;
    *data_len = size;
    return 0;
}
