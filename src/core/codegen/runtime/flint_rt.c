#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif

#ifndef _POSIX_C_SOURCE
#define _POSIX_C_SOURCE 200809L
#endif

#include "flint_rt.h"

#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <ctype.h>
#include <curl/curl.h>
#include <dirent.h>
#include <errno.h>
#include <sys/sendfile.h>
#include <sys/wait.h>
#include <unistd.h>
#include <poll.h>
#include <limits.h>

#include <spawn.h>
#include <limits.h>

extern char **environ;

static int global_argc;
static char **global_argv;

/* =========================
ARENA E RUNTIME
========================= */

#define ARENA_CAPACITY (4ULL * 1024 * 1024 * 1024)

static char *arena_base = NULL;
static size_t arena_offset = 0;

void flint_init(int argc, char **argv)
{

    global_argc = argc;
    global_argv = argv;

    arena_base = mmap(NULL, ARENA_CAPACITY, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS | MAP_NORESERVE, -1, 0);
    if (arena_base == MAP_FAILED)
        flint_panic("Fatal flaw: OS refused Virtual Arena.");
}

void flint_deinit()
{
    munmap(arena_base, ARENA_CAPACITY);
}

void flint_arena_reset()
{
    arena_offset = 0;
}

void *flint_alloc_raw(size_t size)
{
    size = (size + 7) & ~7;
    if (arena_offset + size > ARENA_CAPACITY)
    {
        flint_panic("Arena out of memory! Maximum capacity (4GB) exceeded.");
    }
    void *ptr = (void *)(arena_base + arena_offset);
    arena_offset += size;
    return ptr;
}

void *flint_alloc_zero(size_t size)
{
    void *ptr = flint_alloc_raw(size);
    memset(ptr, 0, size);
    return ptr;
}

typedef size_t FlintArenaMark;

FlintArenaMark flint_arena_mark(void)
{
    return arena_offset;
}

void flint_arena_release(FlintArenaMark m)
{
    if (m <= arena_offset)
        arena_offset = m;
}

void flint_panic(const char *msg)
{
    fprintf(stderr, "\n\033[41;37;1m [RUNTIME PANIC] \033[0m\n");
    fprintf(stderr, "  \033[1;36m~~>\033[0m %s\n", msg);
    fprintf(stderr, "  \033[1;36m~~>\033[0m Halting execution.\n\n");
    exit(1);
}
void flint_exit(int code)
{
    flint_deinit();
    exit(code);
}

/* =========================
   BUILDERS (BOXING)
   ========================= */

FlintValue flint_make_int(long long v) { return (FlintValue){FLINT_VAL_INT, .as.i = v}; }
FlintValue flint_make_float(double v)
{
    FlintValue val;
    val.type = FLINT_VAL_FLOAT;
    memcpy(&val.as.f, &v, sizeof(double));
    return val;
}
FlintValue flint_make_bool(bool v) { return (FlintValue){FLINT_VAL_BOOL, .as.b = v}; }
FlintValue flint_make_str(flint_str v) { return (FlintValue){FLINT_VAL_STR, .as.s = v}; }

FlintValue flint_make_error(flint_str msg) { return (FlintValue){FLINT_VAL_ERROR, .as.s = msg}; }
bool flint_is_err(FlintValue v) { return v.type == FLINT_VAL_ERROR; }
flint_str flint_get_err(FlintValue v)
{
    return v.type == FLINT_VAL_ERROR ? v.as.s : FLINT_STR("");
}

static inline FlintValue flint_make_stream(flint_stream s)
{
    FlintValue v;
    v.type = FLINT_VAL_STREAM;
    v.as.stream = s;

    return v;
}

/* =========================
   PRINT
   ========================= */

void flint_print_str(flint_str text)
{
    printf("%.*s\n", (int)text.len, text.ptr);
    fflush(stdout);
}
void flint_print_int(long long v) { printf("%lld\n", v); }
void flint_print_float(double v) { printf("%g\n", v); }
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
    case FLINT_VAL_FLOAT:
    {
        double real_f;
        memcpy(&real_f, &v.as.f, sizeof(double));
        printf("%g\n", real_f);
        break;
    }
    case FLINT_VAL_BOOL:
        printf("%s\n", v.as.b ? "true" : "false");
        break;
    case FLINT_VAL_STR:
        printf("%.*s\n", (int)v.as.s.len, v.as.s.ptr);
        break;
    case FLINT_VAL_DICT:
        printf("[Dict]\n");
        break;
    case FLINT_VAL_STREAM:
        printf("[Stream]\n");
        break;
    case FLINT_VAL_ARRAY:
        printf("[Array]\n");
        break;
    case FLINT_VAL_JSON_LAZY:
        printf("[Lazy JSON Document]\n");
        break;
    case FLINT_VAL_ERROR:
        printf("\033[1;31mERROR\033[0m: %.*s\n", (int)v.as.s.len, v.as.s.ptr);
        break;
    }
}

void flint_print_bool(bool b)
{
    printf("%s\n", b ? "true" : "false");
}

// stderr
void flint_printerr_str(flint_str text)
{
    fprintf(stderr, "%.*s\n", (int)text.len, text.ptr);
    fflush(stderr);
}

