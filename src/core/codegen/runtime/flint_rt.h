#ifndef FLINT_RT_H
#define FLINT_RT_H

#include <stdbool.h>
#include <stddef.h>
#include <string.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

// ==========================================
// STRING SLICES
// ==========================================
typedef struct
{
    const char *ptr;
    size_t len;
} flint_str;

#define FLINT_STR(literal) (flint_str){.ptr = (literal), .len = sizeof(literal) - 1}

#define FLINT_SLICE(pointer, length) \
    (flint_str) { .ptr = (pointer), .len = (length) }
typedef struct FlintDict FlintDict;

typedef enum
{
    FLINT_VAL_NULL,
    FLINT_VAL_INT,
    FLINT_VAL_BOOL,
    FLINT_VAL_STR,
    FLINT_VAL_DICT,
    FLINT_VAL_ARRAY,
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
void flint_arena_reset();

void *flint_alloc_raw(size_t size);
void *flint_alloc_zero(size_t size);

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
        ItemType *_arr = flint_alloc_zero(_cnt * sizeof(ItemType));  \
        memcpy(_arr, _tmp, sizeof(_tmp));                            \
        (ArrayType){.items = _arr, .count = _cnt, .capacity = _cnt}; \
    })

#define flint_push(arr, val)                                                        \
    do                                                                              \
    {                                                                               \
        if ((arr).count >= (arr).capacity)                                          \
        {                                                                           \
            size_t newcap = (arr).capacity == 0 ? 8 : (arr).capacity * 2;           \
            void *new_items = flint_alloc_zero(newcap * sizeof(*(arr).items));      \
            if ((arr).items)                                                        \
                memcpy(new_items, (arr).items, (arr).count * sizeof(*(arr).items)); \
            (arr).items = new_items;                                                \
            (arr).capacity = newcap;                                                \
        }                                                                           \
        (arr).items[(arr).count++] = (val);                                         \
    } while (0)

#define flint_len(arr) ((long long)((arr).count))

/* =========================
   DICTIONARY
   ========================= */

typedef struct
{
    uint64_t hash;
    flint_str key;
    FlintValue value;
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

static inline FlintValue flint_dict_get_from_val(FlintValue v, flint_str key)
{
    if (v.type == FLINT_VAL_DICT && v.as.d)
        return flint_dict_get(v.as.d, key);
    return (FlintValue){FLINT_VAL_NULL};
}

#define FLINT_GET(obj, key) _Generic((obj), \
    FlintDict *: flint_dict_get,            \
    FlintValue: flint_dict_get_from_val)(obj, key)

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

static inline void flint_dict_set_from_val(FlintValue v, flint_str key, FlintValue val)
{
    if (v.type == FLINT_VAL_DICT && v.as.d)
        flint_dict_set(v.as.d, key, val);
}

#define FLINT_SET(obj, key, val) _Generic((obj), \
    FlintDict *: flint_dict_set,                 \
    FlintValue: flint_dict_set_from_val)(obj, key, FLINT_BOX(val))
/* =========================
   PRINT
   ========================= */

void flint_print_str(flint_str text);
void flint_print_int(long long num);
void flint_print_val(FlintValue val);
void flint_print_bool(bool b);
void flint_print_dict(FlintDict *dict);

#define flint_print(X) _Generic((X), \
    int: flint_print_int,            \
    long: flint_print_int,           \
    long long: flint_print_int,      \
    bool: flint_print_bool,          \
    FlintValue: flint_print_val,     \
    FlintDict *: flint_print_dict,   \
    default: flint_print_str)(X)

/* =========================
   FILESYSTEM
   ========================= */

FlintValue flint_read_file(flint_str filepath);
FlintValue flint_write_file(flint_str text, flint_str filepath);
bool flint_file_exists(flint_str filepath);

// new posix api (v1.7.1)
FlintValue flint_mkdir(flint_str path);
FlintValue flint_rm(flint_str path);
FlintValue flint_rm_dir(flint_str path);
FlintValue flint_touch(flint_str path);
FlintValue flint_ls(flint_str path);

