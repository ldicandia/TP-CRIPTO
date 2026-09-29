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

/* Encrypted framing: BE32(cipher size) || ciphertext. */
int payload_build_encrypted(const uint8_t *cipher, size_t cipher_len, uint8_t **out,
                            size_t *out_len);
int payload_read_cipher(steg_reader_t *r, uint8_t **cipher, size_t *cipher_len, char *err,
                        size_t err_cap);
/* Strict parse of a decrypted plaintext: BE32 size || data || ext || NUL, nothing after. */
int payload_parse(const uint8_t *buf, size_t len, uint8_t **data, size_t *data_len, char *ext,
                  size_t ext_cap, char *err, size_t err_cap);

#endif
