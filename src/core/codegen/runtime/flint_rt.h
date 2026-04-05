#ifndef FLINT_RT_H
#define FLINT_RT_H

#include <stdbool.h>
#include <stddef.h>
#include <string.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <limits.h>

// ==========================================
// STRING SLICES
// ==========================================

typedef struct
{
    const char *ptr;
    size_t len;
} flint_str;

typedef struct
{
    flint_str source;
    size_t current_pos;
    bool has_next;
    flint_str filter_pattern;
} flint_stream;

#define FLINT_STR(literal) (flint_str){.ptr = (literal), .len = sizeof(literal) - 1}

#define FLINT_SLICE(pointer, length) \
    (flint_str) { .ptr = (pointer), .len = (length) }
typedef struct FlintDict FlintDict;

typedef enum
{
    FLINT_VAL_NULL,
    FLINT_VAL_INT,
    FLINT_VAL_FLOAT,
    FLINT_VAL_BOOL,
    FLINT_VAL_STR,
    FLINT_VAL_DICT,
    FLINT_VAL_ARRAY,
    FLINT_VAL_ERROR,
    FLINT_VAL_STREAM,
    FLINT_VAL_JSON_LAZY,
} FlintValType;

typedef struct
{
    FlintValType type;
    union
    {
        long long i;
        uint64_t f;
        bool b;
        flint_str s;
        FlintDict *d;
        flint_stream stream;
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

typedef size_t FlintArenaMark;
FlintArenaMark flint_arena_mark(void);
void flint_arena_release(FlintArenaMark m);

/* =========================
   ARRAYS
   ========================= */

#define DECLARE_FLINT_ARRAY(Type, Name) \
    typedef struct                      \
    {                                   \
        Type *restrict items;           \
        size_t count;                   \
        size_t capacity;                \
    } Name;

DECLARE_FLINT_ARRAY(long long, flint_int_array)
DECLARE_FLINT_ARRAY(flint_str, flint_str_array)
DECLARE_FLINT_ARRAY(bool, flint_bool_array)

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

static inline long long _flint_get_str_len(flint_str s) { return (long long)s.len; }
static inline long long _flint_get_stra_len(flint_str_array a) { return (long long)a.count; }
static inline long long _flint_get_inta_len(flint_int_array a) { return (long long)a.count; }

#define flint_len(X) _Generic((X),        \
    flint_str: _flint_get_str_len,        \
    flint_str_array: _flint_get_stra_len, \
    flint_int_array: _flint_get_inta_len, \
    default: _flint_get_str_len)(X)

flint_str flint_slice_str(flint_str s, long long start, long long end);
flint_int_array flint_slice_int_array(flint_int_array a, long long start, long long end);
flint_str_array flint_slice_str_array(flint_str_array a, long long start, long long end);
flint_bool_array flint_slice_bool_array(flint_bool_array a, long long start, long long end);

#define FLINT_SLICE_EXPR(obj, start, end) _Generic((obj), \
    flint_str: flint_slice_str,                           \
    flint_int_array: flint_slice_int_array,               \
    flint_str_array: flint_slice_str_array,               \
    flint_bool_array: flint_slice_bool_array)((obj), (start), (end))

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
FlintValue flint_make_float(double v);
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
    uint64_t: flint_make_float,    \
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
void flint_print_float(double v);
void flint_print_val(FlintValue val);
void flint_print_bool(bool b);
void flint_print_dict(FlintDict *dict);

#define flint_print(X) _Generic((X), \
    int: flint_print_int,            \
    long: flint_print_int,           \
    long long: flint_print_int,      \
    float: flint_print_float,        \
    double: flint_print_float,       \
    bool: flint_print_bool,          \
    FlintValue: flint_print_val,     \
    FlintDict *: flint_print_dict,   \
    default: flint_print_str)(X)

void flint_printerr_str(flint_str text);
void flint_printerr_float(double v);
void flint_printerr_int(long long num);
void flint_printerr_val(FlintValue val);
void flint_printerr_bool(bool b);
void flint_printerr_dict(FlintDict *dict);

