# Contributing to Flint

Thanks for interest in contribute to Flint!

Flint is a fast, pipeline-oriented language for DevOps and CLI tooling.
To keep performance and zero-dependency distribution, we have strict architectural rules.

---

## Architectural Philosophy (Read First)

Flint is a transpiler. You need understand the boundary between **Compiler** and **Runtime**:

1. **Compiler (Zig):** Parse `.fl` files and generate C99 code. Uses Zig `std.heap.ArenaAllocator`.
2. **Runtime (C99):** Standard library embedded in every compiled Flint script. **Uses a custom 4GB Virtual Arena via `mmap`.**

### Golden Rule for Runtime (Memory Management)

Don't use `malloc()` or `free()` for final data structures. Use `flint_alloc_raw()`.

But if you reading a incoming stream of unknown size, **don't grow buffers inside the Arena**.

Do this instead:

1. Use `malloc/realloc` as temporary scratchpad.
2. Build the full data.
3. Call `flint_alloc_raw()` once to copy final data to Arena.
4. Call `free()` on the scratchpad.

> This prevents Arena leaks.

---

## Development Setup

Requirements:

* Zig (0.15.2)
* Clang (to compile emitted C code)
* libcurl & libtcc (Dev headers)

### Building from Source
```bash
git clone https://github.com/lucaas-d3v/flint.git
cd flint
chmod +x ignite.sh
./ignite.sh
```

---

## Codebase Anatomy

Where to look when fixing a bug or adding a feature:

- [`../src/core/lexer/`](../src/core/lexer/) — Tokenization and keyword hashing.
- [`../src/core/parser/`](../src/core/parser/) — AST generator. Start here for new syntax.
- [`../src/core/analyzer/type_checker.zig`](../src/core/analyzer/type_checker.zig) — Semantic analyzer. Enforces types, pipeline arity, blocks UB.
- [`../src/core/errors/diagnostics.zig`](../src/core/errors/diagnostics.zig) — Visual engine that build the terminal error outputs.
- [`../src/root.zig`](../src/root.zig) — Linker and Canonical Module Resolver.
- [`../src/core/codegen/c_emitter.zig`](../src/core/codegen/c_emitter.zig) — Translate Zig AST to C99.
- [`../src/core/codegen/runtime/`](../src/core/codegen/runtime/) — [`flint_rt.h`](../src/core/codegen/runtime/flint_rt.h) and [`flint_rt.c`](../src/core/codegen/runtime/flint_rt.c). Add new built-in functions here.

---

## Testing

Flint uses snapshot/sanity testing. All tests are `.fl` files in [`../tests/`](../tests/).

Before any Pull Request, make sure the test battery pass:
```bash
flint test
```