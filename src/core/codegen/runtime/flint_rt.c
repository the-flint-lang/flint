#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif

#include "flint_rt.h"
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <ctype.h>
#include <curl/curl.h>

static int global_argc;
static char **global_argv;

/* =========================
ARENA E RUNTIME
========================= */

#define ARENA_BLOCK_SIZE (8 * 1024 * 1024)

typedef struct ArenaBlock
{
    char *memory;
    size_t capacity;
    size_t offset;
    struct ArenaBlock *next;
} ArenaBlock;

static ArenaBlock *arena_head = NULL;
static ArenaBlock *arena_current = NULL;

static int global_argc;
static char **global_argv;

static ArenaBlock *create_arena_block(size_t capacity)
{
    ArenaBlock *block = malloc(sizeof(ArenaBlock));
    if (!block)
        flint_panic("Fatal error: Unable to allocate the Arena block header..");

    block->memory = malloc(capacity);
    if (!block->memory)
        flint_panic("Fatal failure: OS refused to allocate memory for the block.");

    block->capacity = capacity;
    block->offset = 0;
    block->next = NULL;
    return block;
}

void flint_init(int argc, char **argv)
{
    global_argc = argc;
    global_argv = argv;

    arena_head = create_arena_block(ARENA_BLOCK_SIZE);
    arena_current = arena_head;
}

void flint_deinit()
{
    ArenaBlock *curr = arena_head;
    while (curr)
    {
        ArenaBlock *next = curr->next;
        free(curr->memory);
        free(curr);
        curr = next;
    }
}

void flint_arena_reset()
{
    ArenaBlock *curr = arena_head;
    while (curr)
    {
        curr->offset = 0;
        curr = curr->next;
    }
    arena_current = arena_head;
}

void *flint_alloc_raw(size_t size)
{
    size = (size + 7) & ~7;

    if (arena_current->offset + size > arena_current->capacity)
    {

        if (arena_current->next != NULL && arena_current->next->capacity >= size)
        {
            arena_current = arena_current->next;
        }
        else
        {
            size_t new_cap = (size > ARENA_BLOCK_SIZE) ? size : ARENA_BLOCK_SIZE;
            ArenaBlock *new_block = create_arena_block(new_cap);

            arena_current->next = new_block;
            arena_current = new_block;
        }
    }

    void *ptr = arena_current->memory + arena_current->offset;
    arena_current->offset += size;
    return ptr;
}

void *flint_alloc(size_t size)
{
    void *ptr = flint_alloc_raw(size);
    memset(ptr, 0, size);
    return ptr;
}

void flint_panic(const char *msg)
{
    fprintf(stderr, "\033[1;31m[Flint Panic]\033[0m %s\n", msg);
    exit(1);
}

void flint_exit(int code)
{
    flint_deinit();
    exit(code);
}

/* =========================
   CONSTRUTORES (BOXING)
   ========================= */

FlintValue flint_make_int(long long v) { return (FlintValue){FLINT_VAL_INT, .as.i = v}; }
FlintValue flint_make_bool(bool v) { return (FlintValue){FLINT_VAL_BOOL, .as.b = v}; }
FlintValue flint_make_str(flint_str v) { return (FlintValue){FLINT_VAL_STR, .as.s = v}; }

FlintValue flint_make_error(flint_str msg) { return (FlintValue){FLINT_VAL_ERROR, .as.s = msg}; }
bool flint_is_err(FlintValue v) { return v.type == FLINT_VAL_ERROR; }
flint_str flint_get_err(FlintValue v)
{
    return v.type == FLINT_VAL_ERROR ? v.as.s : FLINT_STR("");
}

/* =========================
   PRINT
   ========================= */

void flint_print_str(flint_str text)
{
    printf("%.*s\n", (int)text.len, text.ptr);
}
void flint_print_int(long long v) { printf("%lld\n", v); }
void flint_print_dict(FlintDict *d) { printf("[Flint Dictionary: %zu keys]\n", d ? d->count : 0); }

void flint_print_val(FlintValue v)
{
    switch (v.type)
    {
    case FLINT_VAL_NULL:
        printf("null\n");
        break;
    case FLINT_VAL_INT:
        printf("%lld\n", v.as.i);
        break;
    case FLINT_VAL_BOOL:
        printf("%s\n", v.as.b ? "true" : "false");
        break;
    case FLINT_VAL_STR:
        printf("%.*s\n", (int)v.as.s.len, v.as.s.ptr);
        break;
    case FLINT_VAL_DICT:
        printf("[Dict]\n");
        break;
    case FLINT_VAL_ERROR:
        printf("\033[1;31m[Caught Error]\033[0m %.*s\n", (int)v.as.s.len, v.as.s.ptr);
        break;
    }
}

