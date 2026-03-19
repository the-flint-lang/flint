# Flint Architecture & Design Principles

This document outlines the internal architecture of the Flint compiler and its runtime. It is intended for contributors, language nerds, and anyone curious about how a `.fl` script becomes a dependency-free, highly optimized native C99 executable.

## Overview

Flint is not interpreted; it is **transpiled and compiled Ahead-of-Time (AOT)**.
The compilation pipeline is strictly divided into two domains: the **Host Domain** (the Zig compiler) and the **Target Domain** (the generated C99 code + Runtime).

The life cycle of a Flint script:
```text
   [ source.fl ]
        │
        ▼
 ┌────────────────┐ 1. Lexer (Zig)
 │  Tokenization  │ Reads text and outputs an array of Tokens.
 └──────┬─────────┘
        │
        ▼
 ┌────────────────┐ 2. Parser (Zig)
 │ AST Generation │ Validates grammar and builds the Abstract Syntax Tree.
 └──────┬─────────┘
        │
        ▼
 ┌────────────────┐ 3. Emitter (Zig -> C99)
 │ Code           │ Walks the AST and emits pure C99 code to `.flint_temp.c`.
 │ Generation     │
 └──────┬─────────┘
        │
        ▼
 ┌────────────────┐ 4. Linker & Canonical Resolution
 │  C Compilation │ Clang combines `.flint_temp.c` + `flint_rt.c` (Runtime).
 └──────┬─────────┘
        │
        ▼
  [ executable ]    5. Native Binary
                    Dependency-free, ready to run.
```

## 1. The Compiler (Zig)

The compiler itself is written in Zig to leverage its memory safety, `comptime` capabilities, and raw performance.

- **Memory Management:** The compiler uses Zig's `std.heap.ArenaAllocator` for all AST nodes and tokens. When the compilation finishes, the entire arena is dropped at once. We track leaks rigorously using `std.heap.GeneralPurposeAllocator` in debug modes.
- **Lexical Analysis:** A hand-written, branch-optimized Lexer (`src/core/lexer.zig`). It uses a static string map for keyword lookups, avoiding expensive hash map allocations for basic syntax checking.
- **Parsing:** A recursive descent parser (`src/core/parser.zig`). It builds a strictly typed AST (`src/core/parser/ast.zig`).
- **Canonical Module Resolution (Linker):** Flint prevents the "Diamond Alias Bug" by decoupling the user's alias from the canonical module name. If `io.fl` is imported multiple times under different aliases, the linker routes all C-calls to a single, consolidated C-compilation unit, eliminating binary bloat and reference errors.

## 2. The Runtime (C99)

This is where Flint's true philosophy lies. The generated code relies heavily on `flint_rt.c` and `flint_rt.h`.

### The 4GB Virtual Arena Memory Model

Flint scripts are designed for DevOps and CLI tooling — they boot, do their job, and exit. Traditional Garbage Collection (GC) or manual `malloc`/`free` churn introduces unacceptable latency for these tasks.

To solve this, Flint uses a **Virtual Arena**:

1. On boot, `flint_init()` requests a massive 4GB virtual address space from the Linux kernel using `mmap(MAP_NORESERVE | MAP_ANONYMOUS)`.
2. This operation is virtually instantaneous because no physical RAM is actually allocated yet.
3. Every allocation in Flint (`flint_alloc_raw`) is just a pointer bump: `arena_offset += size`.
4. As the script uses memory, the OS lazily pages in physical RAM via page faults.
5. When the script terminates, the OS instantly reaps the entire mapping. **Zero GC pauses, zero memory fragmentation.**

### Dynamic Typing & Boxing (FlintValue)

While Flint generates static C code, the language itself feels dynamic. This is achieved through a tagged union called `FlintValue`:
```c
typedef struct {
    FlintValType type; // ENUM: INT, BOOL, STR, DICT, ERROR
    union {
        long long i;
        bool b;
        flint_str s;
        FlintDict *d;
    } as;
} FlintValue;
```

All variables in Flint are boxed into this structure when interacting with the standard library, allowing functions to accept multiple types generically using C11's `_Generic` combined with Variadic Macros (`__VA_ARGS__`) under the hood to ensure safe compile-time polymorphism.

## 3. Key Language Features

### The Pipeline Operator `~>`

Flint's signature feature is the pipeline operator. At the AST level, `a ~> b(c)` is syntactically transformed into `b(a, c)`. The Emitter resolves this during code generation, meaning there is **zero runtime overhead** for using pipelines. It is pure syntactic sugar for function composition.

### Pipeline Safety (`expect` and `fallback`)

To maintain the visual flow of the pipeline without verbose `try/catch` blocks, Flint embeds zero-cost C macros directly into the runtime:

- `~> expect("msg")`: Checks if the preceding `FlintValue` is an error or null. If so, it intercepts the CPU, formats a stack trace with the native OS error, and triggers `exit(1)`.
- `~> fallback(alt_val)`: If the preceding value fails, it silently swaps it for the `alt_val` and keeps the pipeline moving safely.

### AOT JSON Struct Mapping

Parsing JSON dynamically in Python is slow due to dictionary lookups and reflection. Flint solves this by doing **Ahead-Of-Time Struct Mapping**.

When you define a `struct` in Flint, the Emitter generates a specialized, static C function (e.g., `__parse_Config_from_dict()`). This function maps JSON keys directly to physical C struct memory offsets, bypassing dynamic reflection entirely.

### Zero-Copy Strings (`flint_str`)

Strings in Flint are "fat pointers" (a pointer to the data and a length `size_t`). Slicing a string, reading a file (`mmap`), or splitting text does not copy the underlying bytes. It merely creates a new `flint_str` slice pointing to the original memory, making text processing blazingly fast.

## 4. Error Handling

Flint does not have exceptions. It uses Zig-inspired `catch` blocks.

At the C level, errors are just `FlintValue` structs with the type `FLINT_VAL_ERROR`. The `catch` block simply checks the enum type: if it's an error, it unwraps the string message and executes the fallback block; otherwise, it returns the value.

---

*Built for engineers who want the speed of C with the ergonomics of modern pipelines.*