void flint_printerr_int(long long v) { fprintf(stderr, "%lld\n", v); }
void flint_printerr_float(double v) { fprintf(stderr, "%g\n", v); }
void flint_printerr_dict(FlintDict *d) { fprintf(stderr, "[Flint Dictionary: %zu keys]\n", d ? d->count : 0); }

void flint_printerr_val(FlintValue v)
{
    switch (v.type)
    {
    case FLINT_VAL_NULL:
        fprintf(stderr, "null\n");
        break;
    case FLINT_VAL_INT:
        fprintf(stderr, "%lld\n", v.as.i);
        break;
    case FLINT_VAL_FLOAT:
    {
        double real_f;
        memcpy(&real_f, &v.as.f, sizeof(double));
        fprintf(stderr, "%g\n", real_f);
        break;
    }
    case FLINT_VAL_BOOL:
        fprintf(stderr, "%s\n", v.as.b ? "true" : "false");
        break;
    case FLINT_VAL_STR:
        fprintf(stderr, "%.*s\n", (int)v.as.s.len, v.as.s.ptr);
        break;
    case FLINT_VAL_DICT:
        fprintf(stderr, "[Dict]\n");
        break;
    case FLINT_VAL_STREAM:
        fprintf(stderr, "[Stream]\n");
        break;
    case FLINT_VAL_ARRAY:
        fprintf(stderr, "[Array]\n");
        break;
    case FLINT_VAL_JSON_LAZY:
        fprintf(stderr, "[Lazy JSON Document]\n");
        break;
    case FLINT_VAL_ERROR:
        fprintf(stderr, "\033[1;31mERROR\033[0m: %.*s\n", (int)v.as.s.len, v.as.s.ptr);
        break;
    }
}

void flint_printerr_bool(bool b)
{
    fprintf(stderr, "%s\n", b ? "true" : "false");
}

/* =========================
   INPUT
   ========================= */

flint_str flint_read_line(flint_str s)
{
    char buffer[1024];

    if (s.len > 0)
    {
        fprintf(stdout, "%.*s", (int)s.len, s.ptr);
    }

    // read to a temp buffer
    if (fgets(buffer, sizeof(buffer), stdin) != NULL)
    {
        size_t len = strlen(buffer);

        if (len > 0 && buffer[len - 1] == '\n')
        {
            len--;
            if (len > 0 && buffer[len - 1] == '\r')
            {
                len--;
            }
        }

        char *arena_buf = flint_alloc_raw(len + 1);
        memcpy(arena_buf, buffer, len);
        arena_buf[len] = '\0';

        // return the flint str slice
        return FLINT_SLICE(arena_buf, len);
    }

    return FLINT_STR("");
}

/* =========================
   FILE I/O
   ========================= */

#define FLINT_C_PATH(dest_name, fstr)                                            \
    char dest_name[PATH_MAX];                                                    \
    do                                                                           \
    {                                                                            \
        size_t _len = (fstr).len < (PATH_MAX - 1) ? (fstr).len : (PATH_MAX - 1); \
        memcpy(dest_name, (fstr).ptr, _len);                                     \
        dest_name[_len] = '\0';                                                  \
    } while (0)

FlintValue flint_read_file(flint_str path)
{
    FLINT_C_PATH(c_path, path);
    int fd = open(c_path, O_RDONLY);

    if (fd < 0)
        return flint_make_error(FLINT_SLICE(strerror(errno), strlen(strerror(errno))));

    struct stat sb;
    if (fstat(fd, &sb) < 0)
    {
        close(fd);
        return flint_make_error(FLINT_SLICE(strerror(errno), strlen(strerror(errno))));
    }

    if (sb.st_size == 0)
    {
        close(fd);
        return flint_make_str(FLINT_STR(""));
    }

    char *mapped = mmap(NULL, sb.st_size, PROT_READ, MAP_PRIVATE, fd, 0);
    close(fd);

    if (mapped == MAP_FAILED)
        return flint_make_error(FLINT_SLICE(strerror(errno), strlen(strerror(errno))));

    return flint_make_str(FLINT_SLICE(mapped, sb.st_size));
}

FlintValue flint_write_file(flint_str text, flint_str filepath)
{
    FLINT_C_PATH(c_path, filepath);
    FILE *f = fopen(c_path, "wb");

    if (!f)
        return flint_make_error(FLINT_SLICE(strerror(errno), strlen(strerror(errno))));

    size_t written = fwrite(text.ptr, 1, text.len, f);
    fclose(f);

    if (written != text.len)
        return flint_make_error(FLINT_STR("IO Error: Failed to write all bytes to disk"));

    return flint_make_bool(true);
}

bool flint_file_exists(flint_str filepath)
{
    FLINT_C_PATH(c_path, filepath);
    FILE *f = fopen(c_path, "r");
    if (f)
    {
        fclose(f);
        return true;
    }
    return false;
}

