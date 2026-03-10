<div align="center">
<img src="../assets/favicon_transparent_bg.png" alt="Flint Logo" width="120">
</div>

# > flint

**A pipeline-oriented system language for robust CLI tools.** *Stop writing fragile Bash. Stop waiting for Python to boot.*

Flint is a statically-typed, ahead-of-time (AOT) compiled language designed specifically to replace complex shell scripts and slow-starting interpreted languages in DevOps and infrastructure environments. It transpiles to pure C99, yielding dependency-free native binaries that execute in milliseconds.

## The Engineering Dilemma

If you are writing infrastructure tooling, you face a miserable trilemma today:

1. **Bash is a minefield:** Silent failures, whitespace explosions, and everything-is-a-string typing make scripts unmaintainable past 50 lines.
2. **Python/Node.js are bloated:** Bootstrapping a VM/Interpreter just to parse a JSON or invoke an OS command adds unacceptable latency to fast-moving CLI workflows.
3. **Go/Rust are verbose:** General-purpose systems languages require massive boilerplate for simple I/O, regex, and process invocation.

## The Flint Architecture (v1.6)

Flint takes the expressiveness of functional data pipelines and brutally enforces it at the hardware level.

* **The Pipeline Operator (`~>`):** Data flows forward. No nested function hell. The result of the left expression becomes the first argument of the right function.
* **Elastic Linked-Block Arena:** Memory is managed via a highly optimized, elastic linked-block allocator (starting at a tiny 8MB footprint). Scripts boot instantly, scale infinitely without `malloc` overhead, and rely on the OS to reap memory upon exit. Zero garbage collection pauses.
* **Zero-Copy String Slices:** The C-string `\0` terminator overhead has been eradicated. All strings are "Fat Pointers" (`ptr` + `len`), making operations like `split()`, `trim()`, and `lines()` $O(1)$ in memory allocation.
* **Errors as Values (Zig-Style):** No silent crashes. I/O and Network failures are intercepted via a zero-cost `catch |err|` inline block, keeping your CI/CD pipelines bulletproof without the overhead of stack unwinding.

## Show, Don't Tell

### Scenario 1: The OS Level (Killing Bash)

*Fragile Bash relies on external binaries and fails silently if pipes break. Flint is native, safe, and strictly typed.*

```flint
const username = env("USER");

print("Collecting processes...");

exec("ps aux")
    ~> lines()
    ~> grep(username)
    ~> join("\n")
    ~> write_file("user_procs.log");

print("Done in 0.001s.");

```

### Scenario 2: The Network Level (Killing Python)

*Python takes 150ms just to load the `requests` module. Flint downloads, parses, handles errors safely, and exits before Python even boots.*

```flint
print("Fetching data from the Cloud...");

# Native HTTP with inline Catch block for absolute resilience
const payload = fetch("https://dummyjson.com/quotes/random") catch |err| {
    print("[WARNING] Network Failure Intercepted. Reason:");
    print(err);
    exit(1);
};

# Native zero-copy JSON parsing into the Arena
const data = parse_json(payload);

print(concat("Quote: ", to_str(get(data, "quote"))));

```

## Performance: The v1.6 Benchmarks

Flint is designed to operate at the physical limits of your hardware, utilizing OS-level memory mapping (`mmap`), lazy initialization, and AVX-vectorized C string operations.

### 1. The 65MB I/O Challenge

**Task:** Read a 1,000,000-line log file (65MB) from disk, scan for the word "ERROR", and count occurrences.

| Competitor | Language Type | Mean Time |
| --- | --- | --- |
| **Bash (`grep`)** | Highly Optimized C (GNU) | ~ 17.4 ms |
| **Flint (v1.6)** | AOT Compiled (Native C) | **~ 28.1 ms** |
| **Python 3** | Interpreted VM | ~ 135.6 ms |

*Verdict:* Flint obliterates Python's throughput (5x faster) and approaches the physical memory bandwidth limits, trading blows with `grep`—a 40-year-old tool written in manual Assembly/C.

### 2. The Cold-Start Network Fetch

**Task:** Boot the runtime, establish a TLS connection, fetch a JSON payload from a remote API, parse it, and print a key.

| Competitor | Stack | Mean Time |
| --- | --- | --- |
| **Flint (v1.6)** | Native `libcurl` + Arena | **~ 164.7 ms** |
| **Bash** | `curl` + `jq` | ~ 165.5 ms |
| **Python 3** | `requests` module | ~ 324.6 ms |

*Verdict:* The "Interpreter Tax" is real. Flint matches the raw startup speed of native OS binaries, completing the entire network request and parsing cycle before Python finishes booting its HTTP libraries.

### 3. The 17MB JSON Heavy-Load Challenge
**Task:** Parse a massive JSON file containing 500,000 keys directly into memory and perform a dictionary lookup.

| Competitor | Engine / Memory Model | Mean Time | Jitter (σ) |
| --- | --- | --- | --- |
| **Flint (v1.6)** | AOT Native / 4GB Virtual Arena | **~ 85.3 ms** | **± 0.5 ms** |
| **Python 3** | CPython VM / Ref Counting | ~ 333.9 ms | ± 1.7 ms |
| **Node.js 20** | V8 Engine / Garbage Collected | ~ 822.2 ms | ± 89.9 ms |

*Verdict:* Flint's zero-copy architecture and Virtual Memory Arena completely bypass the memory fragmentation that plagues managed languages. Flint processes half a million JSON keys 4x faster than Python and nearly 10x faster than Node.js (which suffered massive GC pauses).

## Getting Started (Building from Source)

The Flint compiler is written in [Zig](https://ziglang.org). You need Zig `0.15.2` and `clang` (or `gcc`) installed on your system.

```bash
git clone https://codeberg.org/lucaas-d3v/flint.git
cd flint
zig build -Doptimize=ReleaseFast
sudo ./install.sh

```

Compile and run your first script:

```bash
flint run my_script.fl

```

*(Use `flint build my_script.fl` to generate the standalone, dependency-free binary).*

## Status: v1.6 (Zero-Copy & Elastic Memory)

Flint is not a toy, but it is currently in strict development. The v1.6 architecture established the core transpiler, zero-copy memory foundation, native OS interop, dynamic arrays, and the Zig-style error handling system.

**Upcoming Milestones (v1.7 / v2.0 Roadmap):**

* **Custom Structs:** Strict typing for deep JSON modeling.
* **Advanced Module System:** Multi-file projects and safe imports.
* **Lexical Error Reporting:** Precise compiler tracebacks pointing to the exact line/column of failure.
