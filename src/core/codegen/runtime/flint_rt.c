#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <ctype.h>
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

        flint_panic("The operating system refused to allocate the Arena in memory.");
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
        flint_panic("Out of Memory (OOM): Flint's Arena exceeded the 64MB limit.");
    }

    void *ptr = arena_buffer + arena_offset;
    arena_offset += aligned_size;

    memset(ptr, 0, aligned_size);

    return ptr;
}

void flint_print_str(flint_str text)
{
    printf("%s\n", text ? text : "");
}

void flint_print_val(FlintValue val)
{
    switch (val.type)
    {
    case FLINT_VAL_INT:
        printf("%lld\n", val.as.i);
        break;
    case FLINT_VAL_STR:
        printf("%s\n", val.as.s);
        break;
    case FLINT_VAL_BOOL:
        printf("%s\n", val.as.b ? "true" : "false");
        break;
    case FLINT_VAL_NULL:
        printf("null\n");
        break;
    }
}

void flint_print_int(long long num)
{
    printf("%lld\n", num);
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
        snprintf(err_msg, sizeof(err_msg), "I/O Failure: Could not open file '%s'", filepath);
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
        flint_panic("I/O Failure: Error reading file content into memory.");
    }

    buffer[size] = '\0';
    fclose(file);

    return buffer;
}

void flint_print_dict(FlintDict *dict)
{
    if (!dict)
    {
        printf("null\n");
        return;
    }
    printf("[Flint Dictionary: %zu keys]\n", dict->count);
}

