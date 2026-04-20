# Flint Architecture (v1.14.0-dev)

For contributors, language nerds, and anyone curious about how a `.fl` script
becomes a dependency-free native binary.

---

## Overview

Flint is **transpiled and compiled AOT**.
The pipeline is divided in two domains: **Host Domain** (Zig compiler) and
**Target Domain** (generated C99 + Runtime).

Life cycle of a Flint script:
```text
   [ source.fl ]
        │
        ▼
 ┌────────────────┐ 1. Lexer (Zig)
 │  Tokenization  │ Branch-optimized scan into Token array.
 └──────┬─────────┘
        │
        ▼
 ┌────────────────┐ 2. Parser & String Pool (Zig)
 │ AST Generation │ Interns strings into IDs, builds pointer-free AstTree.
 └──────┬─────────┘
        │
        ▼
 ┌────────────────┐ 3. Type Checker & Semantic Analyzer
 │  Validation    │ Enforces strict typing using O(1) StringId comparisons.
 └──────┬─────────┘
        │
        ▼
 ┌────────────────┐ 4. Emitter (Zig -> C99)
 │ Code Gen       │ Walk AST and emit optimized C99 to memory/pipes.
 └──────┬─────────┘
        │
        ▼
 ┌────────────────┐ 
 │  Execution     │ 5. Native Linker
 └──────┬─────────┘
        │
        ▼
  [ executable ]    6. Native Binary (Dependency-free)
```

---

## 1. The Compiler (Zig)

**Memory Management**
Single global `std.heap.ArenaAllocator`. AST nodes, tokens, and scopes don't
manage own lifecycles. Zero memory leaks by design.

**String Interning**
Every identifier stored once in a global `StringPool`.
Comparisons use `u32` IDs — makes the Type Checker fast.

**AstTree (Data Oriented Design)**
Nodes stored in contiguous `std.ArrayList(AstNode)`.
Uses indices (`NodeIndex`) instead of pointers — better cache locality,
zero memory fragmentation.

**Lexical Analysis**
Hand-written, branch-optimized Lexer.

**Type Checker & Error Recovery**
Fail-Fast on dependent nodes, but apply **Poison Types (`.t_error`)** for
independent nodes like array elements. This let Flint report multiple errors
in single pass without cascade false positives.

**Zero-Disco Pipeline**
`flint run` → code pass via RAM to JIT engine.
`flint build` → code piped to C compiler STDIN via OS Pipes.

**Compile-Time Hashing**
Emitter calculate FNV-1a hashes for static dict keys and inject as integer
literals in C output — O(1) lookups at runtime.

---

## 2. The Runtime (C99)

### 4GB Virtual Arena

Flint scripts boot, do the job, and exit. Traditional GC introduce unacceptable latency.

1. On boot, `flint_init()` request 4GB virtual address space from Linux kernel via `mmap`.
2. Every allocation is just a pointer bump.
3. **Auto-Arena GC:** `stream` loops inject memory marks implicit. Process a 50GB log
   file line-by-line consume zero aggregate memory.

### Zero-Copy I/O and `FLINT_C_PATH`

Flint bypass the Heap and use `mmap` to map disk data direct to virtual memory.
When passing strings to native C functions, `FLINT_C_PATH` macro allocate temporary
C-strings on the **CPU Stack** — zero Arena garbage.

### Lazy JSON Parsing

Instead of building massive Node trees in RAM, Flint implement O(1) Lazy JSON scanning.
When you access `payload["key"]`, runtime scan raw bytes using `memmem`.
Query 20MB+ JSON payloads in milliseconds.