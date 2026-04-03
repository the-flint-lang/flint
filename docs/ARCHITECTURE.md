# Flint Architecture & Design Principles (v1.9.0)

This document outlines the internal architecture of the Flint compiler and its runtime. It is intended for contributors, language nerds, and anyone curious about how a `.fl` script becomes a dependency-free, highly optimized native C99 executable.

## Overview

Flint is not interpreted; it is **transpiled and compiled Ahead-of-Time (AOT)** or executed via an in-memory **JIT Engine**.
The compilation pipeline is strictly divided into two domains: the **Host Domain** (the Zig compiler) and the **Target Domain** (the generated C99 code + Runtime).

The life cycle of a Flint script:

```text
   [ source.fl ]
        │
        ▼
 ┌────────────────┐ 1. Lexer (Zig)
 │  Tokenization  │ Branch-optimized scanning into a Token array.
 └──────┬─────────┘
        │
        ▼
 ┌────────────────┐ 2. Parser & String Pool (Zig)
 │ AST Generation │ Interns str into IDs and builds a pointer-free AstTree.
 └──────┬─────────┘
        │
        ▼
 ┌────────────────┐ 3. Type Checker & Semantic Analyzer
 │  Validation    │ Enforces strict typing using O(1) StringId comparisons.
 └──────┬─────────┘
        │
        ▼
 ┌────────────────┐ 4. Emitter (Zig -> C99)
 │ Code Gen       │ Walks the AST and emits optimized C99 to memory/pipes.
 └──────┬─────────┘
        │
        ▼
 ┌────────────────┐ 5. JIT Engine (libtcc) or Native Linker
 │  Execution     │ JIT runs main() in-memory (~13ms) or Clang builds binary.
 └──────┬─────────┘
        │
        ▼
  [ executable ]    6. Native Binary (Dependency-free)
```

## 1. The Compiler (Zig)

- **Memory Management:** The compiler uses a single, global `std.heap.ArenaAllocator`. AST nodes, tokens, and scopes do not manage their own lifecycles, completely eliminating memory leaks.
- **String Interning:** Every identifier (variable name, function, struct) is stored once in a global `StringPool`. Comparisons are made between `u32` IDs, making the Type Checker extremely fast.
- **AstTree (DOD):** Nodes are stored in a contiguous `std.ArrayList(AstNode)`. Indices (`NodeIndex`) are used instead of pointers, improving cache locality and eliminating memory fragmentation.
- **Lexical Analysis:** A hand-written, branch-optimized Lexer.
- **Type Checker & Error Recovery:** Flint uses a robust semantic analyzer designed for "Fail-Fast" on dependent nodes, but applies **Error Recovery via Poison Types (`.t_error`)** for independent nodes (like array elements). This allows Flint to report multiple contextual errors in a single pass without causing spurious cascading errors downstream. Built-in functions have their signatures natively mapped for AOT validation.
- **Zero-Disco Pipeline:** In `flint run` mode, code is passed via RAM to the JIT engine. In `flint build` mode, code is jetted into the C compiler's STDIN via OS Pipes.
- **Compile-Time Hashing:** Durante a geração de código, o Emitter calcula hashes FNV-1a para chaves de dicionário estáticas e as injeta como literais inteiros na saída C para buscas O(1).

## 2. The Runtime (C99)

### The 4GB Virtual Arena Memory Model

Flint scripts are designed for DevOps — they boot, do their job, and exit. Traditional GC introduces unacceptable latency.

1. On boot, `flint_init()` requests a massive 4GB virtual address space from the Linux kernel using `mmap`.
2. Every allocation is just a pointer bump.
3. **Auto-Arena GC:** When executing `for` loops, Flint injects memory marks implicitly. Processing a 50GB log file line-by-line consumes zero aggregate memory.

### Zero-Copy I/O and `FLINT_C_PATH`

Flint bypasses the Heap and uses `mmap` to map disk data directly to virtual memory. When passing str to native C functions, Flint uses the `FLINT_C_PATH` macro to allocate temporary C-str directly on the **CPU Stack**, generating zero Arena garbage.

### Lazy JSON Parsing

Instead of building massive Node trees in RAM, Flint implements O(1) Lazy JSON scanning. When accessing `payload["key"]`, the runtime scans raw bytes using `memmem`, enabling Flint to query 20MB+ JSON payloads in milliseconds.
