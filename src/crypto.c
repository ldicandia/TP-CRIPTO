#include "crypto.h"

#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <openssl/crypto.h>
#include <openssl/err.h>
#include <openssl/evp.h>

#define CRYPTO_CHUNK 65536u

typedef struct {
    size_t key_len;
    size_t iv_len;
    size_t block;
} alg_params_t;

static const alg_params_t PARAMS[] = {
    {0, 0, 0},   /* CIPHER_NONE */
    {16, 16, 16}, /* aes128 */
    {24, 16, 16}, /* aes192 */
    {32, 16, 16}, /* aes256 */
    {24, 8, 8},   /* 3des (des-ede3, three keys) */
};

const char *crypto_alg_name(cipher_alg_t a)
{
    switch (a) {
    case CIPHER_AES128: return "aes128";
    case CIPHER_AES192: return "aes192";
    case CIPHER_AES256: return "aes256";
    case CIPHER_3DES: return "3des";
    default: return "none";
    }
}

const char *crypto_mode_name(cipher_mode_t m)
{
    switch (m) {
    case CIPHER_MODE_ECB: return "ecb";
    case CIPHER_MODE_CFB: return "cfb";
    case CIPHER_MODE_OFB: return "ofb";
    case CIPHER_MODE_CBC: return "cbc";
    default: return "none";
    }
}

void crypto_wipe(void *p, size_t n)
{
    if (p && n)
        OPENSSL_cleanse(p, n);
}

static int has_padding(cipher_mode_t m) { return m == CIPHER_MODE_ECB || m == CIPHER_MODE_CBC; }

static int params_valid(cipher_alg_t a, cipher_mode_t m)
{
    return a >= CIPHER_AES128 && a <= CIPHER_3DES && m >= CIPHER_MODE_ECB && m <= CIPHER_MODE_CBC;
}

uint64_t crypto_ciphertext_len(cipher_alg_t a, cipher_mode_t m, uint64_t plain_len)
{
    if (!params_valid(a, m) || !has_padding(m))
        return plain_len;
    return (plain_len / PARAMS[a].block + 1) * PARAMS[a].block;
}

/* CFB is always the 8-bit variant (cfb8), OFB the full-block one (spec page 5). */
static const EVP_CIPHER *select_cipher(cipher_alg_t a, cipher_mode_t m)
{
    switch (a) {
    case CIPHER_AES128:
        return m == CIPHER_MODE_ECB   ? EVP_aes_128_ecb()
               : m == CIPHER_MODE_CFB ? EVP_aes_128_cfb8()
               : m == CIPHER_MODE_OFB ? EVP_aes_128_ofb()
                                      : EVP_aes_128_cbc();
    case CIPHER_AES192:
        return m == CIPHER_MODE_ECB   ? EVP_aes_192_ecb()
               : m == CIPHER_MODE_CFB ? EVP_aes_192_cfb8()
               : m == CIPHER_MODE_OFB ? EVP_aes_192_ofb()
                                      : EVP_aes_192_cbc();
    case CIPHER_AES256:
        return m == CIPHER_MODE_ECB   ? EVP_aes_256_ecb()
               : m == CIPHER_MODE_CFB ? EVP_aes_256_cfb8()
               : m == CIPHER_MODE_OFB ? EVP_aes_256_ofb()
                                      : EVP_aes_256_cbc();
    case CIPHER_3DES:
        return m == CIPHER_MODE_ECB   ? EVP_des_ede3_ecb()
               : m == CIPHER_MODE_CFB ? EVP_des_ede3_cfb8()
               : m == CIPHER_MODE_OFB ? EVP_des_ede3_ofb()
                                      : EVP_des_ede3_cbc();
    default:
        return NULL;
    }
}