bool flint_is_dir(flint_str path);
bool flint_is_file(flint_str path);

FlintValue flint_file_size(flint_str path);
FlintValue flint_mv(flint_str old_path, flint_str new_path);
FlintValue flint_copy(flint_str src, flint_str dest);

/* =========================
   PROCESS
   ========================= */

flint_str flint_exec(flint_str cmd);
FlintValue flint_spawn(flint_str cmd);

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
long long flint_count_matches(flint_str text, flint_str pattern);
flint_str flint_replace(flint_str text, flint_str target, flint_str repl);

flint_str flint_to_str(FlintValue v);
flint_str flint_int_to_str(long long num);
flint_str flint_concat(flint_str a, flint_str b);

static inline long long flint_to_int(FlintValue v)
{
    if (v.type == FLINT_VAL_INT)
        return v.as.i;
    return 0;
}

/* =========================
   UTIL
   ========================= */

flint_int_array flint_range(long long start, long long end);
bool flint_str_eql(flint_str a, flint_str b);

/* =========================
   NETWORK
   ========================= */

FlintValue flint_fetch(flint_str url);

/* =========================
   JSON
   ========================= */

FlintValue flint_parse_json(flint_str text);
FlintValue flint_dict_get(FlintDict *d, flint_str key);
static long long fast_atoll(const char **p);

// ============================================================================
// THE ARMOR OF AUTO-BOXING AND VARIADIC MACROS
// ============================================================================

static inline FlintValue flint_box_str_safe(flint_str s)
{
    return (FlintValue){FLINT_VAL_STR, .as.s = s};
}
static inline FlintValue flint_box_int_safe(int i)
{
    return (FlintValue){FLINT_VAL_INT, .as.i = i};
}
static inline FlintValue flint_box_bool_safe(bool b)
{
    return (FlintValue){FLINT_VAL_BOOL, .as.b = b};
}
static inline FlintValue flint_box_val_safe(FlintValue v)
{
    return v;
}

#undef FLINT_BOX
#define FLINT_BOX(...) _Generic((__VA_ARGS__), \
    int: flint_box_int_safe,                   \
    long: flint_box_int_safe,                  \
    long long: flint_box_int_safe,             \
    bool: flint_box_bool_safe,                 \
    flint_str: flint_box_str_safe,             \
    FlintValue: flint_box_val_safe)(__VA_ARGS__)

#define flint_expect(v, ...) flint_expect_inner((v), (__VA_ARGS__))
#define flint_fallback(v, ...) flint_fallback_inner((v), FLINT_BOX(__VA_ARGS__))

static inline FlintValue flint_expect_inner(FlintValue v, flint_str msg)
{
    if (v.type == FLINT_VAL_ERROR || v.type == FLINT_VAL_NULL)
    {
        printf("\033[1;31mERROR\033[0m: \033[1mPipeline Expectation Failed\033[0m\n");
        printf("  \033[1;36m-->\033[0m \033[38;5;208m~\033[1m> expect()\033[0m\n");
        printf("   \033[1;36m|\033[0m\n");
        printf("   \033[1;36m|\033[0m \033[1mMessage:\033[0m %.*s\n", (int)msg.len, msg.ptr);

        if (v.type == FLINT_VAL_ERROR && v.as.s.ptr)
        {
            printf("   \033[1;36m|\033[0m \033[1mSystem :\033[0m %.*s\n", (int)v.as.s.len, v.as.s.ptr);
        }
        else
        {
            printf("   \033[1;36m|\033[0m \033[1mSystem :\033[0m Received a null or invalid value\n");
        }

        printf("   \033[1;36m|\033[0m\n\n");
        exit(1);
    }
    return v;
}
static inline FlintValue flint_fallback_inner(FlintValue v, FlintValue alt)
{
    if (v.type == FLINT_VAL_ERROR || v.type == FLINT_VAL_NULL)
    {
        return alt;
    }
    return v;
}

#endif