/* =========================
   FILE I/O
   ========================= */

static char *to_c_string(flint_str s)
{
    if (s.len == 0)
        return "";
    if (s.ptr[s.len] == '\0')
    {
        return (char *)s.ptr;
    }

    char *buf = flint_alloc_raw(s.len + 1);
    memcpy(buf, s.ptr, s.len);
    buf[s.len] = '\0';
    return buf;
}

flint_str flint_read_file(flint_str path)
{
    char *c_path = to_c_string(path);
    int fd = open(c_path, O_RDONLY);
    if (fd < 0)
        flint_panic("Cannot open file");

    struct stat sb;
    if (fstat(fd, &sb) < 0)
        flint_panic("Cannot stat file");

    if (sb.st_size == 0)
    {
        close(fd);
        return FLINT_STR("");
    }

    char *mapped = mmap(NULL, sb.st_size, PROT_READ, MAP_PRIVATE, fd, 0);
    close(fd);
    if (mapped == MAP_FAILED)
        flint_panic("mmap failed");

    long page_size = sysconf(_SC_PAGESIZE);
    if (sb.st_size % page_size != 0)
    {
        return FLINT_SLICE(mapped, sb.st_size);
    }

    char *buf = flint_alloc_raw(sb.st_size + 1);
    int fd2 = open(c_path, O_RDONLY);
    read(fd2, buf, sb.st_size);
    buf[sb.st_size] = '\0';
    close(fd2);
    munmap(mapped, sb.st_size);

    return FLINT_SLICE(buf, sb.st_size);
}

void flint_write_file(flint_str text, flint_str filepath)
{
    char *c_path = to_c_string(filepath);
    FILE *f = fopen(c_path, "wb");
    if (!f)
        flint_panic("cannot write file");

    fwrite(text.ptr, 1, text.len, f);
    fclose(f);
}

bool flint_file_exists(flint_str filepath)
{
    char *c_path = to_c_string(filepath);
    FILE *f = fopen(c_path, "r");
    if (f)
    {
        fclose(f);
        return true;
    }
    return false;
}

/* =========================
   ENV & PROCESS
   ========================= */

flint_str flint_env(flint_str name)
{
    char *c_name = to_c_string(name);
    char *v = getenv(c_name);
    if (!v)
        return FLINT_STR("");
    return FLINT_SLICE(v, strlen(v));
}

flint_str_array flint_args()
{
    flint_str_array arr;
    flint_array_init(arr);
    for (int i = 0; i < global_argc; i++)
    {
        flint_str arg_slice = FLINT_SLICE(global_argv[i], strlen(global_argv[i]));
        flint_push(arr, arg_slice);
    }
    return arr;
}

flint_str flint_exec(flint_str cmd)
{
    if (cmd.len == 0)
        return FLINT_STR("");

    char *c_cmd = to_c_string(cmd);
    FILE *pipe = popen(c_cmd, "r");
    if (!pipe)
        flint_panic("popen failed");

    char temp_buf[1024];
    size_t total_read = 0;
    size_t max_size = 4096;
    char *buf = flint_alloc_raw(max_size);

    while (fgets(temp_buf, sizeof(temp_buf), pipe) != NULL)
    {
        size_t len = strlen(temp_buf);
        if (total_read + len >= max_size)
        {
            max_size *= 2;
            char *new_buf = flint_alloc_raw(max_size);
            memcpy(new_buf, buf, total_read);
            buf = new_buf;
        }
        memcpy(buf + total_read, temp_buf, len);
        total_read += len;
    }
    pclose(pipe);

    // Ajuste perfeito do tamanho
    return FLINT_SLICE(buf, total_read);
}

/* =========================
   STRINGS
   ========================= */

static bool flint_str_eq(flint_str a, flint_str b)
{
    if (a.len != b.len)
        return false;
    if (a.len == 0)
        return true;
    return memcmp(a.ptr, b.ptr, a.len) == 0;
}

static unsigned long flint_hash(flint_str s)
{
    unsigned long hash = 5381;
    for (size_t i = 0; i < s.len; i++)
    {
        hash = ((hash << 5) + hash) + s.ptr[i];
    }
    return hash;
}