FlintValue flint_copy(flint_str src, flint_str dest)
{
    FLINT_C_PATH(c_src, src);
    FLINT_C_PATH(c_dest, dest);

    int source_fd = open(c_src, O_RDONLY);
    if (source_fd < 0)
        return flint_make_error(FLINT_SLICE(strerror(errno), strlen(strerror(errno))));

    struct stat stat_buf;
    if (fstat(source_fd, &stat_buf) < 0)
    {
        close(source_fd);
        return flint_make_error(FLINT_SLICE(strerror(errno), strlen(strerror(errno))));
    }

    int dest_fd = open(c_dest, O_WRONLY | O_CREAT | O_TRUNC, stat_buf.st_mode);
    if (dest_fd < 0)
    {
        close(source_fd);
        return flint_make_error(FLINT_SLICE(strerror(errno), strlen(strerror(errno))));
    }

    posix_fadvise(source_fd, 0, 0, POSIX_FADV_SEQUENTIAL);

    off_t offset = 0;
    size_t remaining = stat_buf.st_size;

    while (remaining > 0)
    {
        ssize_t bytes_copied = sendfile(dest_fd, source_fd, &offset, remaining);
        if (bytes_copied <= 0)
        {
            close(source_fd);
            close(dest_fd);
            return flint_make_error(FLINT_SLICE(strerror(errno), strlen(strerror(errno))));
        }
        remaining -= bytes_copied;
    }

    close(source_fd);
    close(dest_fd);
    return flint_make_bool(true);
}

FlintValue flint_ls(flint_str path)
{
    FLINT_C_PATH(c_path, path);
    DIR *d = opendir(c_path);
    if (!d)
    {
        return flint_make_error(FLINT_SLICE(strerror(errno), strlen(strerror(errno))));
    }

    struct dirent *dir;
    size_t total_len = 0;
    size_t max_size = 4096;

    char *buf = malloc(max_size);
    if (!buf)
    {
        closedir(d);
        return flint_make_error(FLINT_STR("Fatal: Out of memory during ls"));
    }

    while ((dir = readdir(d)) != NULL)
    {
        if (strcmp(dir->d_name, ".") == 0 || strcmp(dir->d_name, "..") == 0)
            continue;

        size_t name_len = strlen(dir->d_name);
        if (total_len + name_len + 2 >= max_size)
        {
            max_size *= 2;
            char *new_buf = realloc(buf, max_size);
            if (!new_buf)
            {
                free(buf);
                closedir(d);
                return flint_make_error(FLINT_STR("Fatal: Out of memory during ls realloc"));
            }
            buf = new_buf;
        }

        memcpy(buf + total_len, dir->d_name, name_len);
        total_len += name_len;
        buf[total_len] = '\n';
        total_len++;
    }
    closedir(d);

    if (total_len > 0)
        total_len--;

    char *final_buf = flint_alloc_raw(total_len);
    memcpy(final_buf, buf, total_len);

    free(buf);

    return flint_make_str(FLINT_SLICE(final_buf, total_len));
}

void flint_write(flint_str way, flint_str msg)
{
    if (msg.len > 0)
    {
        if (way.len != 6)
        {
            flint_panic("IO Error: Stream not recognized (must be 'stdout' or 'stderr').");
        }

        if (memcmp(way.ptr, FLINT_STR("stdout").ptr, 6) == 0)
        {
            fprintf(stdout, "%.*s", (int)msg.len, msg.ptr);
            fflush(stdout);
        }
        else if (memcmp(way.ptr, FLINT_STR("stderr").ptr, 6) == 0)
        {
            fprintf(stderr, "%.*s", (int)msg.len, msg.ptr);
            fflush(stderr);
        }
        else
        {
            flint_panic("IO Error: Invalid stream name.");
        }
    }
}

bool flint_is_root()
{
    return geteuid() == 0;
}

FlintValue flint_require_root(flint_str_array plus_args)
{
    if (flint_is_root())
    {
        return flint_make_bool(true);
    }

    size_t total = 1 + global_argc + plus_args.count + 1;
    char **new_argv = flint_alloc_zero(sizeof(char *) * total);

    new_argv[0] = "sudo";
    for (size_t i = 0; i < global_argc; i++)
    {
        new_argv[i + 1] = global_argv[i];
    }

    for (size_t i = 0; i < plus_args.count; i++)
    {

        flint_str arg = plus_args.items[i];
        char *safe_str = flint_alloc_zero(arg.len + 1);
        memcpy(safe_str, arg.ptr, arg.len);

        new_argv[global_argc + 1 + i] = safe_str;
    }

    new_argv[total - 1] = NULL;

    // replace the current process
    execvp("sudo", new_argv);

    // if execvp works, it never gets here
    return flint_make_error(FLINT_STR("Falha ao elevar privilégios. O 'sudo' está disponível?"));
}

/* =========================
   SLICES
   ========================= */

flint_str flint_slice_str(flint_str s, long long start, long long end)
{
    if (s.len == 0 || s.ptr == NULL)
        return FLINT_STR("");

    if (start < 0)
        start = 0;
    if (end == LLONG_MAX || end > (long long)s.len)
        end = (long long)s.len;
    if (start >= end || start >= (long long)s.len)
        return FLINT_STR("");

    return FLINT_SLICE(s.ptr + start, (size_t)(end - start));
}

