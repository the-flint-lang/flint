<div align="center">
<img src="assets/favicon_transparent_bg.svg" alt="Flint Logo" width="200">
</div>

# > flint

[![Flint CI](https://github.com/lucaas-d3v/flint/actions/workflows/ci.yml/badge.svg)](https://github.com/lucaas-d3v/flint/actions/workflows/ci.yml)

**A pipeline-oriented system language for robust CLI tools.** *Stop writing fragile Bash. Stop waiting for Python to boot.*

Flint is a statically-typed, ahead-of-time (AOT) compiled language designed specifically to replace complex shell scripts and slow-starting interpreted languages in DevOps and infrastructure environments. It transpiles to pure C99, yielding dependency-free native binaries that execute in milliseconds.

## The Engineering Dilemma

If you are writing infrastructure tooling, you face a miserable trilemma today:

1. **Bash is a minefield:** Silent failures, whitespace explosions, and everything-is-a-string typing make scripts unmaintainable past 50 lines.
2. **Python/Node.js are bloated:** Bootstrapping a VM/Interpreter just to parse a JSON or invoke an OS command adds unacceptable latency to fast-moving CLI workflows.
3. **Go/Rust are verbose:** General-purpose systems languages require massive boilerplate for simple I/O, regex, and process invocation.

## Inside Flint (Architecture & Contributing)

Flint is built by and for systems engineers. Before opening a Pull Request or questioning the absence of standard `malloc()`/`free()` in the C runtime, please read our internal engineering documents:

* **[Architecture & Memory Model](ARCHITECTURE.md)**: A deep dive into the Zig-to-C99 transpilation pipeline, the 4GB `mmap` Virtual Arena, and how AOT Structs bypass dynamic reflection.
* **[Contributing Guide](https://www.google.com/search?q=CONTRIBUTING.md)**: Learn how to build the compiler from source, run the `flint test` orchestrator, and adhere to our strict C99/Zig coding standards.

We welcome PRs that align with Flint's core philosophy: **zero-cost abstractions, zero runtime dependencies, and instant startup times.**

## The Flint Architecture (v1.7)

Flint takes the expressiveness of functional data pipelines and brutally enforces it at the hardware level.

* **The Pipeline Operator (`~>`):** Data flows forward. No nested function hell. The result of the left expression becomes the first argument of the right function.
* **4GB Virtual Memory Arena:** Memory is managed via a highly optimized, branchless virtual allocator using `mmap(MAP_NORESERVE)`. Scripts boot instantly, scale infinitely without `malloc` fragmentation, and bypass the Garbage Collector entirely.
* **Zero-Copy String Slices & SIMD:** The C-string `\0` terminator overhead has been eradicated. Strings are "Fat Pointers" (`ptr` + `len`), making operations like `split()` and `lines()` O(1) in memory. JSON parsing leverages vectorized `memchr` for brutal scanning speeds.
* **AOT Strongly-Typed Structs:** Define static data contracts. Flint's compiler generates native C deserializers that map JSON directly into physical memory offsets, obliterating dynamic hashmap lookups.
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

### Scenario 2: The Data Level (Killing Python & Pydantic)

*Python's dynamic nature makes JSON parsing slow and error-prone. Flint defines rigid memory structs and parses massive network payloads in microseconds, pointing exact line errors if compilation fails.*

```flint
struct GithubUser {
    login: string,
    id: int,
    hireable: bool
}

# Native HTTP with inline Catch block for absolute resilience
const payload = fetch("https://api.github.com/users/lucaas-d3v") catch |err| {
    print("Network Failure Intercepted.");
    exit(1);
};

# Zero-copy, AOT-compiled mapping from JSON to native C struct
const user = parse_json_as(GithubUser, to_str(payload));

print(concat("Developer: ", user.login));
```

## Performance: The Benchmarks

Flint is designed to operate at the physical limits of your hardware, utilizing OS-level memory mapping and bypassing runtime dynamic allocations.

### 1. The 17MB JSON Heavy-Load Challenge

**Task:** Parse a massive JSON file containing 500,000 keys directly into memory and perform a dictionary lookup.

| Competitor | Engine / Memory Model | Mean Time | Jitter (σ) |
| --- | --- | --- | --- |
| **Flint (v1.7)** | AOT Native / 4GB Virtual Arena | **~ 85.3 ms** | **± 0.5 ms** |
| **Python 3** | CPython VM / Ref Counting | ~ 333.9 ms | ± 1.7 ms |
| **Node.js 20** | V8 Engine / Garbage Collected | ~ 822.2 ms | ± 89.9 ms |

*Verdict:* Flint's zero-copy architecture completely bypasses the memory fragmentation that plagues managed languages. Flint processes half a million JSON keys 4x faster than Python and nearly 10x faster than Node.js (which suffered massive GC pauses).

### 2. The 65MB I/O Challenge

**Task:** Read a 1,000,000-line log file (65MB) from disk, scan for the word "ERROR", and count occurrences.

| Competitor | Language Type | Mean Time |
| --- | --- | --- |
| **Bash (`grep`)** | Highly Optimized C (GNU) | ~ 17.4 ms |
| **Flint** | AOT Compiled (Native C) | **~ 28.1 ms** |
| **Python 3** | Interpreted VM | ~ 135.6 ms |

*Verdict:* Flint obliterates Python's throughput (5x faster) and approaches the physical memory bandwidth limits, trading blows with `grep`—a 40-year-old tool written in manual Assembly/C.

### 3. The Cold-Start Network Fetch

**Task:** Boot the runtime, establish a TLS connection, fetch a JSON payload from a remote API, parse it, and print a key.

| Competitor | Stack | Mean Time |
| --- | --- | --- |
| **Flint** | Native `libcurl` + Arena | **~ 164.7 ms** |
| **Bash** | `curl` + `jq` | ~ 165.5 ms |
| **Python 3** | `requests` module | ~ 324.6 ms |

### 4. The Pydantic Massacre (AOT Structs vs Dynamic Reflection)

**Task:** Parse a 6MB JSON payload containing 200,000 "noise" keys, extract exactly 3 target fields into a strongly-typed struct, and print one of them.

| Competitor | Engine / Validation Model | Mean Time | Speedup |
| --- | --- | --- | --- |
| **Flint (v1.7)** | Native C / AOT Struct Mapping | **~ 58.7 ms** | **7x Faster** |
| **Python 3** | CPython / Pydantic BaseModel | ~ 405.6 ms | Baseline |

*Verdict:* Pydantic (the industry standard in Python) requires parsing the entire JSON into a dynamic dictionary of `PyObjects` before applying runtime reflection to validate fields. Flint generates native C deserializers at compile-time, slicing the `mmap` buffer directly into physical struct offsets in O(1) time.

### 5. The 5GB Zero-Copy I/O Challenge

**Task:** Copy a 1GB payload 5 times sequentially, forcing maximum disk throughput while measuring CPU overhead.

| Competitor | Engine / Syscall | Mean Time | User CPU Time |
| --- | --- | --- | --- |
| **Flint (v1.7)** | Native C / `sendfile` | **~ 129.0 s** | **0.007 s** |
| **Python 3** | `shutil` / User Space RAM | ~ 139.1 s | 0.067 s |
| **Bash (`cp`)** | GNU Coreutils | ~ 156.3 s | 0.011 s |

*Verdict:* While all languages hit the physical limits of the storage drive, Flint uses **10x less CPU time** than Python. By instructing the Linux Kernel to copy blocks directly between file descriptors, Flint leaves the machine's CPU and RAM entirely free for other concurrent tasks.

### 6. The 10,000 Metadata Massacre

**Task:** Read a directory containing 10,000 files, iterate through them, and invoke `stat` to calculate the total size.

| Competitor | Memory Model | Mean Time | Speedup |
| --- | --- | --- | --- |
| **Flint (v1.7)** | Hybrid Arena + Stack Allocation | **~ 7.1 ms** | **2.0x Faster** |
| **Bash** | Native globbing + sub-process | ~ 9.0 ms | 1.25x Faster |
| **Python 3** | Heap Objects + GC | ~ 14.6 ms | Baseline |

*Verdict:* Python suffers allocating 10,000 strings on the heap and tracking them via the Garbage Collector. Flint uses a single consolidated Arena allocation and pushes system paths directly to the stack (`O(1)` overhead), resulting in zero memory fragmentation and doubling Python's execution speed.

### 7. The Subprocess Storm (Process Orchestration)

**Task:** Spawn, execute, and capture the output of 500 external system processes (`/bin/true`) sequentially.

| Competitor | Spawning Mechanism | Mean Time |
| --- | --- | --- |
| **Bash** | Native Shell (`fork`) | **~ 399.6 ms** |
| **Flint (v1.7)** | `posix_spawn` + `popen` | ~ 519.7 ms |
| **Python 3** | `subprocess.run` | ~ 592.9 ms |

*Verdict:* Bash wins by design—it is a shell built exclusively for process invocation. However, Flint easily outpaces Python's heavyweight `subprocess` module by replacing costly `fork()` memory-cloning with lightweight `posix_spawn`, delivering robust process orchestration without the interpreter lag.

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

---

## VS Code Extension (Syntax Highlighting & Snippets)

Flint has official support for VS Code, providing native syntax highlighting for Structs, Pipelines (`~>`), and fast snippets for everyday DevOps tasks.

Since Flint is fully independent, the extension is distributed directly via this repository.

**How to install:**

1. Download the `flint-lang-1.7.1.vsix` file from the Releases page.
2. Open your terminal and run:

```bash
code --install-extension flint-lang-1.7.1.vsix
```

*(Alternatively, open VS Code, go to the Extensions tab, click the `...` menu at the top right, and select "Install from VSIX...")*

---

## Status & Roadmap

Flint is highly experimental but heavily optimized for its core use cases. The v1.7 release cemented the memory architecture, AOT Structs, DAG-based module linking, and lexical error reporting.

**Upcoming Milestones (v1.8+):**

* **Namespaces & Safe Modularity:** Introducing `import as` to prevent global scope pollution during complex deployments.
* **Streaming Data Pipelines:** Shifting from memory-centric parsing to chunk-based streaming (like `awk` or `jq`) for multi-gigabyte log processing without RAM overhead.
* **Native Concurrency:** Safe, async HTTP requests and process pooling.
* **Language Server Protocol (LSP):** Real-time error linting and autocomplete directly in the editor.