flint_str flint_trim(flint_str text)
{
    if (text.len == 0 || !text.ptr)
        return FLINT_STR("");

    size_t start = 0;
    while (start < text.len && isspace((unsigned char)text.ptr[start]))
    {
        start++;
    }

    if (start == text.len)
        return FLINT_STR("");

    size_t end = text.len - 1;
    while (end > start && isspace((unsigned char)text.ptr[end]))
    {
        end--;
    }

    return FLINT_SLICE(text.ptr + start, (end - start) + 1);
}

flint_str flint_concat(flint_str a, flint_str b)
{
    if (a.len == 0 && b.len == 0)
        return FLINT_STR("");
    if (a.len == 0)
        return b;
    if (b.len == 0)
        return a;

    size_t total_len = a.len + b.len;
    char *buf = flint_alloc_raw(total_len + 1);

    memcpy(buf, a.ptr, a.len);
    memcpy(buf + a.len, b.ptr, b.len);

    buf[total_len] = '\0';

    return FLINT_SLICE(buf, total_len);
}

flint_str_array flint_split(flint_str text, flint_str delimiter)
{
    flint_str_array arr;
    flint_array_init(arr);

    if (text.len == 0 || !text.ptr)
        return arr;
    if (delimiter.len == 0 || !delimiter.ptr)
    {
        flint_push(arr, text);
        return arr;
    }

    const char *curr = text.ptr;
    const char *end = text.ptr + text.len;

    while (curr < end)
    {
        const char *match = memmem(curr, end - curr, delimiter.ptr, delimiter.len);
        if (!match)
        {
            flint_str tail = FLINT_SLICE(curr, end - curr);
            flint_push(arr, tail);
            break;
        }
        flint_str piece = FLINT_SLICE(curr, match - curr);
        flint_push(arr, piece);
        curr = match + delimiter.len;
    }

    return arr;
}

flint_str_array flint_lines(flint_str text)
{
    return flint_split(text, FLINT_STR("\n"));
}

flint_str_array flint_grep(flint_str_array lines, flint_str pattern)
{
    flint_str_array arr;
    flint_array_init(arr);

    if (pattern.len == 0 || !pattern.ptr)
        return arr;

    for (size_t i = 0; i < lines.count; i++)
    {
        flint_str line = lines.items[i];
        if (memmem(line.ptr, line.len, pattern.ptr, pattern.len))
        {
            flint_push(arr, line);
        }
    }
    return arr;
}

long long flint_count_matches(flint_str text, flint_str pattern)
{
    if (text.len == 0 || pattern.len == 0)
        return 0;

    long long count = 0;
    const char *curr = text.ptr;
    const char *end = text.ptr + text.len;

    while (curr < end)
    {
        const char *match = memmem(curr, end - curr, pattern.ptr, pattern.len);
        if (!match)
            break;
        count++;
        curr = match + pattern.len;
    }

    return count;
}

flint_str flint_replace(flint_str text, flint_str target, flint_str repl)
{
    if (text.len == 0 || !text.ptr)
        return FLINT_STR("");
    if (target.len == 0 || !target.ptr)
        return text;

    long long count = flint_count_matches(text, target);
    if (count == 0)
        return text;

    size_t final_len = text.len - (count * target.len) + (count * repl.len);
    char *buf = flint_alloc_raw(final_len + 1);
    char *dest = buf;

    const char *curr = text.ptr;
    const char *end = text.ptr + text.len;

    while (curr < end)
    {
        const char *match = memmem(curr, end - curr, target.ptr, target.len);
        if (!match)
        {
            memcpy(dest, curr, end - curr);
            dest += (end - curr);
            break;
        }
        size_t prefix_len = match - curr;
        memcpy(dest, curr, prefix_len);
        dest += prefix_len;

        memcpy(dest, repl.ptr, repl.len);
        dest += repl.len;

        curr = match + target.len;
    }

    *dest = '\0';
    return FLINT_SLICE(buf, final_len);
}

flint_str flint_join(flint_str_array arr, flint_str sep)
{
    if (arr.count == 0)
        return FLINT_STR("");

    size_t total_len = 0;
    for (size_t i = 0; i < arr.count; i++)
    {
        total_len += arr.items[i].len;
    }
    total_len += sep.len * (arr.count > 0 ? arr.count - 1 : 0);

    char *buf = flint_alloc_raw(total_len + 1);
    char *dest = buf;

    for (size_t i = 0; i < arr.count; i++)
    {
        memcpy(dest, arr.items[i].ptr, arr.items[i].len);
        dest += arr.items[i].len;
        if (i < arr.count - 1 && sep.len > 0)
        {
            memcpy(dest, sep.ptr, sep.len);
            dest += sep.len;
        }
    }

    *dest = '\0';
    return FLINT_SLICE(buf, total_len);
}