#define flint_printerr(X) _Generic((X), \
    int: flint_printerr_int,            \
    long: flint_printerr_int,           \
    long long: flint_printerr_int,      \
    float: flint_printerr_float,        \
    double: flint_printerr_float,       \
    bool: flint_printerr_bool,          \
    FlintValue: flint_printerr_val,     \
    FlintDict *: flint_printerr_dict,   \
    default: flint_printerr_str)(X)

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
bool flint_is_tty();

FlintValue flint_file_size(flint_str path);
FlintValue flint_mv(flint_str old_path, flint_str new_path);
FlintValue flint_copy(flint_str src, flint_str dest);

// terminal

void flint_clear();
void flint_write(flint_str way, flint_str msg);

bool flint_is_root();
FlintValue flint_require_root(flint_str_array plus_args);

/* =========================
   PROCESS
   ========================= */

flint_str
flint_exec(flint_str cmd);
FlintValue flint_spawn(flint_str cmd, bool echo);

/* =========================
   ENV
   ========================= */

flint_str flint_env(flint_str name);
flint_str_array flint_args();
bool flint_os_command_exists(flint_str bin);

/* =========================
   INPUT
   ========================= */

flint_str flint_read_line(flint_str s);

/* =========================
   STREAMS
   ========================= */

flint_stream flint_str_stream(flint_str text);
flint_str flint_stream_next(flint_stream *stream);

FlintValue flint_lines_inner(FlintValue text_val);

#define flint_lines(X) flint_lines_inner(FLINT_BOX(X))

FlintValue flint_grep_inner(FlintValue iterable, FlintValue pattern_val);
#define flint_grep(iter, pat) flint_grep_inner(FLINT_BOX(iter), FLINT_BOX(pat))

/* =========================
   str
   ========================= */

flint_str_array flint_split(flint_str text, flint_str delimiter);
flint_str flint_join(flint_str_array arr, flint_str sep);

flint_str flint_trim(flint_str text);
long long flint_count_matches(flint_str text, flint_str pattern);

flint_str flint_to_str_func(FlintValue v);
flint_str flint_int_to_str(long long num);
flint_str flint_concat(flint_str a, flint_str b);
flint_str_array flint_chars(flint_str text);

flint_str flint_build_str_array(flint_str *parts, size_t count);

#define flint_build_str(...) flint_build_str_array((flint_str[]){__VA_ARGS__}, sizeof((flint_str[]){__VA_ARGS__}) / sizeof(flint_str))

#define build_str(...) flint_build_str(__VA_ARGS__)

static inline long long flint_to_int_func(FlintValue v)
{
    if (v.type == FLINT_VAL_INT)
        return v.as.i;
    return 0;
}

#define flint_to_int(X) flint_to_int_func(FLINT_BOX(X))
#define flint_to_str(X) flint_to_str_func(FLINT_BOX(X))

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

static inline FlintValue flint_box_float_safe(double f)
{
    FlintValue v;
    v.type = FLINT_VAL_FLOAT;
    memcpy(&v.as.f, &f, sizeof(double));
    return v;
}

#undef FLINT_BOX
#define FLINT_BOX(...) _Generic((__VA_ARGS__), \
    int: flint_box_int_safe,                   \
    long: flint_box_int_safe,                  \
    long long: flint_box_int_safe,             \
    float: flint_box_float_safe,               \
    double: flint_box_float_safe,              \
    bool: flint_box_bool_safe,                 \
    flint_str: flint_box_str_safe,             \
    FlintValue: flint_box_val_safe)(__VA_ARGS__)

#define flint_if_fail(v, ...) flint_expect_inner((v), (__VA_ARGS__))
#define flint_fallback(v, ...) flint_fallback_inner((v), FLINT_BOX(__VA_ARGS__))

