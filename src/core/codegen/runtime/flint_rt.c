#include "flint_rt.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <ctype.h>
#include <curl/curl.h>

#define ARENA_CAPACITY (128 * 1024 * 1024)

static char *arena;
static size_t arena_offset;

static int global_argc;
static char **global_argv;

/* =========================
   ARENA E RUNTIME
   ========================= */

void flint_init(int argc, char **argv)
{
    global_argc = argc;
    global_argv = argv;
    arena = malloc(ARENA_CAPACITY);
    if (!arena)
        flint_panic("Arena allocation failed");
    arena_offset = 0;
    curl_global_init(CURL_GLOBAL_ALL);
}

void flint_deinit()
{
    free(arena);
    curl_global_cleanup();
}

void flint_arena_reset()
{
    arena_offset = 0;
}

void *flint_alloc(size_t size)
{
    size = (size + 7) & ~7;
    if (arena_offset + size >= ARENA_CAPACITY)
        flint_panic("Arena out of memory");
    void *ptr = arena + arena_offset;
    arena_offset += size;
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

/* =========================
   PRINT
   ========================= */

void flint_print_str(flint_str s) { printf("%s\n", s ? s : ""); }
void flint_print_int(long long v) { printf("%lld\n", v); }
void flint_print_dict(FlintDict *d) { printf("[Flint Dictionary: %zu keys]\n", d ? d->count : 0); }

void flint_print_val(FlintValue v)
{
    switch (v.type)
    {
    case FLINT_VAL_INT:
        printf("%lld\n", v.as.i);
        break;
    case FLINT_VAL_BOOL:
        printf("%s\n", v.as.b ? "true" : "false");
        break;
    case FLINT_VAL_STR:
        printf("%s\n", v.as.s);
        break;
    case FLINT_VAL_NULL:
        printf("null\n");
        break;
    case FLINT_VAL_DICT:
        flint_print_dict(v.as.d);
        break;
    }
}

/* =========================
   FILE I/O
   ========================= */

flint_str flint_read_file(flint_str path)
{
    FILE *f = fopen(path, "rb");
    if (!f)
        flint_panic("cannot open file");
    fseek(f, 0, SEEK_END);
    size_t size = ftell(f);
    rewind(f);
    char *buf = flint_alloc(size + 1);
    fread(buf, 1, size, f);
    buf[size] = 0;
    fclose(f);
    return buf;
}

bool flint_file_exists(flint_str path)
{
    FILE *f = fopen(path, "r");
    if (!f)
        return false;
    fclose(f);
    return true;
}

void flint_write_file(flint_str text, flint_str path)
{
    FILE *f = fopen(path, "wb");
    if (!f)
        flint_panic("cannot write file");
    fputs(text, f);
    fclose(f);
}

/* =========================
   ENV & PROCESS
   ========================= */

flint_str flint_env(flint_str name)
{
    char *v = getenv(name);
    return v ? v : "";
}

flint_str_array flint_args()
{
    flint_str_array arr;
    arr.count = global_argc;
    arr.capacity = global_argc;
    arr.items = flint_alloc(sizeof(flint_str) * global_argc);
    for (int i = 0; i < global_argc; i++)
        arr.items[i] = global_argv[i];
    return arr;
}

flint_str flint_exec(flint_str cmd)
{
    if (!cmd)
        return "";
    FILE *pipe = popen(cmd, "r");
    if (!pipe)
        flint_panic("Falha ao executar comando");

    size_t capacity = 1024 * 1024;
    char *temp_buf = malloc(capacity);
    size_t total_read = 0, bytes_read = 0;

    while ((bytes_read = fread(temp_buf + total_read, 1, capacity - total_read - 1, pipe)) > 0)
    {
        total_read += bytes_read;
        if (total_read >= capacity - 1024)
        {
            capacity *= 2;
            temp_buf = realloc(temp_buf, capacity);
        }
    }
    temp_buf[total_read] = '\0';
    pclose(pipe);

    flint_str result = (flint_str)flint_alloc(total_read + 1);
    memcpy((void *)result, temp_buf, total_read + 1);
    free(temp_buf);
    return result;
}

/* =========================
   STRINGS
   ========================= */

flint_str flint_trim(flint_str text)
{
    if (!text)
        return "";
    while (isspace((unsigned char)*text))
        text++;
    if (*text == '\0')
        return "";
    const char *end = text + strlen(text) - 1;
    while (end > text && isspace((unsigned char)*end))
        end--;
    size_t len = end - text + 1;
    flint_str result = (flint_str)flint_alloc(len + 1);
    memcpy((void *)result, text, len);
    ((char *)result)[len] = '\0';
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
    size_t count = 0;
    const char *tmp = text;
    while ((tmp = strstr(tmp, target)))
    {
        count++;
        tmp += target_len;
    }
    if (count == 0)
        return text;

    size_t final_len = strlen(text) - (count * target_len) + (count * repl_len);
    flint_str result = (flint_str)flint_alloc(final_len + 1);
    char *dest = (char *)result;
    const char *src = text, *match;

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
    arr.items = flint_alloc(count * sizeof(flint_str));

    size_t idx = 0;
    const char *start = text, *end;
    while ((end = strstr(start, delimiter)))
    {
        size_t chunk_len = end - start;
        flint_str chunk = (flint_str)flint_alloc(chunk_len + 1);
        memcpy((void *)chunk, start, chunk_len);
        ((char *)chunk)[chunk_len] = '\0';
        arr.items[idx++] = chunk;
        start = end + delim_len;
    }
    size_t last_len = strlen(start);
    flint_str last_chunk = (flint_str)flint_alloc(last_len + 1);
    strcpy((char *)last_chunk, start);
    arr.items[idx] = last_chunk;
    return arr;
}

flint_str_array flint_lines(flint_str text)
{
    return flint_split(text, "\n");
}

flint_str flint_join(flint_str_array arr, flint_str sep)
{
    if (arr.count == 0)
        return (flint_str)flint_alloc(1);
    if (!sep)
        sep = "";
    size_t sep_len = strlen(sep);
    size_t total_len = 0;
    for (size_t i = 0; i < arr.count; i++)
        total_len += strlen(arr.items[i]);
    total_len += sep_len * (arr.count - 1);

    flint_str result = (flint_str)flint_alloc(total_len + 1);
    char *current_pos = (char *)result;
    for (size_t i = 0; i < arr.count; i++)
    {
        size_t line_len = strlen(arr.items[i]);
        memcpy(current_pos, arr.items[i], line_len);
        current_pos += line_len;
        if (i < arr.count - 1 && sep_len > 0)
        {
            memcpy(current_pos, sep, sep_len);
            current_pos += sep_len;
        }
    }
    *current_pos = '\0';
    return result;
}

flint_str_array flint_grep(flint_str_array lines, flint_str pattern)
{
    if (lines.count == 0 || !pattern)
        return (flint_str_array){0};
    flint_str *matched = flint_alloc(sizeof(flint_str) * lines.count);
    size_t match_count = 0;
    for (size_t i = 0; i < lines.count; i++)
    {
        if (strstr(lines.items[i], pattern) != NULL)
            matched[match_count++] = lines.items[i];
    }
    flint_str_array res;
    res.items = matched;
    res.count = match_count;
    res.capacity = lines.count;
    return res;
}

flint_str flint_int_to_str(long long num)
{
    char buf[64];
    snprintf(buf, sizeof(buf), "%lld", num);
    size_t len = strlen(buf);
    flint_str res = (flint_str)flint_alloc(len + 1);
    memcpy((void *)res, buf, len + 1);
    return res;
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
        return v.as.b ? "true" : "false";
    case FLINT_VAL_NULL:
        return "null";
    case FLINT_VAL_DICT:
        return "[Flint Dictionary]";
    }

    return "";
}

