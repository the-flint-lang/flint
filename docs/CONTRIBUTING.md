# Contributing to Flint

First off, thank you for considering contributing to Flint!

Flint is designed to be a fast, pipeline-oriented language for DevOps and CLI tooling. To maintain its performance and zero-dependency distribution, we have strict architectural rules.

## Architectural Philosophy (Read First)

Flint is a transpiler. It is crucial to understand the boundary between the **Compiler** and the **Runtime**:

1. **The Compiler (Zig):** Parses the `.fl` files and generates C99 code. It uses Zig's `std.heap.ArenaAllocator`.
2. **The Runtime (C99):** The standard library embedded into every compiled Flint script. **It uses a custom 4GB Virtual Arena via `mmap`.**

**Golden Rule for the Runtime (Memory Management):**
Do NOT use standard `malloc()` or `free()` for final data structures. You must use `flint_alloc_raw()`.
*However*, if you are reading an incoming stream of unknown size, **you must NOT grow buffers inside the Arena**.

1. Use `malloc/realloc` as a temporary scratchpad.
2. Build the full data.
3. Call `flint_alloc_raw()` exactly once to copy the final data to the Arena.
4. Call `free()` on the scratchpad. This prevents Arena leaks!

## Development Setup

To build and test Flint locally, you need:

- **Zig:** Version 0.15.2
- **Clang:** (to compile the emitted C code).
- **libcurl:** Development headers.

### Building from Source (Self-Hosting)

```bash
git clone https://github.com/lucaas-d3v/flint.git
cd flint

# Trigger bootstrap to build the initial compiler
./ignite.sh
```

### Codebase Anatomy

If you want to fix a bug or add a feature, here is where you should look:

- `src/core/lexer/`: Tokenization logic and keyword hashing.
- `src/core/parser/`: The AST generator. Start here for new syntax.
- `src/core/analyzer/type_checker.zig`: The semantic analyzer. Enforces types, pipeline arity, and blocks undefined behavior.
- `src/core/errors/diagnostics.zig`: The visual engine that builds the Rust-style terminal error outputs.
- `src/root.zig`: The Linker and Canonical Module Resolver.
- `src/core/codegen/c_emitter.zig`: Translates the Zig AST into C99 code.
- `src/core/codegen/runtime/`: Contains `flint_rt.h` and `flint_rt.c`. Add new built-in functions here.

## Testing

Flint uses a snapshot/sanity testing approach. All tests are `.fl` files located in the `./tests/` directory.

Before submitting any Pull Request, you must ensure the test battery passes:

```bash
flint test
```