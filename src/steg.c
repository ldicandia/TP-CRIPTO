#include "steg.h"

/* LSBI: pixel bytes 0..3 hold the four pattern invert flags (plain LSB1);
 * message bits go into the LSB of every non-red byte (index % 3 != 2) from
 * index 4 on, MSB first. A pattern (bits 2-1 of the carrier byte) is stored
 * inverted when more of its message bits changed the LSB than left it. */
#define LSBI_FLAG_BYTES 4

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

int steg_method_supported(steg_method_t m)
{
    return m == STEG_LSB1 || m == STEG_LSB4 || m == STEG_LSBI;
}

/* Count of indices i < n with i % 3 != 2 (no multiplication: cannot overflow). */
static size_t lsbi_nonred(size_t n)
{
    return n - n / 3;
}

uint64_t steg_capacity(steg_method_t m, size_t carrier_len)
{
    if (m == STEG_LSBI) {
        if (carrier_len < LSBI_FLAG_BYTES)
            return 0;
        return (uint64_t)((lsbi_nonred(carrier_len) - lsbi_nonred(LSBI_FLAG_BYTES)) / 8);
    }
    unsigned bits = steg_bits_per_carrier_byte(m);
    if (bits == 0)
        return 0;
    return (uint64_t)carrier_len * bits / 8;
}

static int lsbi_embed(uint8_t *carrier, const uint8_t *payload, size_t payload_len)
{
    size_t changed[4] = {0, 0, 0, 0};
    size_t unchanged[4] = {0, 0, 0, 0};
    unsigned invert[4];
    size_t pos = LSBI_FLAG_BYTES;

    for (size_t i = 0; i < payload_len; i++) {
        for (unsigned j = 0; j < 8; j++) {
            unsigned bit = (payload[i] >> (7 - j)) & 1u;
            while (pos % 3 == 2)
                pos++;
            unsigned p = (carrier[pos] >> 1) & 3u;
            if ((carrier[pos] & 1u) != bit)
                changed[p]++;
            else
                unchanged[p]++;
            pos++;
        }
    }
    for (unsigned k = 0; k < 4; k++) {
        invert[k] = changed[k] > unchanged[k] ? 1u : 0u;
        carrier[k] = (uint8_t)((carrier[k] & 0xFE) | invert[k]);
    }
    pos = LSBI_FLAG_BYTES;
    for (size_t i = 0; i < payload_len; i++) {
        for (unsigned j = 0; j < 8; j++) {
            unsigned bit = (payload[i] >> (7 - j)) & 1u;
            while (pos % 3 == 2)
                pos++;
            unsigned p = (carrier[pos] >> 1) & 3u;
            carrier[pos] = (uint8_t)((carrier[pos] & 0xFE) | (bit ^ invert[p]));
            pos++;
        }
    }
    return 0;
}

int steg_embed(steg_method_t m, uint8_t *carrier, size_t carrier_len,
               const uint8_t *payload, size_t payload_len)
{
    if (!steg_method_supported(m) || payload_len > steg_capacity(m, carrier_len))
        return -1;
    if (m == STEG_LSBI)
        return lsbi_embed(carrier, payload, payload_len);
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
    r->lsbi_flags = 0;
    if (m == STEG_LSBI) {
        if (carrier_len >= LSBI_FLAG_BYTES) {
            for (unsigned k = 0; k < LSBI_FLAG_BYTES; k++)
                r->lsbi_flags |= (unsigned)(carrier[k] & 1u) << k;
            r->pos = LSBI_FLAG_BYTES;
        } else {
            r->pos = carrier_len;
        }
    }
}

uint64_t steg_reader_remaining(const steg_reader_t *r)
{
    if (r->method == STEG_LSBI) {
        if (r->pos >= r->carrier_len)
            return 0;
        return (uint64_t)((lsbi_nonred(r->carrier_len) - lsbi_nonred(r->pos)) / 8);
    }
    return (uint64_t)(r->carrier_len - r->pos) * steg_bits_per_carrier_byte(r->method) / 8;
}

int steg_read(steg_reader_t *r, uint8_t *out, size_t n)
{
    if (!steg_method_supported(r->method) || n > steg_reader_remaining(r))
        return -1;
    if (r->method == STEG_LSBI) {
        for (size_t i = 0; i < n; i++) {
            uint8_t b = 0;
            for (unsigned j = 0; j < 8; j++) {
                while (r->pos % 3 == 2)
                    r->pos++;
                uint8_t c = r->carrier[r->pos];
                unsigned bit = (c & 1u) ^ ((r->lsbi_flags >> ((c >> 1) & 3u)) & 1u);
                b = (uint8_t)((b << 1) | bit);
                r->pos++;
            }
            out[i] = b;
        }
        return 0;
    }
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