// macro to instantiate array slices with zero-copy
#define IMPLEMENT_SLICE_ARRAY(FuncName, ArrayType)                        \
    ArrayType FuncName(ArrayType a, long long start, long long end)       \
    {                                                                     \
        if (a.count == 0 || a.items == NULL)                              \
        {                                                                 \
            return (ArrayType){.items = NULL, .count = 0, .capacity = 0}; \
        }                                                                 \
        if (start < 0)                                                    \
            start = 0;                                                    \
        if (end == LLONG_MAX || end > (long long)a.count)                 \
            end = (long long)a.count;                                     \
        if (start >= end || start >= (long long)a.count)                  \
        {                                                                 \
            return (ArrayType){.items = NULL, .count = 0, .capacity = 0}; \
        }                                                                 \
        return (ArrayType){                                               \
            .items = a.items + start,                                     \
            .count = (size_t)(end - start),                               \
            .capacity = (size_t)(end - start)};                           \
    }

IMPLEMENT_SLICE_ARRAY(flint_slice_int_array, flint_int_array)
IMPLEMENT_SLICE_ARRAY(flint_slice_str_array, flint_str_array)
IMPLEMENT_SLICE_ARRAY(flint_slice_bool_array, flint_bool_array)

/* =========================
   ENV & PROCESS
   ========================= */

flint_str flint_env_get(flint_str name)
{
    FLINT_C_PATH(c_name, name);
    char *v = getenv(c_name);
    if (!v)
        return FLINT_STR("");
    return FLINT_SLICE(v, strlen(v));
}

void flint_env_set(flint_str name, flint_str value)
{
    FLINT_C_PATH(c_name, name);
    FLINT_C_PATH(c_value, value);
    setenv(c_name, c_value, 1);
}

bool flint_env_exists(flint_str name)
{
    FLINT_C_PATH(c_name, name);
    return getenv(c_name) != NULL;
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

    char *c_cmd = malloc(cmd.len + 1);
    if (!c_cmd)
        flint_panic("Out of memory preparing exec");
    memcpy(c_cmd, cmd.ptr, cmd.len);
    c_cmd[cmd.len] = '\0';

    FILE *pipe = popen(c_cmd, "r");
    free(c_cmd);

    if (!pipe)
        flint_panic("popen failed");

    char temp_buf[1024];
    size_t total_read = 0;
    size_t max_size = 4096;

    char *buf = malloc(max_size);
    if (!buf)
        flint_panic("Out of memory in exec (malloc)");

    while (fgets(temp_buf, sizeof(temp_buf), pipe) != NULL)
    {
        size_t len = strlen(temp_buf);
        if (total_read + len >= max_size)
        {
            max_size *= 2;

            char *new_buf = realloc(buf, max_size);
            if (!new_buf)
            {
                free(buf);
                flint_panic("Out of memory in exec (realloc)");
            }
            buf = new_buf;
        }

        memcpy(buf + total_read, temp_buf, len);
        total_read += len;
    }
    pclose(pipe);

    char *final_arena_buf = flint_alloc_raw(total_read);
    memcpy(final_arena_buf, buf, total_read);

    free(buf);

    return FLINT_SLICE(final_arena_buf, total_read);
}

