#ifndef FILEIO_H
#define FILEIO_H

#include <stddef.h>
#include <stdint.h>

#define FILEIO_TMP_PREFIX ".stegobmp-tmp-"

int fileio_read_all(const char *path, size_t max_len, uint8_t **buf, size_t *len,
                    char *err, size_t err_cap);
int fileio_write_atomic(const char *path, const uint8_t *buf, size_t len, char *err,
                        size_t err_cap);

#endif
