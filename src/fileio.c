#include "fileio.h"

#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>

#define CHUNK (64u * 1024u)

int fileio_read_all(const char *path, size_t max_len, uint8_t **buf, size_t *len,
                    char *err, size_t err_cap)
{
    FILE *f = fopen(path, "rb");
    uint8_t *data = NULL;
    size_t used = 0, cap = 0;

    *buf = NULL;
    *len = 0;
    if (!f) {
        snprintf(err, err_cap, "cannot read '%s': %s", path, strerror(errno));
        return -1;
    }
    for (;;) {
        if (cap - used < CHUNK) {
            size_t ncap = cap ? cap * 2 : CHUNK * 2;
            uint8_t *nd = realloc(data, ncap);
            if (!nd) {
                free(data);
                fclose(f);
                snprintf(err, err_cap, "cannot read '%s': out of memory", path);
                return -1;
            }
            data = nd;
            cap = ncap;
        }
        size_t n = fread(data + used, 1, CHUNK, f);
        used += n;
        if (used > max_len) {
            free(data);
            fclose(f);
            return -2;
        }
        if (n < CHUNK) {
            if (ferror(f)) {
                snprintf(err, err_cap, "cannot read '%s': %s", path, strerror(errno));
                free(data);
                fclose(f);
                return -1;
            }
            break;
        }
    }
    fclose(f);
    *buf = data;
    *len = used;
    return 0;
}

int fileio_write_atomic(const char *path, const uint8_t *buf, size_t len, char *err,
                        size_t err_cap)
{
    const char *slash = strrchr(path, '/');
    size_t dirlen = slash ? (size_t)(slash - path) : 0;
    size_t tlen = dirlen + 1 + strlen(FILEIO_TMP_PREFIX) + 6 + 3;
    char *tmp = malloc(tlen);
    int fd;
    size_t off = 0;

    if (!tmp) {
        snprintf(err, err_cap, "cannot write '%s': out of memory", path);
        return -1;
    }
    if (slash && dirlen == 0)
        snprintf(tmp, tlen, "/%sXXXXXX", FILEIO_TMP_PREFIX);
    else if (slash)
        snprintf(tmp, tlen, "%.*s/%sXXXXXX", (int)dirlen, path, FILEIO_TMP_PREFIX);
    else
        snprintf(tmp, tlen, "./%sXXXXXX", FILEIO_TMP_PREFIX);

    fd = mkstemp(tmp);
    if (fd < 0)
        goto fail;
    {
        mode_t um = umask(0);
        umask(um);
        if (fchmod(fd, 0666 & ~um) != 0)
            goto fail_close;
    }
    while (off < len) {
        ssize_t w = write(fd, buf + off, len - off);
        if (w < 0) {
            if (errno == EINTR)
                continue;
            goto fail_close;
        }
        off += (size_t)w;
    }
    if (close(fd) != 0)
        goto fail;
    if (rename(tmp, path) != 0)
        goto fail;
    free(tmp);
    return 0;

fail_close:
    {
        int e = errno;
        close(fd);
        errno = e;
    }
fail:
    snprintf(err, err_cap, "cannot write '%s': %s", path, strerror(errno));
    unlink(tmp);
    free(tmp);
    return -1;
}
