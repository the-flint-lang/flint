# Flint Standard Library (v1.10.0)

Parts of the stdlib are written in Flint itself (`std/*.fl`) and bind direct to the C99 runtime (`flint_rt.c`).

Import any module with:
```flint
import module_name;
```

---

## 1. `os` — Operating System

Utilities for interact with OS and process environment.

* **`os.args() arr<string>`** — Returns command-line arguments.
* **`os.is_root() bool`** — Returns true if process has root privileges.
* **`os.require_root(args: arr<string>) val`** — Re-execute current program with root when required.
* **`os.command_exists(bin: string) bool`** — Returns true if binary exists in PATH.

---

## 2. `env` — Environment Variables

* **`env.get(name: string) string`** — Returns value of environment variable.
* **`env.set(name: string, value: string) void`** — Set environment variable.
* **`env.exists(name: string) bool`** — Returns true if variable exists.

---

## 3. `process` — Process Control

Spawn and manage subprocesses.

* **`process.exec(cmd: string) string`** — Execute shell command and return stdout.
* **`process.spawn(cmd: string, echo: bool) val`** — Spawn subprocess safely. Returns dict:
```flint
{
    "exit_code": int,
    "stdout": string,
    "stderr": string
}
```

* **`process.assert(proc: val, msg: string) val`** — Validate result from `process.spawn`. If `exit_code != 0`, print error and terminate.
* **`process.exit(code: int)`** — Terminate program with exit code.

---

## 4. `fs` — Filesystem

File and directory operations.

* **`fs.file_exists(path: string) bool`**
* **`fs.is_dir(path: string) bool`**
* **`fs.is_file(path: string) bool`**
* **`fs.file_size(path: string) val`** — Returns file size in bytes.
* **`fs.ls(path: string) val`** — Returns newline-separated list of directory contents.
* **`fs.mkdir(path: string) val`**
* **`fs.rm(path: string) val`**
* **`fs.rm_dir(path: string) val`**
* **`fs.touch(path: string) val`**
* **`fs.mv(src: string, dest: string) val`**
* **`fs.copy(src: string, dest: string) val`**
* **`fs.read_file(path: string) val`**
* **`fs.write_file(text: string, path: string) val`**

---

## 5. `io` — Input / Output

Low-level I/O helpers.

* **`io.read_line(prompt: string) string`** — Read line from stdin.
* **`io.write(stream: string, msg: string)`** — Write to `"stdout"` or `"stderr"`.

---

## 6. `term` — Terminal Utilities

ANSI terminal control helpers.

Constants:

- term.RESET
- term.RED
- term.GREEN
- term.BLUE
- term.CYAN
- term.BOLD
- term.ITALIC
- term.UNDERLINED

Utilities: 
* **`term.clear()`** — Clear terminal screen.
* **`term.clear_all()`** — Clear screen and scrollback buffer.
* **`term.hide_cursor()`**
* **`term.show_cursor()`**

---

## 7. `str` — String Manipulation

* **`str.split(text: string, delimiter: string) arr<string>`**
* **`str.join(parts: arr<string>, sep: string) string`**
* **`str.trim(text: string) string`**
* **`str.count_matches(text: string, pattern: string) int`**
* **`str.replace(text: string, target: string, repl: string) string`**
* **`str.starts_with(s: string, p: string) bool`**
* **`str.ends_with(s: string, p: string) bool`**
* **`str.repeat(s: string, x: int) string`**
* **`str.to_str(v: val) string`**
* **`str.int_to_str(num: int) string`**
* **`str.to_int(v: val) int`**

---

## 8. `http` — Network

* **`http.fetch(url: string) val`** — Performs HTTP GET and returns response body.

---

## 9. `json` — JSON Parsing

* **`json.parse(text: string) val`** — Parse JSON string into dynamic Flint dict.

---

## 10. `utils` — Error Handling

* **`utils.is_err(v: val) bool`**
* **`utils.get_err(v: val) string`**

---

## 11. Built-ins (No Import Required)

Injected by the compiler. Available globally.

### 11.1 Text & Stream Processing

* **`lines(text: string) arr<string>`** — Split string by newline.
* **`chars(text: string) arr<string>`** — Iterate over string characters.
* **`grep(lines: arr<string>, pattern: string) arr<string>`** — Filter array keeping lines that contain pattern.

### 11.2 Pipeline Safety (Railway-Oriented)

* **`if_fail(val: any, msg: string) val`** — Halt pipeline if value is an error.
* **`fallback(val: any, alt: any) val`** — Replace failure with fallback value.
* **`ensure(val: any, condition: bool, msg: string) val`** — Validate condition during pipeline execution.

### 11.3 Core & Types

* **`print(val: any)`** — Print to stdout.
* **`printerr(val: any)`** — Print to stderr.
* **`len(obj: any) int`** — Return size of array, string, or dict.

### 11.4 Arrays & Iteration

* **`push(arr: arr, val: any)`** — Append element to dynamic array.
* **`range(start: int, end: int) arr<int>`** — Generate integer sequence.