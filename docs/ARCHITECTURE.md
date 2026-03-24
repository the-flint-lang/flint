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
 │  Tokenization  │ Reads text and outputs an array of Tokens in O(1) allocation.
 └──────┬─────────┘
        │
        ▼
 ┌────────────────┐ 2. Parser (Zig)
 │ AST Generation │ Validates grammar and builds the Abstract Syntax Tree using a Global Arena.
 └──────┬─────────┘
        │
        ▼
 ┌────────────────┐ 3. Emitter (Zig -> C99)
 │ Code           │ Walks the AST, injects Compile-Time Hashes, and emits pure C99 code.
 │ Generation     │
 └──────┬─────────┘
        │
        ▼
 ┌────────────────┐ 4. Linker & Canonical Resolution
 │  C Compilation │ Clang combines `.flint_temp<hash_file>.c` + `flint_rt.c` (Runtime) with -O3 optimizations.
 └──────┬─────────┘
        │
        ▼
  [ executable ]    5. Native Binary
                    Dependency-free, ready to run.
```

## 1. The Compiler (Zig)

The compiler itself is written in Zig to leverage its memory safety, `comptime` capabilities, and raw performance.

- **Memory Management:** The compiler uses a single, global `std.heap.ArenaAllocator` for the entire compilation process. AST nodes, tokens, and scopes do not manage their own lifecycles, completely eliminating memory leaks and dangling pointers. When compilation finishes, the OS reaps the Arena.
- **Lexical Analysis:** A hand-written, branch-optimized Lexer (`src/core/lexer.zig`). It uses a static string map for keyword lookups and reads memory contiguously without bounds-checking overhead.
- **Compile-Time Hashing:** During code generation, the Emitter calculates FNV-1a hashes for static dictionary keys and injects them as integer literals into the C output. This allows the runtime to achieve O(1) dictionary lookups without spending CPU cycles hashing strings dynamically.
- **Canonical Module Resolution (Linker):** Flint prevents the "Diamond Alias Bug" by decoupling the user's alias from the canonical module name. If `io.fl` is imported multiple times, the linker routes all C-calls to a single compilation unit.

## 2. The Runtime (C99)

This is where Flint's true philosophy lies. The generated code relies heavily on `flint_rt.c` and `flint_rt.h`.

### The 4GB Virtual Arena Memory Model

Flint scripts are designed for DevOps and CLI tooling — they boot, do their job, and exit. Traditional Garbage Collection (GC) or manual `malloc`/`free` churn introduces unacceptable latency.

1. On boot, `flint_init()` requests a massive 4GB virtual address space from the Linux kernel using `mmap`.
2. Every allocation in Flint (`flint_alloc_raw`) is just a pointer bump: `arena_offset += size`.
3. **Auto-Arena GC:** When executing `for` loops or streaming data, Flint injects `flint_arena_mark` and `flint_arena_release` implicitly. This ensures that processing a 50GB log file line-by-line consumes zero aggregate memory, safely recycling the Arena per iteration.

### Zero-Copy I/O and `FLINT_C_PATH`
Flint eliminates the overhead of talking to the Operating System. File reads bypass the Heap entirely and use `mmap` to map disk data directly to virtual memory. When passing strings to native C functions (which require null-terminated `\0` strings), Flint uses the `FLINT_C_PATH` macro to allocate temporary C-strings directly on the **CPU Stack**, generating zero Arena garbage.

### Lazy JSON Parsing
Instead of building massive Node trees in RAM, Flint implements O(1) Lazy JSON scanning. When accessing `payload["key"]`, the runtime scans the raw bytes using highly optimized `memmem` instructions, extracts the targeted slice, and returns it. This enables Flint to query 20MB+ JSON payloads in a few milliseconds.