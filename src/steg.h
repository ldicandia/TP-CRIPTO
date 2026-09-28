#ifndef STEG_H
#define STEG_H

#include <stddef.h>
#include <stdint.h>

typedef enum { STEG_NONE = 0, STEG_LSB1, STEG_LSB4, STEG_LSBI } steg_method_t;

const char *steg_method_name(steg_method_t m);
unsigned steg_bits_per_carrier_byte(steg_method_t m);
uint64_t steg_capacity(steg_method_t m, size_t carrier_len);
int steg_embed(steg_method_t m, uint8_t *carrier, size_t carrier_len,
               const uint8_t *payload, size_t payload_len);

typedef struct {
    steg_method_t method;
    const uint8_t *carrier;
    size_t carrier_len;
    size_t pos;
} steg_reader_t;

void steg_reader_init(steg_reader_t *r, steg_method_t m, const uint8_t *carrier,
                      size_t carrier_len);
uint64_t steg_reader_remaining(const steg_reader_t *r);
int steg_read(steg_reader_t *r, uint8_t *out, size_t n);

#endif
