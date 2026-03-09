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

## The Flint Architecture (v1.5)

Flint takes the expressiveness of functional data pipelines and brutally enforces it at the C-memory level. 

* **The Pipeline Operator (`~>`):** Data flows forward. No nested function hell. The result of the left expression becomes the first argument of the right function.
* **C99 Transpilation:** Flint does not reinvent the wheel. The compiler (written in Zig) transpiles your code to strict C99 and uses your host's `clang`/`gcc` to heavily optimize it.
* **Arena Allocator (Zero GC Pauses):** Memory is managed via a monolithic 128MB bump allocator. Scripts run fast, allocate continuously, and rely on the OS to reap the memory upon exit. Zero garbage collection cycles.
* **Errors as Values (Zig-Style):** No silent crashes. I/O and Network failures are intercepted via a zero-cost `catch |err|` inline block, keeping your CI/CD pipelines bulletproof without the overhead of `try/catch` stack unwinding.

## Show, Don't Tell

### Scenario 1: The OS Level (Killing Bash)
*Fragile Bash relies on external binaries and fails silently if pipes break. Flint is native and strictly typed.*

```flint
const usuario = env("USER");

print("Coletando processos...");

exec("ps aux")
    ~> lines()
    ~> grep(usuario)
    ~> join("\n")
    ~> write_file("user_procs.log");

print("Concluido em 0.001s.");

```

### Scenario 2: The Network Level (Killing Python)

*Python takes 50ms just to load the `requests` and `json` modules. Flint downloads, parses, handles errors safely, and exits in 15ms.*

```flint
print("Buscando dados na Cloud...");

# HTTP nativo com block Catch inline para resiliencia absoluta
const payload = fetch("[https://dummyjson.com/quotes/random](https://dummyjson.com/quotes/random)") catch |err| {
    print("[ALERTA] Falha de Rede Interceptada. Motivo:");
    print(err);
    exit(1); 
};

# Parseamento de JSON zero-copy nativo para a Arena (FlintDict)
const dados = parse_json(payload);

const citacao = to_str(get(dados, "quote"));
const autor = to_str(get(dados, "author"));

print(concat("Quote: ", citacao));
print(concat("By: ", autor));

```

## Advanced Primitives (v1.5)

Flint brings modern data structures to raw C performance:

* **Native HTTP & JSON:** Built-in `fetch()` backed by `libcurl` and native JSON unpacking.
* **Dynamic HashMaps:** `const config = parse_json("{}"); set(config, "key", "value");` (Equipped with dynamic load-factor rehashing).
* **Dynamic Arrays:** `const ports = [80, 443]; push(ports, 8080);`
* **Module System:** `import "utils.fl";` for scaling your scripts logically.
* **Native String Manipulation:** Zero-copy slicing, `trim()`, `split()`, and `replace()`.

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

## Status: V1.5 (Resilience & Networking)

Flint is not a toy, but it is currently in strict development. The v1.5 architecture established the core transpiler, OS interop, dynamic arrays, JSON parsing, HashMaps, and the Zig-style error handling system.

Upcoming milestones (v1.6+):

* Deep JSON unpacking (nested dictionaries).
* Custom Structs.
