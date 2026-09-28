#ifndef PAYLOAD_H
#define PAYLOAD_H

#include <stddef.h>
#include <stdint.h>

#include "steg.h"

#define PAYLOAD_SIZE_LEN 4u
#define PAYLOAD_MAX_EXT_LEN 32u

int payload_ext_is_valid(const char *ext);
int payload_extension_of(const char *path, char *ext, size_t ext_cap);
uint64_t payload_total_len(uint64_t data_len, size_t ext_len);
int payload_build(const uint8_t *data, size_t data_len, const char *ext, uint8_t **out,
                  size_t *out_len);
int payload_extract(steg_reader_t *r, uint8_t **data, size_t *data_len, char *ext,
                    size_t ext_cap, char *err, size_t err_cap);

#endif
