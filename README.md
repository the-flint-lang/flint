<div align="center">
<img src="assets/favicon_transparent_bg.svg" alt="Flint Logo" width="120">
</div>

# > Flint

**A fast, pipeline-oriented language for building reliable CLI tools.**

Stop fighting Bash edge cases.  
Stop paying startup cost for simple scripts.

Flint is a statically-typed, ahead-of-time compiled language designed for system scripting, automation, and data pipelines. It compiles to dependency-free native binaries with near-instant startup time and features a **High-Performance JIT Engine** for instant execution.

---

## Why Flint?

When writing infrastructure scripts today, you usually choose between:

- **Bash** → simple, but fragile and hard to maintain
- **Python / Node.js** → flexible, but slow to start and runtime-heavy
- **Go / Rust** → powerful, but verbose for small tasks

Flint sits in the middle:

> **Simple like a script. Fast like a binary. Safer than both.**

---

## Rust-level Developer Experience

Writing C-transpiled languages usually means dealing with horrific C compiler errors. Flint completely shields you from this with a custom, strict **Type Checker** and a dense, context-aware **Diagnostic Engine**:

```text
[SEMANTIC ERROR][E0308]: Mismatched types in array

~~> teste.fl:1
   |
 1 | const mutante: arr = [1, "two", true];
   |                       ^  ^~~~~
   |                       |  |
   |                       |  found `string`
   |                       |
   |                       type inferred as `int` here
   |

note: arrays in Flint must contain elements of the same type
```

Flint uses "Poison Types" for smart error recovery, meaning it will show you all independent errors in a single pass without cascading false positives.

---

## Industrial-Grade Performance (v1.8.1)

Flint v1.8.1 is engineered using **Data-Oriented Design (DoD)**. By using contiguous memory arrays and a centralized String Pool, the compiler frontend operates at the theoretical limits of modern CPU caches.

- **Near-Zero Startup:** `flint run` executes scripts in **~13ms**, outperforming both Python and Node.js.
- **Native JIT:** Powered by an embedded `libtcc`, Flint compiles code directly in RAM and jumps to machine instructions without the overhead of external processes.
- **Memory Safety:** A custom strict Type Checker shields you from C-level complexity while maintaining zero runtime overhead.

---

## 30-Second Example

```flint
import os;

const user = os.env("USER") ~> fallback("Stranger");
print($"Hello, {user}!");
```

Run instantly with JIT:

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

### Native performance, no runtime

Flint compiles to C99 and produces small native binaries.

* no interpreter
* no virtual machine
* no runtime dependencies

### Data-Oriented Architecture (New)
The compiler uses a pointer-free **AstTree** and **String Interning**, making it significantly faster and more memory-efficient than traditional AST implementations.

### Zero-copy I/O & Strings

String operations work on slices (`ptr + len`), avoiding unnecessary allocations. File reads bypass the heap entirely using pure kernel-space `mmap`.

### Predictable memory model

Flint uses a 4GB virtual arena allocator:

* fast allocations (pointer bump)
* no fragmentation
* auto-garbage collection inside loops
* zero GC pauses globally

---

## Performance (Summary)

Flint is engineered for maximum throughput in DevOps workloads. In our v1.8.1 benchmarks:

* **JSON Extraction:** ~29x faster than Node.js and ~22x faster than Python (parses 17MB in ~13ms using O(1) Lazy Scanning).
* **Mass File Stat:** ~650x faster than Bash when inspecting 10,000 files.
* **File Cloning:** Outperforms GNU `cp` on cold-cache huge files using Kernel-Space `sendfile`.

See  [`./benchmarks/`](benchmarks/) for full details and reproducible tests.

---

## Getting Started

### Requirements

* Zig (0.15.2)
* Clang, GCC or TCC
* libcurl & libtcc (development headers)

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

## Architecture & Stability

Current version: **v1.8.1**

Flint is a transpiler:
`.fl → AST (Zig) → Type Checker → C99 → native binary`

* Core syntax → stable
* Memory model → stable
* Standard library → stable (but expanding)

More details in [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) and [`docs/LANGUAGE.md`](docs/LANGUAGE.md).

---

## Philosophy

> Build tools that are simple to use, predictable to run, and fast enough to disappear.
