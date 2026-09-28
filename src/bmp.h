#ifndef BMP_H
#define BMP_H

#include <stddef.h>
#include <stdint.h>

#define BMP_HEADER_LEN 54u

typedef struct {
    uint8_t *data;
    size_t size;
    size_t pixel_offset;
    size_t pixel_len;
    int32_t width;
    int32_t height;
    uint16_t bits_per_pixel;
    uint32_t compression;
} bmp_image_t;

enum { BMP_OK = 0, BMP_ERR_IO = -1, BMP_ERR_FORMAT = -2 };

int bmp_parse(const uint8_t *buf, size_t size, bmp_image_t *img, char *err, size_t err_cap);
int bmp_load(const char *path, bmp_image_t *img, char *err, size_t err_cap);
int bmp_save(const char *path, const bmp_image_t *img, char *err, size_t err_cap);
void bmp_free(bmp_image_t *img);

#endif
