#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "flint_rt.h"

#define ARENA_CAPACITY (64 * 1024 * 1024)

static char *arena_buffer = NULL;
static size_t arena_offset = 0;

static int global_argc = 0;
static char **global_argv = NULL;

void flint_panic(const char *message)
{
    fprintf(stderr, "\033[1;31m[Flint Fatal Error]\033[0m %s\n", message);

    flint_deinit();

    exit(1);
}

void flint_init(int argc, char **argv)
{
    global_argc = argc;
    global_argv = argv;

    arena_buffer = (char *)malloc(ARENA_CAPACITY);
    if (arena_buffer == NULL)
    {

        flint_panic("O sistema operacional recusou a alocação do Arena na memória.");
    }

    arena_offset = 0;
}

void flint_deinit()
{
    if (arena_buffer != NULL)
    {
        free(arena_buffer);
        arena_buffer = NULL;
    }
}

void *flint_alloc(size_t size)
{
    if (size == 0)
        return NULL;

    size_t aligned_size = (size + 7) & ~7;

    if (arena_offset + aligned_size > ARENA_CAPACITY)
    {
        flint_panic("Out of Memory (OOM): A Arena do Flint estourou o limite de 64MB.");
    }

    void *ptr = arena_buffer + arena_offset;
    arena_offset += aligned_size;

    memset(ptr, 0, aligned_size);

    return ptr;
}

void flint_print(flint_str text)
{
    if (text == NULL)
    {
        printf("null\n");
        return;
    }

    printf("%s\n", text);
}

flint_str_array flint_args()
{
    flint_str_array arr;
    arr.count = global_argc;

    arr.items = (flint_str *)flint_alloc(sizeof(flint_str) * global_argc);

    for (int i = 0; i < global_argc; i++)
    {

        size_t len = strlen(global_argv[i]);
        flint_str arg_copy = (flint_str)flint_alloc(len + 1);

        strcpy(arg_copy, global_argv[i]);
        arr.items[i] = arg_copy;
    }

    return arr;
}

flint_str flint_read_file(flint_str filepath)
{

    FILE *file = fopen(filepath, "rb");
    if (!file)
    {

        char err_msg[255];
        snprintf(err_msg, sizeof(err_msg), "Falha de I/O: Não foi possível abrir o arquivo '%s'", filepath);
        flint_panic(err_msg);
    }

    fseek(file, 0, SEEK_END);
    long size = ftell(file);
    fseek(file, 0, SEEK_SET);

    flint_str buffer = (flint_str)flint_alloc(size + 1);

    size_t read_size = fread(buffer, 1, size, file);
    if (read_size != (size_t)size)
    {
        fclose(file);
        flint_panic("Falha de I/O: Erro ao ler conteúdo do arquivo para a memória.");
    }

    buffer[size] = '\0';
    fclose(file);

    return buffer;
}

flint_str_array flint_lines(flint_str text)
{
    if (!text)
    {
        return (flint_str_array){0};
    }

    size_t count = 1;
    for (size_t i = 0; text[i] != '\0'; i++)
    {
        if (text[i] == '\n')
        {

            count++;
        }
    }

    flint_str_array arr;
    arr.count = count;
    arr.items = (flint_str *)flint_alloc(sizeof(flint_str) * count);

    size_t len = strlen(text);
    flint_str text_copy = (flint_str)flint_alloc(len + 1);
    strcpy(text_copy, text);

    size_t line_idx = 0;
    arr.items[line_idx++] = text_copy;

    for (size_t i = 0; text_copy[i] != '\0'; i++)
    {
        if (text_copy[i] == '\n')
        {
            text_copy[i] = '\0';
            arr.items[line_idx++] = &text_copy[i + 1];
        }
    }

    return arr;
}

flint_str_array flint_grep(flint_str_array lines, flint_str pattern)
{
    if (lines.count == 0 || !pattern)
        return (flint_str_array){0};

    flint_str *matched_items = (flint_str *)flint_alloc(sizeof(flint_str) * lines.count);
    size_t match_count = 0;

    for (size_t i = 0; i < lines.count; i++)
    {

        if (strstr(lines.items[i], pattern) != NULL)
        {
            matched_items[match_count++] = lines.items[i];
        }
    }

    flint_str_array result;
    result.items = matched_items;
    result.count = match_count;
    return result;
}

flint_str flint_join(flint_str_array lines, flint_str separator)
{
    if (lines.count == 0)
        return (flint_str)flint_alloc(1);
    if (!separator)
        separator = "";

    size_t sep_len = strlen(separator);
    size_t total_len = 0;

    for (size_t i = 0; i < lines.count; i++)
    {
        total_len += strlen(lines.items[i]);
    }

    total_len += sep_len * (lines.count - 1);

    flint_str result = (flint_str)flint_alloc(total_len + 1);
    char *current_pos = result;

    for (size_t i = 0; i < lines.count; i++)
    {
        size_t line_len = strlen(lines.items[i]);

        memcpy(current_pos, lines.items[i], line_len);
        current_pos += line_len;

        if (i < lines.count - 1 && sep_len > 0)
        {
            memcpy(current_pos, separator, sep_len);
            current_pos += sep_len;
        }
    }

    *current_pos = '\0';
    return result;
}