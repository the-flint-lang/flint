<div align="center">
  <img src="assets/favicon_transparent_bg.svg" alt="Flint Logo" width="120">
  <br>
  <a href="https://github.com/lucaas-d3v/flint/actions/workflows/ci.yml">
    <img src="https://github.com/lucaas-d3v/flint/actions/workflows/ci.yml/badge.svg" alt="Flint CI">
  </a>
</div>

##  Flint

A fast and pipeline oriented, for fast and trustworthy CI/CD automation and CLI.

* Stop fight with extreme case of bash.
* Stop pay initialization cust for simple scripts

> Flint is a static typed language,  ahead-of-time compiled (AOT), projected for sistem scripts, automation and data pipelines, it compiles to dependency-free native binaries with near-instant startup time.

---

## Why Flint?

When writing infrastructure scripts today, you generally choose between:

* Bash, simple, but fragile and hard to maintain
* Python / Node, flexible, but slow to init and heavy in execution time (runtime)
* Go / Rust, powerful but verbose for small tasks

Flint is in middle:

> Simple like script. Fast like binary. But insurance for both.

---

## Developer Experience (DX)

Write languages that transpile to C, generally means deal with horrible error of C compiler. Flint protects you from that with a strict type checker and diagnostic engine custom dense and sensitive to the context: 

```
[SEMANTIC ERROR][E0308]: Mismatched types in array

~~> teste.fl:1
   |
 1 | const mutant: arr = [1, "two", true];
   |                       ^  ^~~~~
   |                       |  |
   |                       |  found `string`
   |                       |
   |                       type inferred as `int` here
   |

note: arrays in Flint must contain elements of the same type
```

Flint uses "poison types" for smart error recovery, means he shows all errors in unique pass without false positives cascade.

---

## Performance Of  Indrustial

Flint v1.13.0 is projected using data oriented design (DoD).
When using arrays of memory continuous and pool of strings
centered, the compiler frontend operates in cache limits of modern CPUs.


* Initialization near zero: flint run execute with ~10ms of init, exceeding for both python and node.
* Memory Security: A custom strict type checker protect you from C complexity while keep zero overload in runtime.

---

## 30 seconds example

```flint
import env;

const USER = env.get("USER") ~> fallback("Stranger");
print($"Hello, {USER}!");
```

Run instantly:

> flint run hello.fl

Or compile to native binary:

> flint build hello.fl


---

## When to use Flint

Flint works better for:

* CLI tools and automation scripts
* DevOps workflows and CI/CD pipelines
* Data process (logs, JSON, etc)

---

## Central ideas

### Pipelines oriented syntax

```flint
process.exec("ps aux")
    ~> lines()
    ~> grep("root)
    ~> str.join("\n")
```

> Linear and readable data flux - without nested call

### Native performance

* Without interpreter
* Without VM

> Flint compile to C99 and produces small binaries


## Benchmarks (Summary)

Flint is engineered for maximum throughput in DevOps workloads:

* JSON Extraction: ~29x faster than Node.js and ~22x faster than Python (parses 17MB in ~13ms using O(1) Lazy Scanning).
Mass File Stat: ~650x faster than Bash when inspecting 10,000 files.

* File Cloning: Outperforms GNU cp on cold-cache huge files using Kernel-Space sendfile.

> See [./benchmarks/](./benchmarks/) for full details and reproducible tests.

## Getting Started

### Installing on Debian/Ubuntu (APT Repository - Recommended)

The easiest and recommended way to install Flint on Debian/Ubuntu-based distributions is through our official APT repository.

```bash
# 1. Add the Flint repository
echo "deb [trusted=yes] https://the-flint-lang.github.io/flint ./" | sudo tee /etc/apt/sources.list.d/flint.list

# 2. Update and install
sudo apt update
sudo apt install flint
```

### Installing from [`install.sh`](install.sh)

Requeriments:

* Clang, GCC or TCC
* libcurl & libtcc (Dev headers)

run this:

```bash
curl -fsSL https://raw.githubusercontent.com/the-flint-lang/flint/main/install.sh | bash
``` 

> The [`install.sh`](install.sh) try install requeriments with apt, pacman and dnf, if you don't have it, install this at your own risk.

### Building from source

Requeriments:

* Zig (0.16.0)
* Clang, GCC or TCC
* libcurl & libtcc (Dev headers)

Run this:

```bash
git clone https://github.com/the-flint-lang/flint
cd flint
chmod +x ignite.sh 
./ignite.sh
```

---

## Philosophy

Build tools that are simple to use, predictable to execute, and fast enough to disappear.

---

## Ecosystem

Flint is growing and new tools are being built with it.

You can explore community projects here:

~> **https://github.com/the-flint-lang/awesome-flint**

If you build something with Flint, consider adding the badge below to your README.

### Built with Flint

```md
[![Built with Flint](https://img.shields.io/badge/Built%20with-Flint-orange)](https://github.com/lucaas-d3v/awesome-flint)
```

Which renders as:

[![Built with Flint](https://img.shields.io/badge/Built%20with-Flint-orange)](https://github.com/lucaas-d3v/awesome-flint)

This helps other developers discover the Flint ecosystem.

---

## Star History

<a href="https://www.star-history.com/?repos=thezaplang%2Fzap&type=date&legend=top-left">
 <picture>
   <source media="(prefers-color-scheme: dark)" srcset="https://api.star-history.com/image?repos=lucaas-d3v/flint&type=date&theme=dark&legend=top-left" />
   <source media="(prefers-color-scheme: light)" srcset="https://api.star-history.com/image?repos=the-flint-lang/flint&type=date&legend=top-left" />
   <img alt="Star History Chart" src="https://api.star-history.com/image?repos=the-flint-lang/flint&type=date&legend=top-left" />
 </picture>
</a>