FlintValue flint_spawn(flint_str cmd, bool echo)
{
    if (cmd.len == 0 || !cmd.ptr)
        return flint_make_error(FLINT_STR("Empty command"));

    FLINT_C_PATH(c_cmd, cmd);
    int out_pipe[2], err_pipe[2];

    if (pipe(out_pipe) == -1 || pipe(err_pipe) == -1)
    {
        return flint_make_error(FLINT_SLICE(strerror(errno), strlen(strerror(errno))));
    }

    posix_spawn_file_actions_t actions;
    posix_spawn_file_actions_init(&actions);

    posix_spawn_file_actions_addclose(&actions, out_pipe[0]);
    posix_spawn_file_actions_addclose(&actions, err_pipe[0]);
    posix_spawn_file_actions_adddup2(&actions, out_pipe[1], STDOUT_FILENO);
    posix_spawn_file_actions_adddup2(&actions, err_pipe[1], STDERR_FILENO);
    posix_spawn_file_actions_addclose(&actions, out_pipe[1]);
    posix_spawn_file_actions_addclose(&actions, err_pipe[1]);

    posix_spawn_file_actions_adddup2(&actions, STDIN_FILENO, STDIN_FILENO);

    char *argv[] = {"sh", "-c", c_cmd, NULL};
    pid_t pid;

    int status_spawn = posix_spawnp(&pid, "sh", &actions, NULL, argv, environ);
    posix_spawn_file_actions_destroy(&actions);

    if (status_spawn != 0)
    {
        close(out_pipe[0]);
        close(out_pipe[1]);
        close(err_pipe[0]);
        close(err_pipe[1]);
        return flint_make_error(FLINT_SLICE(strerror(status_spawn), strlen(strerror(status_spawn))));
    }

    close(out_pipe[1]);
    close(err_pipe[1]);

    size_t out_cap = 4096, err_cap = 4096;
    size_t out_len = 0, err_len = 0;

    char *out_buf = malloc(out_cap);
    char *err_buf = malloc(err_cap);

    struct pollfd fds[2];
    fds[0].fd = out_pipe[0];
    fds[0].events = POLLIN;
    fds[1].fd = err_pipe[0];
    fds[1].events = POLLIN;

    while (fds[0].fd != -1 || fds[1].fd != -1)
    {
        if (poll(fds, 2, -1) == -1)
            break;

        for (int i = 0; i < 2; i++)
        {
            if (fds[i].fd == -1)
                continue;

            if (fds[i].revents & POLLIN)
            {
                char **buf = (i == 0) ? &out_buf : &err_buf;
                size_t *len = (i == 0) ? &out_len : &err_len;
                size_t *cap = (i == 0) ? &out_cap : &err_cap;

                if (*len + 1024 >= *cap)
                {
                    *cap *= 2;
                    char *new_buf = realloc(*buf, *cap);
                    if (!new_buf)
                        flint_panic("Out of memory in spawn (realloc)");
                    *buf = new_buf;
                }

                ssize_t n = read(fds[i].fd, *buf + *len, 1024);
                if (n > 0)
                {
                    if (echo)
                    {
                        write((i == 0) ? STDOUT_FILENO : STDERR_FILENO, *buf + *len, n);
                    }

                    *len += n;
                }
                else
                {
                    close(fds[i].fd);
                    fds[i].fd = -1;
                }
            }
            else if (fds[i].revents & (POLLHUP | POLLERR | POLLNVAL))
            {
                close(fds[i].fd);
                fds[i].fd = -1;
            }
        }
    }

    int status;
    waitpid(pid, &status, 0);
    int exit_code = WIFEXITED(status) ? WEXITSTATUS(status) : 128;

    char *final_out = flint_alloc_raw(out_len);
    memcpy(final_out, out_buf, out_len);
    free(out_buf);

    char *final_err = flint_alloc_raw(err_len);
    memcpy(final_err, err_buf, err_len);
    free(err_buf);

    FlintDict *dict = flint_dict_new(4);
    flint_dict_set(dict, FLINT_STR("exit_code"), flint_make_int(exit_code));
    flint_dict_set(dict, FLINT_STR("stdout"), flint_make_str(FLINT_SLICE(final_out, out_len)));
    flint_dict_set(dict, FLINT_STR("stderr"), flint_make_str(FLINT_SLICE(final_err, err_len)));

    return (FlintValue){FLINT_VAL_DICT, .as.d = dict};
}

bool flint_is_tty()
{
    return isatty(STDOUT_FILENO);
}

bool flint_is_dir(flint_str path)
{
    FLINT_C_PATH(c_path, path);
    struct stat sb;
    return (stat(c_path, &sb) == 0 && S_ISDIR(sb.st_mode));
}

bool flint_is_file(flint_str path)
{
    FLINT_C_PATH(c_path, path);
    struct stat sb;
    return (stat(c_path, &sb) == 0 && S_ISREG(sb.st_mode));
}

FlintValue flint_file_size(flint_str path)
{
    FLINT_C_PATH(c_path, path);
    struct stat sb;
    if (stat(c_path, &sb) == 0)
        return flint_make_int((long long)sb.st_size);
    return flint_make_error(FLINT_SLICE(strerror(errno), strlen(strerror(errno))));
}

FlintValue flint_mkdir(flint_str path)
{
    FLINT_C_PATH(c_path, path);
    if (mkdir(c_path, 0777) == 0)
        return flint_make_bool(true);
    return flint_make_error(FLINT_SLICE(strerror(errno), strlen(strerror(errno))));
}

FlintValue flint_rm(flint_str path)
{
    FLINT_C_PATH(c_path, path);
    if (unlink(c_path) == 0)
        return flint_make_bool(true);
    return flint_make_error(FLINT_SLICE(strerror(errno), strlen(strerror(errno))));
}

FlintValue flint_rm_dir(flint_str path)
{
    FLINT_C_PATH(c_path, path);
    if (rmdir(c_path) == 0)
        return flint_make_bool(true);
    return flint_make_error(FLINT_SLICE(strerror(errno), strlen(strerror(errno))));
}

FlintValue flint_touch(flint_str path)
{
    FLINT_C_PATH(c_path, path);
    int fd = open(c_path, O_CREAT | O_WRONLY, 0666);
    if (fd >= 0)
    {
        close(fd);
        return flint_make_bool(true);
    }
    return flint_make_error(FLINT_SLICE(strerror(errno), strlen(strerror(errno))));
}

FlintValue flint_mv(flint_str old_path, flint_str new_path)
{
    FLINT_C_PATH(c_old, old_path);
    FLINT_C_PATH(c_new, new_path);
    if (rename(c_old, c_new) == 0)
        return flint_make_bool(true);
    return flint_make_error(FLINT_SLICE(strerror(errno), strlen(strerror(errno))));
}

/* =========================
   STREAMS
   ========================= */

flint_stream flint_str_stream(flint_str text)
{
    return (flint_stream){
        .source = text,
        .current_pos = 0,
        .has_next = (text.len > 0),
        .filter_pattern = FLINT_STR(""),
    };
}

