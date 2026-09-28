#include "steg.h"

const char *steg_method_name(steg_method_t m)
{
    switch (m) {
    case STEG_LSB1: return "LSB1";
    case STEG_LSB4: return "LSB4";
    case STEG_LSBI: return "LSBI";
    default: return "none";
    }
}

unsigned steg_bits_per_carrier_byte(steg_method_t m)
{
    switch (m) {
    case STEG_LSB1: return 1;
    case STEG_LSB4: return 4;
    default: return 0;
    }
}

uint64_t steg_capacity(steg_method_t m, size_t carrier_len)
{
    unsigned bits = steg_bits_per_carrier_byte(m);
    if (bits == 0)
        return 0;
    return (uint64_t)carrier_len * bits / 8;
}

int steg_embed(steg_method_t m, uint8_t *carrier, size_t carrier_len,
               const uint8_t *payload, size_t payload_len)
{
    if (steg_bits_per_carrier_byte(m) == 0 || payload_len > steg_capacity(m, carrier_len))
        return -1;
    if (m == STEG_LSB1) {
        for (size_t i = 0; i < payload_len; i++)
            for (unsigned j = 0; j < 8; j++)
                carrier[8 * i + j] = (uint8_t)((carrier[8 * i + j] & 0xFE) |
                                               ((payload[i] >> (7 - j)) & 1));
        return 0;
    }
    for (size_t i = 0; i < payload_len; i++) {
        carrier[2 * i] = (uint8_t)((carrier[2 * i] & 0xF0) | (payload[i] >> 4));
        carrier[2 * i + 1] = (uint8_t)((carrier[2 * i + 1] & 0xF0) | (payload[i] & 0x0F));
    }
    return 0;
}

void steg_reader_init(steg_reader_t *r, steg_method_t m, const uint8_t *carrier,
                      size_t carrier_len)
{
    r->method = m;
    r->carrier = carrier;
    r->carrier_len = carrier_len;
    r->pos = 0;
}

uint64_t steg_reader_remaining(const steg_reader_t *r)
{
    return (uint64_t)(r->carrier_len - r->pos) * steg_bits_per_carrier_byte(r->method) / 8;
}

int steg_read(steg_reader_t *r, uint8_t *out, size_t n)
{
    if (steg_bits_per_carrier_byte(r->method) == 0 || n > steg_reader_remaining(r))
        return -1;
    if (r->method == STEG_LSB1) {
        for (size_t i = 0; i < n; i++) {
            uint8_t b = 0;
            for (unsigned j = 0; j < 8; j++)
                b = (uint8_t)(b | ((r->carrier[r->pos + j] & 1) << (7 - j)));
            out[i] = b;
            r->pos += 8;
        }
        return 0;
    }
    for (size_t i = 0; i < n; i++) {
        out[i] = (uint8_t)(((r->carrier[r->pos] & 0x0F) << 4) | (r->carrier[r->pos + 1] & 0x0F));
        r->pos += 2;
    }
    return 0;
}
