#ifndef FLINT_RT_H
#define FLINT_RT_H

#include <stdbool.h>
#include <stddef.h>
#include <string.h>

// ============================================================================
// BASE TYPES// ============================================================================

typedef char *flint_str;

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
        size_t capacity;                \
    } Name;

DECLARE_FLINT_ARRAY(long long, flint_int_array)
DECLARE_FLINT_ARRAY(flint_str, flint_str_array)
DECLARE_FLINT_ARRAY(bool, flint_bool_array)

#define FLINT_MAKE_ARRAY(Type, StructName, ...)                \
    ({                                                         \
        Type _temp[] = {__VA_ARGS__};                          \
        size_t _c = sizeof(_temp) / sizeof(Type);              \
        size_t _cap = _c < 8 ? 8 : _c * 2;                     \
        StructName _arr;                                       \
        _arr.count = _c;                                       \
        _arr.capacity = _cap;                                  \
        _arr.items = (Type *)flint_alloc(_cap * sizeof(Type)); \
        if (_c > 0)                                            \
            memcpy(_arr.items, _temp, _c * sizeof(Type));      \
        _arr;                                                  \
    })

#define flint_push(arr, val)                                                         \
    do                                                                               \
    {                                                                                \
        if ((arr).count >= (arr).capacity)                                           \
        {                                                                            \
            size_t _new_cap = (arr).capacity == 0 ? 8 : (arr).capacity * 2;          \
            void *_new_items = flint_alloc(_new_cap * sizeof(*(arr).items));         \
            if ((arr).count > 0)                                                     \
                memcpy(_new_items, (arr).items, (arr).count * sizeof(*(arr).items)); \
            (arr).items = _new_items;                                                \
            (arr).capacity = _new_cap;                                               \
        }                                                                            \
        (arr).items[(arr).count++] = (val);                                          \
    } while (0)

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
// DICTIONARY
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
// I/O AND STDLIB
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
flint_str flint_trim(flint_str text);
flint_str flint_replace(flint_str text, flint_str target, flint_str replacement);
flint_str_array flint_split(flint_str text, flint_str delimiter);
#endif