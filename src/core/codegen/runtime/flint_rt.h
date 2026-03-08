#ifndef FLINT_RT_H
#define FLINT_RT_H

#include <stdbool.h>
#include <stddef.h>

typedef char *flint_str;

typedef struct
{
    flint_str *items;
    size_t count;
} flint_str_array;

void flint_init(int argc, char **argv);

void flint_deinit();

void *flint_alloc(size_t size);

void flint_panic(const char *message);

flint_str_array flint_args();

flint_str flint_read_file(flint_str filepath);
void flint_write_file(flint_str text, flint_str filepath);
bool flint_file_exists(flint_str filepath);

void flint_exit(int code);

// ============================================================================
// THE STANDARD LIBRARY (I/O & Utilities)
// ============================================================================

void flint_print_str(flint_str text);
void flint_print_int(long long num);

#define flint_print(X) _Generic((X), \
    int: flint_print_int,            \
    long: flint_print_int,           \
    long long: flint_print_int,      \
    default: flint_print_str)(X)

flint_str flint_env(flint_str name);
flint_str flint_exec(flint_str cmd);
void flint_exit(int code);

flint_str_array flint_lines(flint_str text);

flint_str_array flint_grep(flint_str_array lines, flint_str pattern);

flint_str flint_join(flint_str_array lines, flint_str separator);

#endif