flint_str flint_concat(flint_str a, flint_str b)
{
    if (!a)
        a = "";
    if (!b)
        b = "";
    size_t len_a = strlen(a);
    size_t len_b = strlen(b);
    flint_str res = (flint_str)flint_alloc(len_a + len_b + 1);
    memcpy((void *)res, a, len_a);
    memcpy((void *)res + len_a, b, len_b + 1);
    return res;
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

static unsigned long hash(flint_str s)
{
    unsigned long h = 5381;
    int c;
    while ((c = *s++))
        h = ((h << 5) + h) + c;
    return h;
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

    size_t i = hash(key) % d->capacity;
    size_t probes = 0;

    while (d->entries[i].occupied)
    {
        if (strcmp(d->entries[i].key, key) == 0)
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
    size_t i = hash(key) % d->capacity;
    while (d->entries[i].occupied)
    {
        if (strcmp(d->entries[i].key, key) == 0)
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

flint_str flint_fetch(flint_str url)
{
    if (!url)
        return "";
    CURL *curl_handle;
    CURLcode res;
    struct FetchMemoryStruct chunk;
    chunk.memory = malloc(1);
    chunk.size = 0;

    curl_handle = curl_easy_init();
    if (curl_handle)
    {
        curl_easy_setopt(curl_handle, CURLOPT_URL, url);
        curl_easy_setopt(curl_handle, CURLOPT_WRITEFUNCTION, flint_fetch_callback);
        curl_easy_setopt(curl_handle, CURLOPT_WRITEDATA, (void *)&chunk);
        curl_easy_setopt(curl_handle, CURLOPT_USERAGENT, "Flint-Lang-v1.4");
        curl_easy_setopt(curl_handle, CURLOPT_FOLLOWLOCATION, 1L);
        res = curl_easy_perform(curl_handle);
        if (res != CURLE_OK)
            flint_panic("Falha na conexao de rede");
        curl_easy_cleanup(curl_handle);
    }

    flint_str result = (flint_str)flint_alloc(chunk.size + 1);
    memcpy((void *)result, chunk.memory, chunk.size + 1);
    free(chunk.memory);
    return result;
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
    flint_str res = (flint_str)flint_alloc(len + 1);
    memcpy((void *)res, start, len);
    ((char *)res)[len] = '\0';
    if (**p == '"')
        (*p)++;
    return res;
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
    if (!text)
        return flint_dict_new(16);
    const char *p = text;
    json_skip_ws(&p);
    if (*p == '{')
    {
        return json_parse_object(&p);
    }
    return flint_dict_new(16);
}