static int crypt_run(int enc, cipher_alg_t a, cipher_mode_t m, const char *password,
                     const uint8_t *in, size_t in_len, uint8_t **out, size_t *out_len, char *err,
                     size_t err_cap)
{
    uint8_t buf[EVP_MAX_KEY_LENGTH + EVP_MAX_IV_LENGTH];
    static const uint8_t salt[CRYPTO_SALT_LEN] = {0};
    const alg_params_t *p;
    const EVP_CIPHER *cipher;
    EVP_CIPHER_CTX *ctx = NULL;
    uint8_t *o = NULL;
    size_t pw_len, off = 0, done = 0;
    int ok = -1, n = 0;
    const char *msg = "OpenSSL error";

    *out = NULL;
    *out_len = 0;
    if (!params_valid(a, m)) {
        snprintf(err, err_cap, "no algorithm or mode selected");
        return -1;
    }
    p = &PARAMS[a];
    if (!enc && in_len == 0) {
        snprintf(err, err_cap, "the ciphertext is empty");
        return -1;
    }
    if (!enc && has_padding(m) && in_len % p->block != 0) {
        snprintf(err, err_cap, "the ciphertext length %zu is not a multiple of the %zu-byte block",
                 in_len, p->block);
        return -1;
    }
    pw_len = strlen(password);
    if (pw_len > INT_MAX) {
        snprintf(err, err_cap, "the password is too long");
        return -1;
    }
    if (in_len > SIZE_MAX - p->block) {
        snprintf(err, err_cap, "the data is too large");
        return -1;
    }
    cipher = select_cipher(a, m);
    if (!cipher) {
        snprintf(err, err_cap, "no algorithm or mode selected");
        return -1;
    }
    if (PKCS5_PBKDF2_HMAC(password, (int)pw_len, salt, CRYPTO_SALT_LEN, CRYPTO_PBKDF2_ITERATIONS,
                          EVP_sha256(), (int)(p->key_len + p->iv_len), buf) != 1) {
        OPENSSL_cleanse(buf, sizeof buf);
        ERR_clear_error();
        snprintf(err, err_cap, "OpenSSL error (key derivation)");
        return -1;
    }
    o = malloc(in_len + p->block);
    ctx = EVP_CIPHER_CTX_new();
    if (!o || !ctx) {
        msg = "out of memory";
        goto done;
    }
    /* key = buf[0, key_len), IV = buf[key_len, key_len + iv_len); ECB ignores the IV. */
    if (EVP_CipherInit_ex(ctx, cipher, NULL, buf, m == CIPHER_MODE_ECB ? NULL : buf + p->key_len,
                          enc) != 1)
        goto done;
    if (EVP_CIPHER_CTX_set_padding(ctx, has_padding(m) ? 1 : 0) != 1)
        goto done;
    while (off < in_len) {
        size_t chunk = in_len - off > CRYPTO_CHUNK ? CRYPTO_CHUNK : in_len - off;
        if (EVP_CipherUpdate(ctx, o + done, &n, in + off, (int)chunk) != 1)
            goto done;
        done += (size_t)n;
        off += chunk;
    }
    if (EVP_CipherFinal_ex(ctx, o + done, &n) != 1) {
        if (!enc)
            msg = "bad padding";
        goto done;
    }
    done += (size_t)n;
    *out = o;
    *out_len = done;
    o = NULL;
    ok = 0;
done:
    if (ok != 0)
        snprintf(err, err_cap, "%s", msg);
    OPENSSL_cleanse(buf, sizeof buf);
    if (ctx)
        EVP_CIPHER_CTX_free(ctx);
    if (o) {
        OPENSSL_cleanse(o, in_len + p->block);
        free(o);
    }
    ERR_clear_error();
    return ok;
}

int crypto_encrypt(cipher_alg_t a, cipher_mode_t m, const char *password, const uint8_t *in,
                   size_t in_len, uint8_t **out, size_t *out_len, char *err, size_t err_cap)
{
    return crypt_run(1, a, m, password, in, in_len, out, out_len, err, err_cap);
}

int crypto_decrypt(cipher_alg_t a, cipher_mode_t m, const char *password, const uint8_t *in,
                   size_t in_len, uint8_t **out, size_t *out_len, char *err, size_t err_cap)
{
    return crypt_run(0, a, m, password, in, in_len, out, out_len, err, err_cap);
}
