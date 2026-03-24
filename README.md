<div align="center">
<img src="assets/favicon_transparent_bg.svg" alt="Flint Logo" width="120">
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

const user = os.env("USER") ~> fallback("Stranger");
print($"Hello, {user}!");
```

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
    ~> lines()
    ~> grep("root")
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

### Zero-copy I/O & Strings

String operations work on slices (`ptr + len`), avoiding unnecessary allocations. File reads bypass the heap entirely using pure kernel-space `mmap`.

---

### Predictable memory model

Flint uses a 4GB virtual arena allocator:

* fast allocations (pointer bump)
* no fragmentation
* auto-garbage collection inside loops
* zero GC pauses globally

---

## Performance (Summary)

Flint is engineered for maximum throughput in DevOps workloads. In our v1.7.5 benchmarks:

* **JSON Extraction:** ~29x faster than Node.js and ~22x faster than Python (parses 17MB in ~13ms using O(1) Lazy Scanning).
* **Mass File Stat:** ~650x faster than Bash when inspecting 10,000 files.
* **File Cloning:** Outperforms GNU `cp` on cold-cache huge files using Kernel-Space `sendfile`.

See `./benchmarks/` for full details and reproducible tests.

---

## Getting Started

### Requirements

* Zig (0.15.2)
* Clang or GCC
* libcurl (for HTTP support)

### Build from source

```bash
git clone https://github.com/lucaas-d3v/flint.git
cd flint
./ignite.sh
```

### Run your first script

```bash
flint run my_script.fl
```

---

## Stability

Current version: **v1.7.5**

* Core syntax → stable
* Memory model → stable
* Standard library → stable (but expanding)

---

## Architecture

Flint is a transpiler:

```
.fl → AST (Zig) → C99 → native binary
```

Key components:

* Lexer + Recursive Descent Parser (Zig)
* C99 code generation (with Compile-Time Hashing)
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
    ~> lines()
    ~> grep("root")
    ~> strings.join("\n")
    ~> ensure(len(_) > 0, "No root processes found!")
    ~> io.write_file(_, "root_processes.log")
    ~> expect("failed to write file");
```

---

## Contributing

See `docs/CONTRIBUTING.md` for:

* build instructions
* architecture overview
* coding standards

---

## Philosophy

> Build tools that are simple to use, predictable to run, and fast enough to disappear.