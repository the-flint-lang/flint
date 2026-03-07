<div align="center">
    <img src="assets/favicon_transparent_bg.png" alt="Texto Alternativo" width="100">
</div>

# > flint

**A compiled, pipeline-oriented language for robust CLI tools.**

Flint replaces fragile shell scripts and slow-starting interpreted languages (Python/Node) with small, dependency-free native binaries. It is built for developers who need to process text, chain commands, and build reliable infrastructure tooling without the friction of C or Rust.

## The Problem It Solves

* **Bash is fragile:** Whitespace errors, silent failures, and string-typing make complex scripts a maintenance nightmare.
* **General-purpose languages are heavy:** Bootstrapping a Python or Node.js environment for a simple text-processing CLI adds unacceptable latency (startup time).
* **Verbose pipelines:** Chaining operations in traditional compiled languages requires excessive boilerplate.

## The Solution: Native Pipelines

Flint introduces a first-class pipeline operator (`~>`) that passes the result of the left expression as the first argument to the right function. 

**Example: Parsing an error log**
```flint
# filter_logs.fl

fn main() void {
    const log_file = args()[1];

    if not file_exists(log_file) {
        print("Error: Provide a valid log file.");
        exit(1);
    }

    read_file(log_file)
        ~> lines()
        ~> grep("ERROR")
        ~> join("\n")
        ~> write_file("errors_only.log");

}
```

Compile it to a fast, standalone binary:

```bash
flint build filter_logs.fl -o filter_logs ./filter_logs /var/log/syslog
```

## Core Philosophy (v1)

1. **Ahead-of-Time (AOT) Compilation:** Flint transpiles to C99 and uses your system's `clang` or `gcc` to generate highly optimized, static binaries.
2. **Fail-Fast I/O:** No complex `try/catch` or monads in v1. If a standard library I/O operation fails without prior validation, the runtime panics cleanly and exits.
3. **Static Typing with Inference:** Types (`int`, `string`, `bool`, `list<T>`) are checked at compile time. Use `const` and `var` without verbosity.
4. **Zero Garbage Collection:** Memory is managed via a minimal arena/bump allocator tailored for short-lived CLI executions.

## Getting Started (Building from Source)

The Flint compiler is written in Zig. To build the compiler itself:

```bash
git clone https://codeberg.org/lucaas-d3v/flint.git
cd flint
zig build -Doptimize=ReleaseFast
```

*Note: Flint requires `clang` or `gcc` installed on the host system to compile `.fl` files into final executables.*

## Status: Pre-Alpha (v1 Roadmap)

Flint is currently in early development. The v1 scope is strictly locked to:

* [ ] Lexer & AST parser (In progress)
* [ ] C transpiler backend
* [ ] Core standard library (`args`, `read_file`, `lines`, `grep`)
* [ ] Linux (POSIX) support only

Contributions are welcome, but please read the [Architecture Guidelines](https://www.google.com/search?q=link) before proposing major syntax changes.