flint_str flint_int_to_str(long long num)
{
    char *buf = flint_alloc(32);
    int len = snprintf(buf, 32, "%lld", num);
    return FLINT_SLICE(buf, (size_t)len);
}

flint_str flint_to_str(FlintValue v)
{
    switch (v.type)
    {
    case FLINT_VAL_STR:
        return v.as.s;
    case FLINT_VAL_INT:
        return flint_int_to_str(v.as.i);
    case FLINT_VAL_BOOL:
        return v.as.b ? FLINT_STR("true") : FLINT_STR("false");
    case FLINT_VAL_NULL:
        return FLINT_STR("null");
    case FLINT_VAL_ERROR:
        return flint_concat(FLINT_STR("[Error] "), v.as.s);
    default:
        return FLINT_STR("[Object]");
    }
}

/* =========================
   UTIL E HASHMAP
   ========================= */

flint_int_array flint_range(long long start, long long end)
{
    if (end <= start)
        return (flint_int_array){0};
    size_t n = end - start;
    long long *items = flint_alloc(sizeof(long long) * n);
    for (size_t i = 0; i < n; i++)
        items[i] = start + i;
    return (flint_int_array){items, n, n};
}

FlintDict *flint_dict_new(size_t cap)
{
    FlintDict *d = flint_alloc(sizeof(FlintDict));
    if (cap < 16)
        cap = 16;
    d->capacity = cap;
    d->count = 0;
    d->entries = flint_alloc(sizeof(FlintDictEntry) * cap);
    return d;
}

void flint_dict_set(FlintDict *d, flint_str key, FlintValue val)
{

    if (d->count >= (d->capacity * 3) / 4)
    {
        size_t old_cap = d->capacity;
        FlintDictEntry *old_entries = d->entries;

        d->capacity = old_cap * 2;
        d->entries = flint_alloc(sizeof(FlintDictEntry) * d->capacity);
        d->count = 0;

        for (size_t j = 0; j < old_cap; j++)
        {
            if (old_entries[j].occupied)
            {
                flint_dict_set(d, old_entries[j].key, old_entries[j].value);
            }
        }
    }

    size_t i = flint_hash(key) % d->capacity;
    size_t probes = 0;

    while (d->entries[i].occupied)
    {
        if (flint_str_eq(d->entries[i].key, key))
            break;

        i = (i + 1) % d->capacity;

        if (++probes >= d->capacity)
        {
            flint_panic("Colisao fatal no Dicionario (100% de carga).");
        }
    }

    if (!d->entries[i].occupied)
    {
        d->entries[i].occupied = true;
        d->entries[i].key = key;
        d->count++;
    }
    d->entries[i].value = val;
}

FlintValue flint_dict_get(FlintDict *d, flint_str key)
{
    size_t i = flint_hash(key) % d->capacity;
    while (d->entries[i].occupied)
    {
        if (flint_str_eq(d->entries[i].key, key))
            return d->entries[i].value;
        i = (i + 1) % d->capacity;
    }
    return (FlintValue){FLINT_VAL_NULL};
}

/* =========================
   REDE (HTTP)
   ========================= */

struct FetchMemoryStruct
{
    char *memory;
    size_t size;
};

static size_t flint_fetch_callback(void *contents, size_t size, size_t nmemb, void *userp)
{
    size_t realsize = size * nmemb;
    struct FetchMemoryStruct *mem = (struct FetchMemoryStruct *)userp;
    char *ptr = realloc(mem->memory, mem->size + realsize + 1);
    if (!ptr)
        return 0;
    mem->memory = ptr;
    memcpy(&(mem->memory[mem->size]), contents, realsize);
    mem->size += realsize;
    mem->memory[mem->size] = 0;
    return realsize;
}