flint_str_array flint_lines(flint_str text)
{
    if (!text)
    {
        return (flint_str_array){0};
    }

    size_t count = 0;
    for (size_t i = 0; text[i] != '\0'; i++)
    {
        if (text[i] == '\n' && text[i + 1] != '\0')
            count++;
    }
    count++;

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
    {

        return (flint_str)flint_alloc(1);
    }

    if (!separator)
    {

        separator = "";
    }

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

// ============================================================================
// ENVIRONMENTAL VARIABLES AND PROCESS EXECUTION
// ============================================================================
flint_str flint_env(flint_str name)
{

    if (!name)
    {

        return "";
    }

    char *val = getenv(name);
    // If the variable does not exist, we return empty string instead of NULL.
    return val ? (flint_str)val : "";
}

void flint_exit(int code)
{

    flint_deinit(); // clean arena
    exit(code);
}

flint_str flint_exec(flint_str cmd)
{
    if (!cmd)
        return "";

    FILE *pipe = popen(cmd, "r");
    if (!pipe)
    {
        fprintf(stderr, "Erro fatal: Falha ao executar comando '%s'\n", cmd);
        flint_exit(1);
    }

    size_t capacity = 2 * 1024 * 1024;
    char *temp_buf = (char *)malloc(capacity);
    if (!temp_buf)
    {
        fprintf(stderr, "Erro fatal: Sem memória no Sistema Operacional para o exec.\n");
        flint_exit(1);
    }

    size_t total_read = 0;
    size_t bytes_read = 0;

    while ((bytes_read = fread(temp_buf + total_read, 1, capacity - total_read - 1, pipe)) > 0)
    {
        total_read += bytes_read;
        if (total_read >= capacity - 1024)
        {
            capacity *= 2;
            char *new_buf = (char *)realloc(temp_buf, capacity);
            if (!new_buf)
            {
                free(temp_buf);
                flint_exit(1);
            }
            temp_buf = new_buf;
        }
    }

    temp_buf[total_read] = '\0';
    pclose(pipe);

    flint_str result = (flint_str)flint_alloc(total_read + 1);
    memcpy(result, temp_buf, total_read + 1);

    free(temp_buf);

    return result;
}

// ============================================================================
// ARRAY UTILITIES AND ITERATORS
// ============================================================================

flint_int_array flint_range(long long start, long long end)
{
    if (start >= end)
    {
        return (flint_int_array){0}; // Returns empty array if parameters are illogical
    }

    size_t count = (size_t)(end - start);

    long long *items = (long long *)flint_alloc(count * sizeof(long long));

    for (size_t i = 0; i < count; i++)
    {
        items[i] = start + (long long)i;
    }

    // Atualize o return no final da função flint_range
    return (flint_int_array){.items = items, .count = count, .capacity = count};
}

// ============================================================================
// HASHMAP ENGINE AND DYNAMIC TYPING
// ============================================================================

FlintValue flint_make_int(long long val) { return (FlintValue){FLINT_VAL_INT, .as.i = val}; }
FlintValue flint_make_str(flint_str val) { return (FlintValue){FLINT_VAL_STR, .as.s = val}; }
FlintValue flint_make_bool(bool val) { return (FlintValue){FLINT_VAL_BOOL, .as.b = val}; }

static unsigned long flint_hash_djb2(flint_str str)
{
    unsigned long hash = 5381;
    int c;
    while ((c = *str++))
    {
        hash = ((hash << 5) + hash) + c; // hash * 33 + c
    }
    return hash;
}

FlintDict *flint_dict_new(size_t capacity)
{
    if (capacity < 16)
        capacity = 16;

    FlintDict *dict = (FlintDict *)flint_alloc(sizeof(FlintDict));
    dict->capacity = capacity;
    dict->count = 0;
    dict->entries = (FlintDictEntry *)flint_alloc(sizeof(FlintDictEntry) * capacity);
    return dict;
}

void flint_dict_set(FlintDict *dict, flint_str key, FlintValue value)
{

    unsigned long index = flint_hash_djb2(key) % dict->capacity;

    size_t probes = 0;
    while (dict->entries[index].occupied)
    {
        if (strcmp(dict->entries[index].key, key) == 0)
            break;
        index = (index + 1) % dict->capacity;
        if (++probes >= dict->capacity)
        {
            flint_panic("Dictionary is full: cannot insert new key.");
        }
    }

    if (!dict->entries[index].occupied)
    {
        dict->count++;
        dict->entries[index].occupied = true;
        dict->entries[index].key = key;
    }
    dict->entries[index].value = value;
}

void flint_write_file(flint_str text, flint_str filepath)
{
    FILE *file = fopen(filepath, "wb");
    if (!file)
    {
        char err_msg[255];
        snprintf(err_msg, sizeof(err_msg), "I/O Failure: Could not open file '%s' for writing", filepath);
        flint_panic(err_msg);
    }
    fputs(text, file);
    fclose(file);
}

bool flint_file_exists(flint_str filepath)
{
    FILE *file = fopen(filepath, "r");
    if (!file)
        return false;
    fclose(file);
    return true;
}

FlintValue flint_dict_get(FlintDict *dict, flint_str key)
{
    unsigned long index = flint_hash_djb2(key) % dict->capacity;

    while (dict->entries[index].occupied)
    {
        if (strcmp(dict->entries[index].key, key) == 0)
        {
            return dict->entries[index].value;
        }
        index = (index + 1) % dict->capacity;
    }

    return (FlintValue){FLINT_VAL_NULL, .as.i = 0};
}

// ============================================================================
// NATIVE STRING MANIPULATION MODULE
// ============================================================================

flint_str flint_trim(flint_str text)
{
    if (!text)
        return "";

    while (isspace((unsigned char)*text))
        text++;

    if (*text == '\0')
        return "";

    char *end = text + strlen(text) - 1;
    while (end > text && isspace((unsigned char)*end))
        end--;

    size_t len = end - text + 1;

    flint_str result = (flint_str)flint_alloc(len + 1);
    memcpy(result, text, len);
    result[len] = '\0';

    return result;
}

flint_str flint_replace(flint_str text, flint_str target, flint_str replacement)
{
    if (!text || !target || !replacement)
        return text ? text : "";

    size_t target_len = strlen(target);
    if (target_len == 0)
        return text;

    size_t repl_len = strlen(replacement);
    size_t text_len = strlen(text);

    size_t count = 0;
    const char *tmp = text;
    while ((tmp = strstr(tmp, target)))
    {
        count++;
        tmp += target_len;
    }

    if (count == 0)
        return text;

    size_t final_len = text_len - (count * target_len) + (count * repl_len);
    flint_str result = (flint_str)flint_alloc(final_len + 1);

    char *dest = result;
    const char *src = text;
    const char *match;

    while ((match = strstr(src, target)))
    {
        size_t chunk_len = match - src;
        memcpy(dest, src, chunk_len);
        dest += chunk_len;

        memcpy(dest, replacement, repl_len);
        dest += repl_len;

        src = match + target_len;
    }
    strcpy(dest, src);

    return result;
}

flint_str_array flint_split(flint_str text, flint_str delimiter)
{
    if (!text || !delimiter)
        return (flint_str_array){0};

    size_t delim_len = strlen(delimiter);
    if (delim_len == 0)
        return (flint_str_array){0};

    size_t count = 1;
    const char *tmp = text;
    while ((tmp = strstr(tmp, delimiter)))
    {
        count++;
        tmp += delim_len;
    }

    flint_str_array arr;
    arr.count = count;
    arr.capacity = count;
    arr.items = (flint_str *)flint_alloc(count * sizeof(flint_str));

    size_t idx = 0;
    const char *start = text;
    const char *end;

    while ((end = strstr(start, delimiter)))
    {
        size_t chunk_len = end - start;
        flint_str chunk = (flint_str)flint_alloc(chunk_len + 1);
        memcpy(chunk, start, chunk_len);
        chunk[chunk_len] = '\0';

        arr.items[idx++] = chunk;
        start = end + delim_len;
    }

    size_t last_len = strlen(start);
    flint_str last_chunk = (flint_str)flint_alloc(last_len + 1);
    strcpy(last_chunk, start);
    arr.items[idx] = last_chunk;

    return arr;
}