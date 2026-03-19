<div align="center">
<img src="assets/favicon_transparent_bg.svg" alt="Flint Logo" width="200">
</div>

# > flint

**A fast, pipeline-oriented language for building reliable CLI tools.**

Stop fighting Bash edge cases.  
Stop paying startup cost for simple scripts.

Flint is a statically-typed, ahead-of-time compiled language designed for system scripting, automation, and data pipelines. It compiles to dependency-free native binaries with near-instant startup time.

---

## Why Flint?

When writing infrastructure scripts today, you usually choose between:

- **Bash** → simple, but fragile and hard to maintain
- **Python / Node.js** → flexible, but slow to start and runtime-heavy
- **Go / Rust** → powerful, but verbose for small tasks

Flint sits in the middle:

> **Simple like a script. Fast like a binary. Safer than both.**

---

## 30-Second Example

```flint
import os;
import strings;

const user = os.env("USER") ~> fallback("Stranger");

print("Hello, " ~> strings.concat(user) ~> strings.concat("!"));
````

Run instantly:

```bash
flint run hello.fl
```

Or compile to a native binary:

```bash
flint build hello.fl
```

---

## When to Use Flint

Flint works best for:

* CLI tools and automation scripts
* DevOps workflows and CI/CD pipelines
* Data processing (logs, JSON, system output)
* Process orchestration (spawning and piping commands)

---

## When NOT to Use Flint

Flint is intentionally focused. It is **not** a general-purpose language.

Avoid Flint for:

* High-concurrency servers → use Go or Rust
* Machine learning or heavy math → use Python or Julia
* GUI applications → no support for rendering/windowing
* Large ecosystems → Flint has a minimal standard library

---

## Core Ideas

### Pipeline-first syntax

```flint
os.exec("ps aux")
    ~> strings.lines()
    ~> strings.grep("root")
    ~> strings.join("\n")
```

Readable, linear data flow — no nested calls.

---

### Native performance, no runtime

Flint compiles to C99 and produces small native binaries.

* no interpreter
* no virtual machine
* no runtime dependencies

---

### Zero-copy strings

String operations work on slices (`ptr + len`), avoiding unnecessary allocations.

---

### Predictable memory model

Flint uses a virtual arena allocator:

* fast allocations (pointer bump)
* no fragmentation
* no garbage collection pauses

---

## Performance (Summary)

Flint is designed for fast startup and efficient data processing.

In internal benchmarks:

* faster than Python for JSON and I/O-heavy workloads
* comparable to native tools like `grep` in throughput
* significantly lower CPU overhead in file operations

See `./benchmarks/` for full details and reproducible tests.

---

## Getting Started

### Requirements

* Zig (0.15.2)
* Clang or GCC
* libcurl (for HTTP support)

### Build from source

```bash
git clone https://codeberg.org/lucaas-d3v/flint.git
cd flint
./bootstrap.sh
```

### Run your first script

```bash
flint run my_script.fl
```

---

## Stability

Current version: **v1.7.x**

* Core syntax → stable
* Memory model → stable
* Standard library → evolving (breaking changes possible)

---

## Architecture

Flint is a transpiler:

```
.fl → AST (Zig) → C99 → native binary
```

Key components:

* Lexer + Recursive Descent Parser (Zig)
* C99 code generation
* Embedded runtime (`flint_rt.c`)
* Virtual memory arena (mmap-based)

More details in:

* `docs/ARCHITECTURE.md`
* `docs/LANGUAGE.md`
* `docs/STDLIB.md`

---

## Example: Replacing a Bash Pipeline

```flint
import os;
import strings;
import io;

os.exec("ps aux")
    ~> strings.lines()
    ~> strings.grep("root")
    ~> strings.join("\n")
    ~> io.write_file("root_processes.log")
    ~> expect("failed to write file");
```

---

## Project Status

Flint is actively developed and optimized for its core use case:
**fast, reliable system scripting.**

Planned:

* streaming pipelines (large files)
* async/network improvements
* LSP support

---

## Contributing

See `docs/CONTRIBUTING.md` for:

* build instructions
* architecture overview
* coding standards

---

## Philosophy

> Build tools that are simple to use, predictable to run, and fast enough to disappear.