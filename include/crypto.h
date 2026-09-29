#ifndef CRYPTO_H
#define CRYPTO_H

#include <stddef.h>
#include <stdint.h>

typedef enum {
    CIPHER_NONE = 0,
    CIPHER_AES128,
    CIPHER_AES192,
    CIPHER_AES256,
    CIPHER_3DES
} cipher_alg_t;
typedef enum {
    CIPHER_MODE_NONE = 0,
    CIPHER_MODE_ECB,
    CIPHER_MODE_CFB,
    CIPHER_MODE_OFB,
    CIPHER_MODE_CBC
} cipher_mode_t;

/* Key and IV come from ONE PBKDF2-HMAC-SHA256 call with a fixed all-zero salt. */
#define CRYPTO_PBKDF2_ITERATIONS 10000
#define CRYPTO_SALT_LEN 8

const char *crypto_alg_name(cipher_alg_t a);
const char *crypto_mode_name(cipher_mode_t m);

/* Size of the ciphertext for plain_len bytes: PKCS5 padding for ecb/cbc, none for cfb/ofb. */
uint64_t crypto_ciphertext_len(cipher_alg_t a, cipher_mode_t m, uint64_t plain_len);

/* Both return 0 and a malloc'd buffer in *out (caller crypto_wipe + free), or -1 with err set. */
int crypto_encrypt(cipher_alg_t a, cipher_mode_t m, const char *password, const uint8_t *in,
                   size_t in_len, uint8_t **out, size_t *out_len, char *err, size_t err_cap);
int crypto_decrypt(cipher_alg_t a, cipher_mode_t m, const char *password, const uint8_t *in,
                   size_t in_len, uint8_t **out, size_t *out_len, char *err, size_t err_cap);

/* OPENSSL_cleanse wrapper so callers need no OpenSSL include. */
void crypto_wipe(void *p, size_t n);

#endif
