#ifndef FLINT_RT_H
#define FLINT_RT_H

#include <stdbool.h>
#include <stddef.h>

// ============================================================================
// BASE TYPES AND DATA STRUCTURES (The Array Power Plant)
// ============================================================================

typedef char *flint_str;

// MACRO: Make magically typed Array Structs
#define DECLARE_FLINT_ARRAY(Type, Name) \
    typedef struct                      \
    {                                   \
        Type *items;                    \
        size_t count;                   \
    } Name;

// The C compiler generates the three structs at compile time
DECLARE_FLINT_ARRAY(long long, flint_int_array)
DECLARE_FLINT_ARRAY(flint_str, flint_str_array)
DECLARE_FLINT_ARRAY(bool, flint_bool_array)

// sizeof calculates the exact size of the list at compile time. Zero CPU cost.
#define FLINT_MAKE_ARRAY(Type, StructName, ...) \
    (StructName) { .items = (Type[]){__VA_ARGS__}, .count = sizeof((Type[]){__VA_ARGS__}) / sizeof(Type) }

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