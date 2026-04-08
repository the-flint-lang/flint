# Flint Language Support for VS Code

Official syntax highlighting, snippets, and language support for the **Flint** programming language (v1.10.0).

Flint is a high-performance, AOT-compiled language for DevOps, CLI tooling, and infrastructure automation — with zero-copy memory architecture and a pipeline-oriented syntax. This extension provides the essential Developer Experience (DX) to write Flint code efficiently in VS Code.

## Features

* **Syntax Highlighting:** Full coverage for Flint's keywords (`fn`, `struct`, `import`, `stream`, `catch`), primitive types (`int`, `float`, `string`, `bool`, `val`, `arr`), control flow, and comments.
* **Pipeline Operator (`~>`):** Dedicated highlighting for Flint's core data-flow operator and safety primitives (`if_fail`, `fallback`, `ensure`).
* **String Support:** Standard strings (`" "`), string interpolation (`$" "`), and multiline template strings (`` $` ` ``).
* **Standard Library Recognition:** Highlights namespaced calls from `fs`, `os`, `process`, `str`, `http`, `json`, `term`, `io`, and `utils`, as well as all global built-ins (`print`, `printerr`, `lines`, `grep`, `chars`, `len`, `push`, `range`).
* **File Icon Theme:** Custom `.fl` file icon, selectable via **File Icon Theme** in VS Code settings.

## Snippets

| Trigger | Description |
| :--- | :--- |
| `import` | Importa um módulo da stdlib (`fs`, `os`, `process`, `str`, etc.) |
| `struct` | Declara um `struct` com tipagem forte |
| `fn` | Declara uma função tipada |
| `if` | Bloco `if / else` |
| `stream` | Loop `stream` com auto-arena GC para grandes volumes de dados |
| `fetch` | Pipeline HTTP com `http.fetch` + `json.parse` + `if_fail` |
| `json` | Lê e faz parse de um arquivo JSON com segurança |
| `read_catch` | Lê arquivo com tratamento de erro via `catch` |
| `read_fail` | Lê arquivo e para o pipeline com `if_fail` |
| `spawn` | Spawna subprocesso com `process.spawn` + `process.assert` |
| `fallback` | Pipeline com valor de fallback |
| `ls` | Lista diretório e itera sobre arquivos |
| `interp` | String interpolada com `$"..."` |
| `tmpl` | Template string multiline com `` $`...` `` |

## Installation

### Option 1: Command Line (Recommended)

1. Download the latest `flint-lang-1.10.0.vsix` from the [Releases page](https://github.com/lucaas-d3v/flint/releases).
2. Run:
   ```bash
   code --install-extension flint-lang-1.10.0.vsix
   ```

### Option 2: VS Code GUI

1. Download the `.vsix` file.
2. Open the **Extensions** tab (`Ctrl+Shift+X`).
3. Click the `...` menu (top right of the pane) → **"Install from VSIX..."**.
4. Selecione o arquivo baixado.

## Issues & Contributions

Found a syntax edge-case or want to add a snippet?  
Open an issue or PR at: [github.com/lucaas-d3v/flint](https://github.com/lucaas-d3v/flint)

---

*Built for engineers who care about CPU cycles and memory layout.*