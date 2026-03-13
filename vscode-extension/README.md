# Flint Language Support for VS Code

Official syntax highlighting, snippets, and language support for the **Flint** programming language (v1.7+). 

Flint is a high-performance, AOT-compiled systems and infrastructure language with zero-copy memory architecture. This extension provides the essential Developer Experience (DX) required to write Flint code efficiently, tailored for its custom Structs, pipelines, and standard library.

## Features

This extension turns VS Code into a first-class IDE for Flint:

* **Native Syntax Highlighting:** Perfect parsing for Flint's keywords (`fn`, `struct`, `import`, `catch`), data types, and control flow structures.
* **Pipeline Operator Support:** Deep integration for Flint's signature data-flow operator (`~>`), ensuring clean visual separation of chained functions.
* **AOT Structs & Typings:** Highlights custom strongly-typed data structures and type annotations (`string`, `int`, `bool`).
* **Standard Library Recognition:** Autocompletion and highlighting for Flint's ultra-fast C99 runtime built-ins (e.g., `fetch`, `parse_json_as`, `exec`, `lines`, `grep`, `count_matches`).
* **String Parsing:** Full support for standard strings (`" "`), char literals (`' '`), and raw multiline strings (`` ` ` ``).

## Built-in Snippets

Stop writing boilerplate. Use these triggers to generate Flint's core structures instantly:

| Trigger | Description | Output |
| :--- | :--- | :--- |
| `struct` | Define a custom data contract | Scaffolds a strongly-typed `struct { ... }` block. |
| `fetch` | HTTP Request with Fallback | Generates a `fetch(url) catch |err| { ... }` block. |
| `parse` | AOT JSON Parsing | Inserts `parse_json_as(StructName, payload)`. |
| `read` | Zero-Copy File Reading | Scaffolds `read_file(path) ~> lines()`. |
| `exec` | OS Command Pipeline | Generates an `exec("cmd") ~> grep() ~> print()` flow. |

## Manual Installation

As an independent, hardcore open-source project, Flint bypasses the corporate telemetry and credit-card walls of the official MS Marketplace. 

You can install this extension locally in 10 seconds:

**Option 1: Command Line (Recommended)**
1. Download the latest `flint-lang-X.X.X.vsix` from the [Releases page](https://github.com/lucaas-d3v/flint/releases).
2. Open your terminal and run:
   ```bash
   code --install-extension flint-lang-1.7.1.vsix
    ```

**Option 2: GUI**

1. Download the `.vsix` file.
2. Open VS Code and navigate to the **Extensions** tab (`Ctrl+Shift+X`).
3. Click the `...` (Views and More Actions) menu at the top right of the extensions pane.
4. Select **"Install from VSIX..."** and choose the downloaded file.

## Issues & Contributions

Found a syntax edge-case or want to add a new snippet?
Open an issue or submit a PR at the official repository: [github.com/lucaas-d3v/flint](https://www.google.com/search?q=https://github.com/lucaas-d3v/flint).

---

*Built for engineers who care about CPU cycles and memory layout.*
