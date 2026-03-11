# Contributing to Flint

First off, thank you for considering contributing to Flint!

Flint is designed to be a fast, pipeline-oriented language for DevOps and CLI tooling. To maintain its performance and zero-dependency distribution, we have strict architectural rules. This document will guide you through the process of setting up, understanding the codebase, and submitting your contributions.

## Architectural Philosophy (Read First)

Flint is a transpiler. It is crucial to understand the boundary between the **Compiler** and the **Runtime**:

1. **The Compiler (Zig):** Parses the `.fl` files and generates C99 code. It uses Zig's `std.heap.ArenaAllocator`.
2. **The Runtime (C99):** The standard library (`flint_rt.c` and `flint_rt.h`) embedded into every compiled Flint script. **It uses a custom 4GB Virtual Arena via `mmap`.**

**Golden Rule for the Runtime:** Do NOT use standard `malloc()` or `free()` in `flint_rt.c`. You must use `flint_alloc_raw()` or `flint_alloc_zero()`. The OS will reap the memory when the script exits.

## Development Setup

To build and test Flint locally, you need:

- **Zig:** Version 0.15.2 (to compile the transpiler).
- **Clang:** (to compile the emitted C code).
- **libcurl:** Development headers (e.g., `libcurl4-openssl-dev` on Debian/Ubuntu) for the native `fetch()` function.

### Building from Source
```bash
# Clone the repository
git clone https://codeberg.org/lucaas-d3v/flint.git
cd flint

# Build the compiler
zig build -Doptimize=ReleaseFast -Dcpu=native

# The executable will be available at:
./zig-out/bin/flint
```

### Codebase Anatomy

If you want to fix a bug or add a feature, here is where you should look:

- `src/core/lexer/`: Tokenization logic and keyword hashing.
- `src/core/parser/`: The AST generator. If you are adding new syntax (like a new loop type), start here.
- `src/core/codegen/c_emitter.zig`: Translates the Zig AST into C99 code.
- `src/core/codegen/runtime/`: Contains `flint_rt.h` and `flint_rt.c`. If you are adding a new built-in function (e.g., string manipulation, OS interaction), this is where it goes.

## Testing

Flint uses a snapshot/sanity testing approach. All tests are `.fl` files located in the `./tests/` directory.

Before submitting any Pull Request, you must ensure the test battery passes:
```bash
# Run the built-in test orchestrator
./zig-out/bin/flint test
```

### Adding a New Test

If you fix a bug or add a feature, please add a new `.fl` file to the `./tests/` directory demonstrating the change. The test orchestrator will automatically pick it up, transpile it, compile it with Clang, and verify if the exit code is 0.

## Coding Standards

### Zig Code (The Compiler)

- Always run `zig fmt src/` before committing.
- Avoid raw pointers; use slices whenever possible.
- Handle memory leaks using `std.heap.GeneralPurposeAllocator` in `main.zig` (it's already set up to scream if you leak memory during compilation).

### C Code (The Runtime)

- Adhere strictly to C99. No compiler-specific extensions unless absolutely necessary (like `__auto_type`, which we currently rely on).
- Do not use Garbage Collection concepts. Rely on the bump allocator (`flint_alloc_zero`).
- Prefix all new runtime functions and structs with `flint_` to avoid namespace collisions in the final C output.

## Pull Request Process

1. Fork the repository and create your branch from `main`.
2. **Discuss first:** If you are proposing a massive syntax change or a core architectural shift, please open an Issue first to discuss it. We want to avoid you wasting hours on a PR that doesn't align with Flint's roadmap.
3. **Commit:** Write clear, descriptive commit messages.
4. **Test:** Ensure `./zig-out/bin/flint test` reports all green.
5. **Open the PR:** Describe the problem you are solving and link to any relevant Issues.