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
// 3. A BIBLIOTECA PADRÃO (I/O & Utilitários)
// ============================================================================

// Funções reais ocultas do usuário
void flint_print_str(flint_str text);
void flint_print_int(long long num);

// A Mágica do C11 (Polimorfismo em Tempo de Compilação)
// Se X for inteiro, chama print_int. Caso contrário (default), assume que é string.
#define flint_print(X) _Generic((X), \
    int: flint_print_int,            \
    long: flint_print_int,           \
    long long: flint_print_int,      \
    default: flint_print_str)(X)

// ... resto do seu flint_rt.h (read_file, write_file, etc)

flint_str_array flint_lines(flint_str text);

flint_str_array flint_grep(flint_str_array lines, flint_str pattern);

flint_str flint_join(flint_str_array lines, flint_str separator);

#endif