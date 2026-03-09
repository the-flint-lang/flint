#ifndef FLINT_RT_H
#define FLINT_RT_H

#include <stdbool.h>
#include <stddef.h>

// ============================================================================
// TIPOS BASE
// ============================================================================

typedef char *flint_str; // Precisa vir primeiro — usado em tudo abaixo

typedef enum
{
    FLINT_VAL_NULL,
    FLINT_VAL_INT,
    FLINT_VAL_STR,
    FLINT_VAL_BOOL,
} FlintValType;

typedef struct
{
    FlintValType type;
    union
    {
        long long i;
        flint_str s;
        bool b;
    } as;
} FlintValue;

typedef struct
{
    flint_str key;
    FlintValue value;
    bool occupied;
} FlintDictEntry;

typedef struct
{
    FlintDictEntry *entries;
    size_t capacity;
    size_t count;
} FlintDict;

// ============================================================================
// ARRAYS
// ============================================================================

#define DECLARE_FLINT_ARRAY(Type, Name) \
    typedef struct                      \
    {                                   \
        Type *items;                    \
        size_t count;                   \
    } Name;

DECLARE_FLINT_ARRAY(long long, flint_int_array)
DECLARE_FLINT_ARRAY(flint_str, flint_str_array)
DECLARE_FLINT_ARRAY(bool, flint_bool_array)

#define FLINT_MAKE_ARRAY(Type, StructName, ...) \
    (StructName) { .items = (Type[]){__VA_ARGS__}, .count = sizeof((Type[]){__VA_ARGS__}) / sizeof(Type) }

#define flint_len(arr) (long long)((arr).count)

// ============================================================================
// RUNTIME
// ============================================================================

void flint_init(int argc, char **argv);
void flint_deinit();
void *flint_alloc(size_t size);
void flint_panic(const char *message);
void flint_exit(int code);

// ============================================================================
// DICIONÁRIO
// ============================================================================

FlintDict *flint_dict_new(size_t capacity);
void flint_dict_set(FlintDict *dict, flint_str key, FlintValue value);
FlintValue flint_dict_get(FlintDict *dict, flint_str key);

// ============================================================================
// BOXING
// ============================================================================

FlintValue flint_make_int(long long val);
FlintValue flint_make_str(flint_str val);
FlintValue flint_make_bool(bool val);

// ============================================================================
// I/O E STDLIB
// ============================================================================

void flint_print_str(flint_str text);
void flint_print_int(long long num);
void flint_print_val(FlintValue val);
void flint_print_dict(FlintDict *dict);

#define flint_print(X) _Generic((X), \
    int: flint_print_int,            \
    long: flint_print_int,           \
    long long: flint_print_int,      \
    FlintValue: flint_print_val,     \
    FlintDict *: flint_print_dict,   \
    default: flint_print_str)(X)

flint_str flint_env(flint_str name);
flint_str flint_exec(flint_str cmd);
flint_str flint_read_file(flint_str filepath);
void flint_write_file(flint_str text, flint_str filepath);
bool flint_file_exists(flint_str filepath);
flint_str_array flint_args();
flint_str_array flint_lines(flint_str text);
flint_str_array flint_grep(flint_str_array lines, flint_str pattern);
flint_str flint_join(flint_str_array lines, flint_str separator);
flint_int_array flint_range(long long start, long long end);

#endif