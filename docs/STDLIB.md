# Flint Standard Library Reference (v1.9.0)

Flint's Standard Library is written in Flint itself (`std/*.fl`) and binds directly to the zero-dependency C99 runtime (`flint_rt.c`). 

All standard modules can be imported using the canonical syntax: `import module_name;`

---

## 1. `os` (Operating System & Processes)
Functions for process orchestration, environment variables, and filesystem metadata.

* **`os.env(name: string) string`**: Returns the value of an environment variable.
* **`os.args() arr`**: Returns an array of command-line arguments.
* **`os.exec(cmd: string) string`**: Spawns a raw shell command and returns `stdout`.
* **`os.spawn(cmd: string) val`**: Safely spawns a subprocess. Returns a dict containing `exit_code`, `stdout`, and `stderr`.
* **`os.assert(proc: val, msg: string) val`**: Validates a dictionary returned by `os.spawn`. If `exit_code` != 0, halts pipeline and prints `stderr`.
* **`os.ls(path: string) val`**: Returns a string containing all files in a directory.
* **`os.is_tty() bool`**: Return true if is a tty.
* **`os.is_dir(path: string) bool`** / **`os.is_file(path: string) bool`**: Validates file system types.
* **`os.file_size(path: string) val`**: Returns the size of a file in bytes.
* **`os.mkdir(path: string) val`** / **`os.rm(path: string) val`**: Directory and file removal/creation.
* **`os.copy(src: string, dest: string) val`**: Performs a Kernel-space zero-copy (`sendfile()`) clone of a file.

---

## 2. `io` (Input / Output)
Functions for raw disk reading and writing.

* **`io.read_line() string`**: Read a input with absolute zero-copy.
* **`io.read_file(path: string) val`**: Uses pure `mmap` to read a file with absolute zero-copy.
* **`io.write_file(text: string, path: string) val`**: Writes a string to disk.

---

## 3. `str` (Zero-Copy Manipulation)
Text processing functions. They return fat pointers (slices) to the original Arena allocation.

* **`str.split(text: string, delimiter: string) arr`**: Splits a string into an array of string slices.
* **`str.join(parts: arr, sep: string) string`**: Allocates a new string combining all elements of an array.
* **`str.trim(text: string) string`**: Removes whitespace from both ends.
* **`str.count_matches(text: string, pattern: string) int`**: Returns the number of times a pattern appears.
* **`str.starts_with(s: string, p: string) bool`**: Returns if a string `s` starts with `p`.
* **`str.ends_with(s: string, p: string) bool`**: Returns if a string `s` ends with `p`.

---

## 4. `http` (Network)
* **`http.fetch(url: string) val`**: Performs an HTTP GET request using native `libcurl`.

---

## 5. `json` (Data Parsing)
* **`parse_json_as(StructName, payload: string) StructName`**: AOT compiler built-in. Maps a JSON string directly into a physical C struct layout.

---

## 6. Built-ins (Global Functions)

These functions are natively injected by the Flint compiler. They are globally available and do not require any `import` statement. They form the core of Flint's O(1) processing pipeline.

### 6.1. Text & Stream Processing
* **`lines(text: string) arr`**: O(1) Shorthand for splitting text by `\n`.
* **`chars(text: string) arr`**: Zero-copy iterator over a string. Returns an array of 1-byte string slices without allocating new memory.
* **`grep(lines: arr, pattern: string) arr`**: Fast-filters an array of str, returning only those containing the pattern.

### 6.2. Pipeline Safety (Railway-Oriented)
* **`if_fail(val: any, err_msg: string) val`**: Halts the pipeline if `val` is an error. Prints stack trace and exits.
* **`fallback(val: any, alt_val: any) val`**: Intercepts a failure and silently replaces it with `alt_val`.
* **`ensure(val: any, condition: bool, err_msg: string) val`**: A mid-pipeline verifier. If false, ejects a `FLINT_VAL_ERROR`.

### 6.3. JSON & Data Parsing
* **`parse_json(payload: string) val`**: Parses a raw JSON string using O(1) Lazy Scanning without allocating dictionaries in RAM.

### 6.4. Core & Types
* **`print(val: any)`**: Prints any native type or boxed `val` to stdout.
* **`printerr(val: any)`**: Prints any native type or boxed `val` to stderr.
* **`len(obj: any) int`**: Returns the size of an array, string, or dictionary.
* **`to_str(val: any) string`**: Safely extracts or converts a boxed value into a native string slice (replaces `int_to_str` through bare-metal fast-itoa).
* **`to_int(val: any) int`**: Safely extracts or converts a boxed value into a native integer.

### 6.5. Arrays & Iteration
* **`push(array: arr, val: any)`**: Appends an element to the end of a dynamic array.
* **`range(start: int, end: int) array`**: Generates an iterable sequence of integers.