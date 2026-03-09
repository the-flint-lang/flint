#ifndef FLINT_RT_H
#define FLINT_RT_H

#include <stdbool.h>
#include <stddef.h>

// ============================================================================
// BASE TYPES AND DATA STRUCTURES
// ============================================================================

// ============================================================================
// TIPAGEM DINÂMICA E DICIONÁRIOS (v1.2)
// ============================================================================

// 1. A Etiqueta de Tipo
typedef enum
{
    FLINT_VAL_NULL,
    FLINT_VAL_INT,
    FLINT_VAL_STR,
    FLINT_VAL_BOOL
} FlintValType;

// 2. O Contêiner Universal (Tagged Union)
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

// 3. A Entrada do Dicionário
typedef struct
{
    flint_str key;
    FlintValue value;
    bool occupied; // Marca se o slot está em uso na memória contígua
} FlintDictEntry;

// 4. O Dicionário (HashMap)
typedef struct
{
    FlintDictEntry *entries;
    size_t capacity;
    size_t count;
} FlintDict;

// Assinaturas do Motor de Dicionário
FlintDict *flint_dict_new(size_t capacity);
void flint_dict_set(FlintDict *dict, flint_str key, FlintValue value);
FlintValue flint_dict_get(FlintDict *dict, flint_str key);

// Construtores auxiliares para empacotar (Boxing) valores no Zig
FlintValue flint_make_int(long long val);
FlintValue flint_make_str(flint_str val);
FlintValue flint_make_bool(bool val);

// A Etiqueta (Tag)
typedef enum
{
    FLINT_VAL_INT,
    FLINT_VAL_STR,
    FLINT_VAL_BOOL,
    FLINT_VAL_NULL,

} FlintValType;

// O Contêiner Universal (Tagged Union)
typedef struct
{
    FlintValType type;
    union
    { // O C aloca apenas o espaço do maior elemento aqui
        long long i;
        flint_str s;
        bool b;
    } as;
} FlintValue;

// A Entrada do Dicionário
typedef struct
{
    flint_str key;
    FlintValue value;
} FlintDictEntry;

// O Dicionário em Si
typedef struct
{
    FlintDictEntry *entries;
    size_t count;
    size_t capacity; // Dicionários precisam crescer para evitar colisões de Hash
} FlintDict;

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

#define flint_len(arr) (long long)((arr).count)

flint_int_array flint_range(long long start, long long end);

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

// Adicione a assinatura no cabeçalho
void flint_print_val(FlintValue val);

// Atualize o _Generic para reconhecer o FlintValue
#define flint_print(X) _Generic((X), \
    int: flint_print_int,            \
    long: flint_print_int,           \
    long long: flint_print_int,      \
    FlintValue: flint_print_val,     \
    default: flint_print_str)(X)

void flint_print_str(flint_str text);
void flint_print_int(long long num);

flint_str flint_env(flint_str name);
flint_str flint_exec(flint_str cmd);
void flint_exit(int code);

flint_str_array flint_lines(flint_str text);

flint_str_array flint_grep(flint_str_array lines, flint_str pattern);

flint_str flint_join(flint_str_array lines, flint_str separator);

#endif