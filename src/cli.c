#include "cli.h"

#include <string.h>

static const char *const known_flags[] = {"-embed", "-extract", "-in", "-p", "-out", "-steg", "-a", "-m", "-pass"};
#define NFLAGS 9

static int flag_index(const char *s)
{
    for (int i = 0; i < NFLAGS; i++)
        if (strcmp(s, known_flags[i]) == 0)
            return i;
    return -1;
}

static int set_choice(const char *flag, const char *value, const char *const *names,
                      int count, const char *expected, int *out, char *err, size_t err_cap)
{
    for (int i = 0; i < count; i++) {
        if (strcmp(value, names[i]) == 0) {
            *out = i + 1;
            return 0;
        }
    }
    snprintf(err, err_cap, "invalid value for %s: '%s' (expected %s)", flag, value, expected);
    return -1;
}

int cli_parse(int argc, char **argv, cli_options_t *opts, char *err, size_t err_cap)
{
    static const char *const steg_names[] = {"LSB1", "LSB4", "LSBI"};
    static const char *const alg_names[] = {"aes128", "aes192", "aes256", "3des"};
    static const char *const mode_names[] = {"ecb", "cfb", "ofb", "cbc"};

    int seen[NFLAGS] = {0};

    memset(opts, 0, sizeof *opts);
    for (int i = 1; i < argc; i++) {
        const char *a = argv[i];
        const char **slot = NULL;
        int v;
        int fi = flag_index(a);

        if (fi < 0) {
            snprintf(err, err_cap, "unknown parameter '%s'", a);
            return -1;
        }
        if (seen[fi]) {
            snprintf(err, err_cap, "duplicate parameter %s", a);
            return -1;
        }
        seen[fi] = 1;
        if (strcmp(a, "-embed") == 0) {
            opts->mode = CLI_MODE_EMBED;
            continue;
        }
        if (strcmp(a, "-extract") == 0) {
            opts->mode = CLI_MODE_EXTRACT;
            continue;
        }
        if (strcmp(a, "-in") == 0)
            slot = &opts->in_path;
        else if (strcmp(a, "-p") == 0)
            slot = &opts->carrier_path;
        else if (strcmp(a, "-out") == 0)
            slot = &opts->out_path;
        else if (strcmp(a, "-pass") == 0)
            slot = &opts->password;

        if (i + 1 >= argc) {
            snprintf(err, err_cap, "missing value for %s", a);
            return -1;
        }
        i++;
        if (argv[i][0] == 0) {
            snprintf(err, err_cap, "empty value for %s", a);
            return -1;
        }
        if (flag_index(argv[i]) >= 0) {
            snprintf(err, err_cap, "missing value for %s", a);
            return -1;
        }
        if (slot) {
            *slot = argv[i];
        } else if (strcmp(a, "-steg") == 0) {
            if (set_choice(a, argv[i], steg_names, 3, "LSB1 | LSB4 | LSBI", &v, err, err_cap))
                return -1;
            opts->steg = (steg_method_t)v;
        } else if (strcmp(a, "-a") == 0) {
            if (set_choice(a, argv[i], alg_names, 4, "aes128 | aes192 | aes256 | 3des", &v, err,
                           err_cap))
                return -1;
            opts->alg = (cipher_alg_t)v;
        } else {
            if (set_choice(a, argv[i], mode_names, 4, "ecb | cfb | ofb | cbc", &v, err, err_cap))
                return -1;
            opts->cipher_mode = (cipher_mode_t)v;
        }
    }
    if (seen[0] && seen[1]) {
        snprintf(err, err_cap, "choose exactly one of -embed or -extract");
        return -1;
    }
    if (opts->mode == CLI_MODE_NONE) {
        snprintf(err, err_cap, "missing -embed or -extract");
        return -1;
    }
    if (opts->mode == CLI_MODE_EXTRACT && opts->in_path) {
        snprintf(err, err_cap, "-in is not valid with -extract");
        return -1;
    }
    {
        const char *mode = opts->mode == CLI_MODE_EMBED ? "-embed" : "-extract";
        const char *missing = NULL;

        if (opts->mode == CLI_MODE_EMBED && !opts->in_path)
            missing = "-in";
        else if (!opts->carrier_path)
            missing = "-p";
        else if (!opts->out_path)
            missing = "-out";
        else if (opts->steg == STEG_NONE)
            missing = "-steg";
        if (missing) {
            snprintf(err, err_cap, "missing required parameter %s for %s", missing, mode);
            return -1;
        }
    }
    return 0;
}

void cli_print_usage(FILE *out)
{
    fputs("Usage:\n"
          "  stegobmp -embed -in <file> -p <bitmapfile> -out <bitmapfile> -steg <LSB1 | LSB4 | "
          "LSBI> [-a <aes128 | aes192 | aes256 | 3des>] [-m <ecb | cfb | ofb | cbc>] [-pass "
          "<password>]\n"
          "  stegobmp -extract -p <bitmapfile> -out <file> -steg <LSB1 | LSB4 | LSBI> [-a "
          "<aes128 | aes192 | aes256 | 3des>] [-m <ecb | cfb | ofb | cbc>] [-pass <password>]\n",
          out);
}