flint_str flint_stream_next(flint_stream *stream)
{
    while (stream->has_next)
    {
        size_t start = stream->current_pos;
        size_t end = start;

        // scans the bytes until it reaches the next '\n' or the end of the content
        while (end < stream->source.len && stream->source.ptr[end] != '\n')
        {
            end++;
        }

        flint_str line;
        line.ptr = stream->source.ptr + start;
        line.len = end - start;

        // if the last character before \n is a \r, we cut it from the slice
        if (line.len > 0 && line.ptr[line.len - 1] == '\r')
        {
            line.len--;
        }

        if (end < stream->source.len)
        {
            stream->current_pos = end + 1;
        }
        else
        {
            stream->has_next = false;
        }

        if (stream->filter_pattern.len > 0)
        {
            // if line not contains a patter skip
            if (!memmem(line.ptr, line.len, stream->filter_pattern.ptr, stream->filter_pattern.len))
            {
                continue;
            }
        }

        return line;
    }

    return FLINT_STR("");
}

FlintValue flint_grep_inner(FlintValue iterable, FlintValue pattern_val)
{
    if (pattern_val.type != FLINT_VAL_STR)
    {
        return flint_make_error(FLINT_STR("Grep Error: pattern must be a string"));
    }

    flint_str pattern = pattern_val.as.s;

    if (iterable.type == FLINT_VAL_STREAM)
    {
        flint_stream s = iterable.as.stream;
        s.filter_pattern = pattern;
        return flint_make_stream(s);
    }

    if (iterable.type == FLINT_VAL_STR)
    {
        flint_stream s = flint_str_stream(iterable.as.s);
        s.filter_pattern = pattern;
        return flint_make_stream(s);
    }

    return flint_make_error(FLINT_STR("Grep Error: Invalid iterable type"));
}

bool flint_os_command_exists(flint_str bin)
{
    if (bin.len == 0 || !bin.ptr)
        return false;

    if (memchr(bin.ptr, '/', bin.len) != NULL)
    {
        if (bin.len >= PATH_MAX)
            return false;

        char *path = flint_alloc_zero(bin.len + 1);
        memcpy(path, bin.ptr, bin.len);
        path[bin.len] = '\0';

        return access(path, X_OK) == 0;
    }

    // default search in system PATH
    const char *path_env = getenv("PATH");
    if (!path_env)
        return false;

    char *full_path = flint_alloc_zero(PATH_MAX);
    const char *start = path_env;
    const char *end;

    while ((end = strchr(start, ':')) != NULL)
    {
        size_t dir_len = end - start;

        // checks if the concatenation fits in the buffer (+2 for '/' and '\0')
        if (dir_len + 1 + bin.len < PATH_MAX)
        {
            memcpy(full_path, start, dir_len);
            full_path[dir_len] = '/';
            memcpy(full_path + dir_len + 1, bin.ptr, bin.len);
            full_path[dir_len + 1 + bin.len] = '\0';

            if (access(full_path, X_OK) == 0)
            {
                return true;
            }
        }
        start = end + 1;
    }

    size_t dir_len = strlen(start);
    if (dir_len > 0 && dir_len + 1 + bin.len < PATH_MAX)
    {
        memcpy(full_path, start, dir_len);
        full_path[dir_len] = '/';
        memcpy(full_path + dir_len + 1, bin.ptr, bin.len);
        full_path[dir_len + 1 + bin.len] = '\0';

        if (access(full_path, X_OK) == 0)
        {
            return true;
        }
    }

    return false;
}

/* =========================
   str
   ========================= */

