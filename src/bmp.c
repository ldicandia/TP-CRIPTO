#include "bmp.h"

#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "fileio.h"

static uint32_t le16(const uint8_t *p) { return (uint32_t)p[0] | ((uint32_t)p[1] << 8); }

static uint32_t le32(const uint8_t *p)
{
    return (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) |
           ((uint32_t)p[3] << 24);
}

static int64_t le32s(const uint8_t *p) { return (int64_t)(int32_t)le32(p); }

int bmp_parse(const uint8_t *buf, size_t size, bmp_image_t *img, char *err, size_t err_cap)
{
    uint32_t bi_size, comp, off, bpp;
    int64_t w, h, rows;
    uint64_t row, stride, need, avail;

    if (size < BMP_HEADER_LEN) {
        snprintf(err, err_cap, "not a BMP file: shorter than the 54-byte header");
        return BMP_ERR_FORMAT;
    }
    if (buf[0] != 'B' || buf[1] != 'M') {
        snprintf(err, err_cap, "not a BMP file: missing 'BM' signature");
        return BMP_ERR_FORMAT;
    }
    bi_size = le32(buf + 14);
    if (bi_size != 40) {
        snprintf(err, err_cap,
                 "unsupported BMP version: info header size %" PRIu32
                 " (only BMP V3 with a 40-byte header is supported)",
                 bi_size);
        return BMP_ERR_FORMAT;
    }
    bpp = le16(buf + 28);
    if (bpp != 24) {
        snprintf(err, err_cap,
                 "unsupported BMP: %" PRIu32 " bits per pixel (only 24 bits per pixel is supported)",
                 bpp);
        return BMP_ERR_FORMAT;
    }
    comp = le32(buf + 30);
    if (comp != 0) {
        snprintf(err, err_cap,
                 "unsupported BMP: compressed (biCompression = %" PRIu32
                 "; only uncompressed BMPs are supported)",
                 comp);
        return BMP_ERR_FORMAT;
    }
    w = le32s(buf + 18);
    h = le32s(buf + 22);
    if (w <= 0 || h == 0) {
        snprintf(err, err_cap, "invalid BMP dimensions %" PRId64 " x %" PRId64, w, h);
        return BMP_ERR_FORMAT;
    }
    off = le32(buf + 10);
    if (off < BMP_HEADER_LEN || off > size) {
        snprintf(err, err_cap, "invalid BMP pixel data offset %" PRIu32, off);
        return BMP_ERR_FORMAT;
    }
    row = (uint64_t)w * 3;
    stride = (row + 3) & ~(uint64_t)3;
    rows = h < 0 ? -h : h;
    need = stride * (uint64_t)rows;
    avail = (uint64_t)size - off;
    if (need > avail) {
        snprintf(err, err_cap,
                 "truncated BMP: pixel data needs %" PRIu64 " bytes but only %" PRIu64
                 " are present",
                 need, avail);
        return BMP_ERR_FORMAT;
    }
    img->size = size;
    img->pixel_offset = off;
    img->pixel_len = (size_t)need;
    img->width = (int32_t)w;
    img->height = (int32_t)h;
    img->bits_per_pixel = (uint16_t)bpp;
    img->compression = comp;
    return BMP_OK;
}

int bmp_load(const char *path, bmp_image_t *img, char *err, size_t err_cap)
{
    uint8_t *buf;
    size_t len;
    int rc;

    memset(img, 0, sizeof *img);
    if (fileio_read_all(path, SIZE_MAX, &buf, &len, err, err_cap) != 0)
        return BMP_ERR_IO;
    rc = bmp_parse(buf, len, img, err, err_cap);
    if (rc != BMP_OK) {
        free(buf);
        memset(img, 0, sizeof *img);
        return rc;
    }
    img->data = buf;
    return BMP_OK;
}

int bmp_save(const char *path, const bmp_image_t *img, char *err, size_t err_cap)
{
    return fileio_write_atomic(path, img->data, img->size, err, err_cap);
}

void bmp_free(bmp_image_t *img)
{
    free(img->data);
    memset(img, 0, sizeof *img);
}
