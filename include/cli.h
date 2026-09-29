#ifndef CLI_H
#define CLI_H

#include <stddef.h>
#include <stdio.h>

#include "crypto.h"
#include "steg.h"

typedef enum { CLI_MODE_NONE = 0, CLI_MODE_EMBED, CLI_MODE_EXTRACT } cli_mode_t;

typedef struct {
    cli_mode_t mode;
    const char *in_path;
    const char *carrier_path;
    const char *out_path;
    steg_method_t steg;
    cipher_alg_t alg;
    cipher_mode_t cipher_mode;
    const char *password;
} cli_options_t;

int cli_parse(int argc, char **argv, cli_options_t *opts, char *err, size_t err_cap);
void cli_print_usage(FILE *out);

#endif