static bool curl_initialized = false;
FlintValue flint_fetch(flint_str url)
{
    if (url.len == 0 || !url.ptr)
        return flint_make_error(FLINT_STR("Null or invalid URL provided to fetch"));

    if (!curl_initialized)
    {
        curl_global_init(CURL_GLOBAL_ALL);
        curl_initialized = true;
    }

    CURL *curl = curl_easy_init();
    if (!curl)
        return flint_make_error(FLINT_STR("Failed to init curl"));

    struct FetchMemoryStruct chunk = {.memory = malloc(1), .size = 0};
    char *c_url = to_c_string(url);

    curl_easy_setopt(curl, CURLOPT_URL, c_url);
    curl_easy_setopt(curl, CURLOPT_WRITEFUNCTION, flint_fetch_callback);
    curl_easy_setopt(curl, CURLOPT_WRITEDATA, (void *)&chunk);
    curl_easy_setopt(curl, CURLOPT_FOLLOWLOCATION, 1L);
    curl_easy_setopt(curl, CURLOPT_USERAGENT, "Flint/1.6");

    CURLcode res = curl_easy_perform(curl);

    curl_easy_cleanup(curl);

    if (res != CURLE_OK)
    {
        free(chunk.memory);
        const char *err_msg = curl_easy_strerror(res);
        return flint_make_error(FLINT_SLICE(err_msg, strlen(err_msg)));
    }

    char *buf = flint_alloc_raw(chunk.size + 1);
    memcpy(buf, chunk.memory, chunk.size);
    buf[chunk.size] = '\0';

    free(chunk.memory);
    return flint_make_str(FLINT_SLICE(buf, chunk.size));
}

/* =========================
   JSON PARSER (v1.4)
   ========================= */

static void json_skip_ws(const char **p)
{
    while (isspace((unsigned char)**p))
        (*p)++;
}

static flint_str json_parse_str(const char **p)
{
    (*p)++;
    const char *start = *p;
    while (**p && **p != '"')
    {
        if (**p == '\\' && *(*p + 1))
            (*p) += 2;
        else
            (*p)++;
    }
    size_t len = *p - start;

    char *buf = flint_alloc_raw(len + 1);
    memcpy(buf, start, len);
    buf[len] = '\0';

    if (**p == '"')
        (*p)++;

    return FLINT_SLICE(buf, len);
}

static FlintValue json_parse_value(const char **p);
static FlintDict *json_parse_object(const char **p)
{
    (*p)++;
    FlintDict *dict = flint_dict_new(256);
    json_skip_ws(p);
    while (**p && **p != '}')
    {
        json_skip_ws(p);
        if (**p != '"')
            break;

        flint_str key = json_parse_str(p);
        json_skip_ws(p);
        if (**p == ':')
            (*p)++;

        FlintValue val = json_parse_value(p);
        flint_dict_set(dict, key, val);

        json_skip_ws(p);
        if (**p == ',')
            (*p)++;
    }
    if (**p == '}')
        (*p)++;
    return dict;
}

static FlintValue json_parse_value(const char **p)
{
    json_skip_ws(p);
    if (**p == '"')
    {
        return (FlintValue){FLINT_VAL_STR, .as.s = json_parse_str(p)};
    }
    else if (**p == '{')
    {
        return (FlintValue){FLINT_VAL_DICT, .as.d = json_parse_object(p)};
    }
    else if (**p == 't' && strncmp(*p, "true", 4) == 0)
    {
        *p += 4;
        return (FlintValue){FLINT_VAL_BOOL, .as.b = true};
    }
    else if (**p == 'f' && strncmp(*p, "false", 5) == 0)
    {
        *p += 5;
        return (FlintValue){FLINT_VAL_BOOL, .as.b = false};
    }
    else if (**p == 'n' && strncmp(*p, "null", 4) == 0)
    {
        *p += 4;
        return (FlintValue){FLINT_VAL_NULL, .as.i = 0};
    }
    else if (**p == '-' || isdigit((unsigned char)**p))
    {
        long long val = strtoll(*p, (char **)p, 10);
        if (**p == '.')
        {
            while (**p && (**p == '.' || isdigit((unsigned char)**p)))
                (*p)++;
        }
        return (FlintValue){FLINT_VAL_INT, .as.i = val};
    }
    else if (**p == '[')
    {
        int depth = 1;
        (*p)++;
        while (**p && depth > 0)
        {
            if (**p == '[')
                depth++;
            if (**p == ']')
                depth--;
            (*p)++;
        }
        return (FlintValue){FLINT_VAL_NULL, .as.i = 0};
    }
    (*p)++;
    return (FlintValue){FLINT_VAL_NULL, .as.i = 0};
}

FlintDict *flint_parse_json(flint_str text)
{
    if (text.len == 0 || !text.ptr)
        return NULL;

    const char *p = text.ptr;
    json_skip_ws(&p);
    if (*p == '{')
    {
        return json_parse_object(&p);
    }
    return flint_dict_new(16);
}
