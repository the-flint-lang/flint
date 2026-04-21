# Flint Language Support for VS Code

Official syntax highlighting, snippets, and language support for the **Flint** programming language (v1.14.0).

Flint is a high-performance, AOT-compiled language for DevOps, CLI tooling, and infrastructure automation — with zero-copy memory architecture and a pipeline-oriented syntax. This extension provides the essential Developer Experience (DX) to write Flint code efficiently in VS Code.

## Features

* **Syntax Highlighting:** Full coverage for Flint's keywords (`fn`, `struct`, `import`, `stream`, `catch`), primitive types (`int`, `float`, `string`, `bool`, `val`, `arr`), control flow, and comments.
* **Pipeline Operator (`~>`):** Dedicated highlighting for Flint's core data-flow operator and safety primitives (`if_fail`, `fallback`, `ensure`).
* **String Support:** Standard strings (`" "`), string interpolation (`$" "`), and multiline template strings (`` $` ` ``).
* **Standard Library Recognition:** Highlights namespaced calls from `fs`, `os`, `process`, `str`, `http`, `json`, `term`, `io`, and `utils`, as well as all global built-ins (`print`, `printerr`, `lines`, `grep`, `chars`, `len`, `push`, `range`).
* **Code Folding:** Automatic folding of `{}` blocks.
* **File Icon Theme:** Custom `.fl` file icon, selectable via **File Icon Theme** in VS Code settings.

## Snippets

| Trigger | Description |
| :--- | :--- |
| `import` | Imports a stdlib module (`fs`, `os`, `process`, `str`, etc.) |
| `struct` | Declares a strongly typed `struct` |
| `fn` | Declares a typed function |
| `if` | `if / else` block |
| `stream_ls` | `stream` loop over directory files with auto-arena GC |
| `stream_json` | High-performance streaming JSON iteration |
| `fetch` | HTTP pipeline with `http.fetch` + `json.parse` + `if_fail` |
| `json_parse` | Safely reads and parses a JSON file |
| `read_fail` | Reads a file and stops the pipeline on error with `if_fail` |
| `spawn` | Spawns a subprocess with `process.spawn` + `process.assert` |
| `fallback` | Pipeline with a fallback value |
| `ls` | Lists a directory and iterates over files |
| `interp` | Interpolated string with `$"..."` |
| `tmpl` | Multiline template string with `` $`...` `` |
| `sleep` | Pauses execution with `time.sleep` |
| `time_fmt` | Formats current time |
| `choice` | Picks a random element from an array with `rand.choice` |

## Installation

### Option 1: Command Line (Recommended)

1. Download the latest `flint-lang-1.14.0.vsix` from the [Releases page](https://github.com/the-flint-lang/flint/releases).
2. Run:
   ```bash
   code --install-extension flint-lang-1.14.0.vsix
   ```

### Option 2: VS Code GUI

1. Download the `.vsix` file.
2. Open the **Extensions** tab (`Ctrl+Shift+X`).
3. Click the `...` menu (top right of the pane) → **"Install from VSIX..."**.
4. Select the downloaded file.

## Issues & Contributions

Found a syntax edge-case or want to add a snippet?  
Open an issue or PR at: [github.com/the-flint-lang/flint](https://github.com/the-flint-lang/flint)

---

*Built for engineers who care about CPU cycles and memory layout.*