bool flint_str_eql(flint_str a, flint_str b)
{
    if (a.len != b.len)
        return false;
    if (a.len == 0)
        return true;
    return memcmp(a.ptr, b.ptr, a.len) == 0;
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

flint_str flint_build_str_array(flint_str *parts, size_t count)
{
    if (count == 0)
    {
        return FLINT_STR("");
    }

    // calc lenth
    size_t total_len = 0;
    for (size_t i = 0; i < count; i++)
    {
        total_len += parts[i].len;
    }

    if (total_len == 0)
    {
        return FLINT_STR("");
    }

    char *buf = flint_alloc_raw(total_len + 1);
    char *dest = buf;

    for (size_t i = 0; i < count; i++)
    {
        if (parts[i].len > 0)
        {
            memcpy(dest, parts[i].ptr, parts[i].len);
            dest += parts[i].len;
        }
    }

    *dest = '\0';
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

FlintValue flint_lines_inner(FlintValue text_val)
{
    if (text_val.type != FLINT_VAL_STR)
    {
        return flint_make_error(FLINT_STR("Type Error: lines() expects a string"));
    }

    flint_stream s = flint_str_stream(text_val.as.s);

    return flint_make_stream(s);
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
    if (num == 0)
        return FLINT_STR("0");

    char temp[32];
    char *p = temp + 31;
    *p = '\0';

    unsigned long long n = (num < 0) ? (unsigned long long)(-num) : (unsigned long long)num;

    while (n > 0)
    {
        *(--p) = '0' + (n % 10);
        n /= 10;
    }

    if (num < 0)
    {
        *(--p) = '-';
    }

    size_t len = (temp + 31) - p;
    char *buf = flint_alloc_raw(len + 1);
    memcpy(buf, p, len + 1);

    return FLINT_SLICE(buf, len);
}

flint_str flint_float_to_str(double num)
{
    char temp[64];
    int len = snprintf(temp, sizeof(temp), "%g", num);
    if (len <= 0)
        return FLINT_STR("0");

    char *buf = flint_alloc_raw(len + 1);
    memcpy(buf, temp, len + 1);

    return FLINT_SLICE(buf, len);
}

flint_str flint_to_str_func(FlintValue v)
{
    switch (v.type)
    {
    case FLINT_VAL_STR:
        return v.as.s;
    case FLINT_VAL_INT:
        return flint_int_to_str(v.as.i);
    case FLINT_VAL_FLOAT:
    {
        double real_f;
        memcpy(&real_f, &v.as.f, sizeof(double));
        return flint_float_to_str(real_f);
    }
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

flint_str_array flint_chars(flint_str text)
{
    flint_str_array arr;
    arr.items = NULL;
    arr.count = 0;
    arr.capacity = 0;

    if (text.len == 0 || !text.ptr)
    {
        return arr;
    }

    arr.items = flint_alloc_zero(text.len * sizeof(flint_str));
    arr.count = text.len;
    arr.capacity = text.len;

    for (size_t i = 0; i < text.len; i++)
    {
        arr.items[i].ptr = text.ptr + i;
        arr.items[i].len = 1;
    }

    return arr;
}

/* =========================
   UTIL E HASHMAP
   ========================= */

static uint64_t flint_hash(flint_str s)
{
    uint64_t h = 1469598103934665603ULL;
    for (size_t i = 0; i < s.len; i++)
    {
        h = (h ^ (unsigned char)s.ptr[i]) * 1099511628211ULL;
    }
    return h;
}

flint_int_array flint_range(long long start, long long end)
{
    if (end <= start)
        return (flint_int_array){0};
    size_t n = end - start;
    long long *items = flint_alloc_zero(sizeof(long long) * n);
    for (size_t i = 0; i < n; i++)
        items[i] = start + i;
    return (flint_int_array){items, n, n};
}

FlintDict *flint_dict_new(size_t cap)
{
    FlintDict *d = flint_alloc_raw(sizeof(FlintDict));
    if (cap < 16)
        cap = 16;
    d->capacity = cap;
    d->count = 0;

    d->entries = flint_alloc_zero(sizeof(FlintDictEntry) * cap);
    return d;
}

void flint_dict_set(FlintDict *d, flint_str key, FlintValue val)
{
    if (d->count >= (d->capacity * 3) / 4)
    {
        size_t old_cap = d->capacity;
        FlintDictEntry *old_entries = d->entries;

        d->capacity = old_cap * 2;
        d->entries = flint_alloc_zero(sizeof(FlintDictEntry) * d->capacity);
        d->count = 0;

        for (size_t j = 0; j < old_cap; j++)
        {
            if (old_entries[j].hash != 0)
            {

                size_t idx = old_entries[j].hash % d->capacity;
                while (d->entries[idx].hash != 0)
                {
                    idx = (idx + 1) % d->capacity;
                }
                d->entries[idx] = old_entries[j];
                d->count++;
            }
        }
    }

    uint64_t h = flint_hash(key);
    if (h == 0)
        h = 1;

    size_t i = h % d->capacity;
    size_t probes = 0;

    while (d->entries[i].hash != 0)
    {
        if (d->entries[i].hash == h && flint_str_eql(d->entries[i].key, key))
            break;

        i = (i + 1) % d->capacity;
        if (++probes >= d->capacity)
            flint_panic("Fatal Colisao in Dictionary.");
    }

    if (d->entries[i].hash == 0)
    {
        d->entries[i].hash = h;
        d->entries[i].key = key;
        d->count++;
    }
    d->entries[i].value = val;
}

FlintValue flint_dict_get(FlintDict *d, flint_str key)
{
    uint64_t h = flint_hash(key);
    if (h == 0)
        h = 1;

    size_t i = h % d->capacity;
    while (d->entries[i].hash != 0)
    {
        if (d->entries[i].hash == h && flint_str_eql(d->entries[i].key, key))
            return d->entries[i].value;
        i = (i + 1) % d->capacity;
    }
    return (FlintValue){FLINT_VAL_NULL};
}

// new gen 1.9.0
FlintValue flint_dict_get_hashed(FlintDict *d, flint_str key, uint64_t h)
{
    if (h == 0)
        h = 1;

    size_t i = h % d->capacity;
    while (d->entries[i].hash != 0)
    {
        if (d->entries[i].hash == h && flint_str_eql(d->entries[i].key, key))
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

    FLINT_C_PATH(c_url, url);

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
   JSON PARSER (v1.9.0)
   ========================= */

static long long fast_atoll(const char **p)
{
    long long res = 0;
    int sign = 1;
    if (**p == '-')
    {
        sign = -1;
        (*p)++;
    }
    while (**p >= '0' && **p <= '9')
    {
        res = res * 10 + (**p - '0');
        (*p)++;
    }
    return res * sign;
}

static FlintValue json_parse_value(const char **p);

FlintValue flint_lazy_json_get(flint_str json_str, flint_str key)
{
    if (json_str.len == 0 || key.len == 0)
        return (FlintValue){FLINT_VAL_NULL};

    char search_buf[256];
    size_t search_len = key.len + 2;
    if (search_len >= sizeof(search_buf))
        return (FlintValue){FLINT_VAL_NULL};

    search_buf[0] = '"';
    memcpy(search_buf + 1, key.ptr, key.len);
    search_buf[key.len + 1] = '"';

    const char *match = memmem(json_str.ptr, json_str.len, search_buf, search_len);
    if (match)
    {
        const char *p = match + search_len;

        while (p < json_str.ptr + json_str.len && (*p == ' ' || *p == '\t' || *p == '\n' || *p == '\r'))
            p++;

        if (p < json_str.ptr + json_str.len && *p == ':')
        {
            p++;

            return json_parse_value(&p);
        }
    }
    return (FlintValue){FLINT_VAL_NULL};
}

FlintValue flint_parse_json(flint_str text)
{
    if (text.len == 0 || !text.ptr)
        return (FlintValue){FLINT_VAL_NULL};

    return (FlintValue){FLINT_VAL_JSON_LAZY, .as.s = text};
}

static void json_skip_ws(const char **p)
{

    while (**p == ' ' || **p == '\n' || **p == '\t' || **p == '\r')
    {
        (*p)++;
    }
}

static flint_str json_parse_str(const char **p)
{
    (*p)++;
    const char *start = *p;

    while (**p && **p != '"')
    {
        if (**p == '\\' && *(*p + 1))
        {
            (*p) += 2;
        }
        else
        {
            (*p)++;
        }
    }

    size_t len = *p - start;
    if (**p == '"')
        (*p)++;

    return FLINT_SLICE(start, len);
}

static FlintValue json_parse_value(const char **p);

static FlintDict *json_parse_object(const char **p, size_t estimated_cap)
{
    (*p)++;
    FlintDict *dict = flint_dict_new(estimated_cap);
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
        return (FlintValue){FLINT_VAL_DICT, .as.d = json_parse_object(p, 16)};
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
        long long val = fast_atoll(p);

        if (**p == '.')
        {
            // Skip decimal places (Flint doesn't support floats natively yet)
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

FlintValue flint_ensure(FlintValue val, bool condition, flint_str err_msg)
{
    if (!condition)
    {
        return flint_make_error(err_msg);
    }
    return val;
}

// ============================================================================
// FLINT STANDARD LIBRARY ABI BINDINGS
// ============================================================================

#define str_to_int(v) flint_to_int(v)
#define str_int_to_str(n) flint_int_to_str(n)
#define str_to_str(v) flint_to_str(v)
#define str_join(a, sep) flint_join(a, sep)
#define str_trim(text) flint_trim(text)
#define str_split(t, d) flint_split(t, d)
#define str_count_matches(t, p) flint_count_matches(t, p)
#define str_replace(t, tg, r) flint_replace(t, tg, r)
#define str_concat(a, b) flint_concat(a, b)

#define process_exec(cmd) flint_exec(cmd)
#define process_spawn(cmd, echo) flint_spawn(cmd, echo)
#define process_exit(code) flint_exit(code)

#define fs_is_dir(path) flint_is_dir(path)
#define fs_is_file(path) flint_is_file(path)
#define fs_read_file(path) flint_read_file(path)
#define fs_write_file(t, p) flint_write_file(t, p)
#define fs_rm(path) flint_rm(path)
#define fs_mkdir(path) flint_mkdir(path)
#define fs_rm_dir(path) flint_rm_dir(path)
#define fs_file_size(path) flint_file_size(path)
#define fs_ls(path) flint_ls(path)
#define fs_copy(s, d) flint_copy(s, d)
#define fs_mv(o, n) flint_mv(o, n)
#define fs_touch(p) flint_touch(p)

#define os_exec(cmd) flint_exec(cmd)
#define os_spawn(cmd, echo) flint_spawn(cmd, echo)
#define os_exit(code) flint_exit(code)
#define os_env(name) flint_env(name)
#define os_is_root() flint_is_root()
#define os_is_tty() flint_is_tty()
#define os_command_exists(bin) flint_os_command_exists(bin)
#define os_rm(p) flint_rm(p)
#define os_ls(p) flint_ls(p)
#define os_is_file(p) flint_is_file(p)
#define os_file_size(p) flint_file_size(p)
#define os_args() flint_args()

#define io_read_file(path) flint_read_file(path)
#define io_write_file(t, p) flint_write_file(t, p)

#define env_get(name) flint_env_get(name)
#define env_set(name, val) flint_env_set(name, val)
#define env_exists(name) flint_env_exists(name)

#define http_fetch(url) flint_fetch(url)

#define json_parse(t) flint_parse_json(t)

#define utils_is_err(v) flint_is_err(FLINT_BOX(v))
#define utils_get_err(v) flint_get_err(FLINT_BOX(v))

#define term_clear()            \
    do                          \
    {                           \
        printf("\033[H\033[J"); \
        fflush(stdout);         \
    } while (0)
