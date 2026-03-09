#ifndef FLINT_RT_H
#define FLINT_RT_H

#include <stdbool.h>
#include <stddef.h>
#include <string.h>

typedef const char *flint_str;

typedef struct FlintDict FlintDict;

typedef enum
{
    FLINT_VAL_NULL,
    FLINT_VAL_INT,
    FLINT_VAL_BOOL,
    FLINT_VAL_STR,
    FLINT_VAL_DICT,
    FLINT_VAL_ERROR
} FlintValType;

typedef struct
{
    FlintValType type;

    union
    {
        long long i;
        bool b;
        flint_str s;
        FlintDict *d;
    } as;

} FlintValue;

/* =========================
   MEMORY
   ========================= */

void flint_init(int argc, char **argv);
void flint_deinit();

void *flint_alloc(size_t size);
void flint_arena_reset();

void flint_panic(const char *msg);
void flint_exit(int code);

/* =========================
   ARRAYS
   ========================= */

#define DECLARE_FLINT_ARRAY(Type, Name) \
    typedef struct                      \
    {                                   \
        Type *items;                    \
        size_t count;                   \
        size_t capacity;                \
    } Name;

DECLARE_FLINT_ARRAY(long long, flint_int_array)
DECLARE_FLINT_ARRAY(flint_str, flint_str_array)

#define flint_array_init(a) \
    do                      \
    {                       \
        (a).items = NULL;   \
        (a).count = 0;      \
        (a).capacity = 0;   \
    } while (0)

#define FLINT_MAKE_ARRAY(ItemType, ArrayType, ...)                   \
    ({                                                               \
        ItemType _tmp[] = {__VA_ARGS__};                             \
        size_t _cnt = sizeof(_tmp) / sizeof(ItemType);               \
        ItemType *_arr = flint_alloc(_cnt * sizeof(ItemType));       \
        memcpy(_arr, _tmp, sizeof(_tmp));                            \
        (ArrayType){.items = _arr, .count = _cnt, .capacity = _cnt}; \
    })

#define flint_array_push(arr, val)                                                  \
    do                                                                              \
    {                                                                               \
        if ((arr).count >= (arr).capacity)                                          \
        {                                                                           \
            size_t newcap = (arr).capacity == 0 ? 8 : (arr).capacity * 2;           \
            void *new_items = flint_alloc(newcap * sizeof(*(arr).items));           \
            if ((arr).items)                                                        \
                memcpy(new_items, (arr).items, (arr).count * sizeof(*(arr).items)); \
            (arr).items = new_items;                                                \
            (arr).capacity = newcap;                                                \
        }                                                                           \
        (arr).items[(arr).count++] = val;                                           \
    } while (0)

#define flint_push(arr, val) flint_array_push(arr, val)

#define flint_len(arr) ((long long)((arr).count))

/* =========================
   DICTIONARY
   ========================= */

typedef struct
{
    flint_str key;
    FlintValue value;
    bool occupied;

} FlintDictEntry;

struct FlintDict
{
    FlintDictEntry *entries;
    size_t capacity;
    size_t count;
};

FlintDict *flint_dict_new(size_t capacity);
void flint_dict_set(FlintDict *dict, flint_str key, FlintValue value);
FlintValue flint_dict_get(FlintDict *dict, flint_str key);

/* =========================
   VALUE CONSTRUCTORS
   ========================= */

FlintValue flint_make_int(long long v);
FlintValue flint_make_bool(bool v);
FlintValue flint_make_str(flint_str v);
FlintValue flint_make_error(flint_str msg);

bool flint_is_err(FlintValue v);
flint_str flint_get_err(FlintValue v);

/* =========================
   VALUE CONSTRUCTORS E BOXING
   ========================= */

FlintValue flint_make_int(long long v);
FlintValue flint_make_bool(bool v);
FlintValue flint_make_str(flint_str v);

static inline FlintValue flint_identity(FlintValue v) { return v; }

#define FLINT_BOX(X) _Generic((X), \
    int: flint_make_int,           \
    long: flint_make_int,          \
    long long: flint_make_int,     \
    bool: flint_make_bool,         \
    char *: flint_make_str,        \
    const char *: flint_make_str,  \
    FlintValue: flint_identity)(X)

#define FLINT_SET(dict, key, val) flint_dict_set((dict), (key), FLINT_BOX(val))

/* =========================
   PRINT
   ========================= */

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

/* =========================
   FILESYSTEM
   ========================= */

flint_str flint_read_file(flint_str filepath);
void flint_write_file(flint_str text, flint_str filepath);
bool flint_file_exists(flint_str filepath);

/* =========================
   PROCESS
   ========================= */

flint_str flint_exec(flint_str cmd);

/* =========================
   ENV
   ========================= */

flint_str flint_env(flint_str name);
flint_str_array flint_args();

/* =========================
   STRINGS
   ========================= */

flint_str_array flint_lines(flint_str text);
flint_str_array flint_split(flint_str text, flint_str delimiter);
flint_str flint_join(flint_str_array arr, flint_str sep);

flint_str flint_trim(flint_str text);
flint_str_array flint_grep(flint_str_array lines, flint_str pattern);
flint_str flint_replace(flint_str text, flint_str target, flint_str repl);

flint_str flint_to_str(FlintValue v);
flint_str flint_int_to_str(long long num);
flint_str flint_concat(flint_str a, flint_str b);

/* =========================
   UTIL
   ========================= */

flint_int_array flint_range(long long start, long long end);

/* =========================
   NETWORK
   ========================= */

FlintValue flint_fetch(flint_str url);

/* =========================
   JSON
   ========================= */

FlintDict *flint_parse_json(flint_str text);
FlintValue flint_dict_get(FlintDict *d, flint_str key);

#endif