static inline FlintValue flint_expect_inner(FlintValue v, flint_str msg)
{
    if (v.type == FLINT_VAL_ERROR || v.type == FLINT_VAL_NULL)
    {
        printf("\033[1;31mERROR\033[0m: \033[1mPipeline Expectation Failed\033[0m\n");
        printf("  \033[1;36m-->\033[0m \033[38;5;208m~\033[1m> if_fail()\033[0m\n");
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

// ============================================================================
// UNIVERSAL INDEXING (BRACKET NOTATION)
// ============================================================================

static inline long long flint_idx_int_arr(flint_int_array a, FlintValue k) { return a.items[flint_to_int(k)]; }
static inline flint_str flint_idx_str_arr(flint_str_array a, FlintValue k) { return a.items[flint_to_int(k)]; }
static inline FlintValue flint_idx_dict(FlintDict *d, FlintValue k) { return flint_dict_get(d, flint_to_str(k)); }

FlintValue flint_lazy_json_get(flint_str json_str, flint_str key);
FlintValue flint_dict_get_hashed(FlintDict *d, flint_str key, uint64_t hash);

static inline FlintValue flint_idx_val(FlintValue v, FlintValue k)
{
    if (v.type == FLINT_VAL_DICT && v.as.d)
        return flint_dict_get(v.as.d, flint_to_str(k));

    if (v.type == FLINT_VAL_JSON_LAZY)
        return flint_lazy_json_get(v.as.s, flint_to_str(k));

    return (FlintValue){FLINT_VAL_NULL};
}

static inline FlintValue flint_idx_val_hashed(FlintValue v, flint_str key, uint64_t hash)
{
    if (v.type == FLINT_VAL_DICT && v.as.d)
        return flint_dict_get_hashed(v.as.d, key, hash);

    if (v.type == FLINT_VAL_JSON_LAZY)
        return flint_lazy_json_get(v.as.s, key);

    return (FlintValue){FLINT_VAL_NULL};
}

#define FLINT_INDEX(obj, idx) _Generic((obj), \
    flint_int_array: flint_idx_int_arr,       \
    flint_str_array: flint_idx_str_arr,       \
    FlintDict *: flint_idx_dict,              \
    const FlintDict *: flint_idx_dict,        \
    FlintValue: flint_idx_val,                \
    const FlintValue: flint_idx_val)((obj), FLINT_BOX(idx))

#define FLINT_GET_HASHED(obj, key, hash) _Generic((obj), \
    FlintDict *: flint_dict_get_hashed,                  \
    FlintValue: flint_idx_val_hashed)((obj), FLINT_STR(key), (hash))

// ============================================================================
// UNIVERSAL COMPARISON (DEEP EQUALITY)
// ============================================================================

static inline bool flint_val_eq(FlintValue a, FlintValue b)
{
    if (a.type != b.type)
        return false;
    switch (a.type)
    {
    case FLINT_VAL_NULL:
        return true;
    case FLINT_VAL_INT:
        return a.as.i == b.as.i;
    case FLINT_VAL_BOOL:
        return a.as.b == b.as.b;
    case FLINT_VAL_STR:
        return flint_str_eql(a.as.s, b.as.s);
    default:
        return false;
    }
}

#define FLINT_EQ(a, b) flint_val_eq(FLINT_BOX(a), FLINT_BOX(b))
#define FLINT_NEQ(a, b) (!flint_val_eq(FLINT_BOX(a), FLINT_BOX(b)))

FlintValue flint_ensure(FlintValue val, bool condition, flint_str err_msg);

// ============================================================================
// UNIVERSAL ASSIGNMENT (SET INDEX)
// ============================================================================

static inline void flint_set_idx_int_arr(flint_int_array a, FlintValue k, FlintValue v)
{
    a.items[flint_to_int(k)] = flint_to_int(v);
}
static inline void flint_set_idx_str_arr(flint_str_array a, FlintValue k, FlintValue v)
{
    a.items[flint_to_int(k)] = flint_to_str(v);
}
static inline void flint_set_idx_dict(FlintDict *d, FlintValue k, FlintValue v)
{
    flint_dict_set(d, flint_to_str(k), v);
}
static inline void flint_set_idx_val(FlintValue v, FlintValue k, FlintValue val)
{
    if (v.type == FLINT_VAL_DICT && v.as.d)
    {
        flint_dict_set(v.as.d, flint_to_str(k), val);
    }
}

#define FLINT_SET_INDEX(obj, idx, val) _Generic((obj), \
    flint_int_array: flint_set_idx_int_arr,            \
    flint_str_array: flint_set_idx_str_arr,            \
    FlintDict *: flint_set_idx_dict,                   \
    FlintValue: flint_set_idx_val)((obj), FLINT_BOX(idx), FLINT_BOX(val))

#endif