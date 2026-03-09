<div align="center">
    <img src="assets/favicon_transparent_bg.png" alt="Flint Logo" width="120">
</div>

# > flint

**A pipeline-oriented system language for robust CLI tools.** *Stop writing fragile Bash. Stop waiting for Python to boot.*

Flint is a statically-typed, ahead-of-time (AOT) compiled language designed specifically to replace complex shell scripts and slow-starting interpreted languages in DevOps and infrastructure environments. It transpiles to pure C99, yielding dependency-free native binaries that execute in milliseconds.

## The Engineering Dilemma

If you are writing infrastructure tooling, you face a miserable trilemma today:
1. **Bash is a minefield:** Silent failures, whitespace explosions, and everything-is-a-string typing make scripts unmaintainable past 50 lines.
2. **Python/Node.js are bloated:** Bootstrapping a VM/Interpreter just to parse a text file or invoke an OS command adds unacceptable latency to fast-moving CLI workflows.
3. **Go/Rust are verbose:** General-purpose systems languages require massive boilerplate for simple I/O, regex, and process invocation.

## The Flint Architecture (v1.2)

Flint takes the expressiveness of functional data pipelines and brutally enforces it at the C-memory level. 

* **The Pipeline Operator (`~>`):** Data flows forward. No nested function hell. The result of the left expression becomes the first argument of the right function.
* **C99 Transpilation:** Flint does not reinvent the wheel. The compiler (written in Zig) transpiles your code to strict C99 and uses your host's `clang`/`gcc` to heavily optimize it.
* **Arena Allocator (Zero GC Pauses):** Memory is managed via a monolithic 64MB bump allocator. Scripts run fast, allocate continuously, and rely on the OS to reap the memory upon exit. Zero garbage collection cycles. Maximum cache locality.
* **Fail-Fast Philosophy:** No silent failures. If an I/O operation fails or an array goes out of bounds, the Flint runtime panics, prints a clean error, and exits. 

## Show, Don't Tell

**The Bash Way:**
```bash
#!/bin/bash
USER=$(whoami)
ps aux | grep "$USER" | awk '{print $2, $11}' > user_procs.log

```

*Fragile, relies on external binaries, fails silently if pipes break.*

**The Flint Way:**

```flint
const usuario = env("USER");

print("Collecting processes...");

exec("ps aux")
    ~> lines()
    ~> grep(usuario)
    ~> join("\n")
    ~> write_file("user_procs.log");

print("Completed in 0.001s.");

```

*Compiled to native machine code. Statically typed. Memory-safe via Arena.*

## Advanced Primitives (Available in v1.2)

Flint brings modern data structures to raw C performance:

* **Dynamic Arrays:** `const ports = [80, 443]; push(ports, 8080);`
* **HashMaps (djb2 Engine):** `const config = { "host": "aws", "secure": true };`
* **Native String Manipulation:** Zero-copy slicing, `trim()`, `split()`, and `replace()`.

## Getting Started (Building from Source)

The Flint compiler is written in Zig. You need Zig `0.15.2` (to compile flint locally) and `clang` (or `gcc`) installed on your system (to compile your .fl).

```bash
git clone   https://codeberg.org/lucaas-d3v/flint.git
cd flint
zig build -Doptimize=ReleaseFast
sudo ./install.sh

```

Compile and run your first script:

```bash
flint run my_script.fl

```

*(Use `flint build my_script.fl` to generate the standalone binary).*

## Status: V1.2 (Foundation Complete)

Flint is not a toy, but it is currently in strict development. The v1.2 architecture establishes the core transpiler, OS interop, dynamic arrays, and memory arena.
Upcoming milestones (v1.3+):

* Module System (`import`)
* Native HTTP Client (`fetch`)
* Custom Structs
