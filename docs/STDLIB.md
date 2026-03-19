# Flint Standard Library Reference (v1.7)

Flint's Standard Library is written in Flint itself (`std/*.fl`) and binds directly to the zero-dependency C99 runtime (`flint_rt.c`). 

All standard modules can be imported using the canonical syntax: `import module_name;`

---

## 1. `os` (Operating System & Processes)
Functions for process orchestration, environment variables, and filesystem metadata.

* **`os.env(name: string) string`**: Returns the value of an environment variable (or an empty string if not found).
* **`os.args() arr`**: Returns an array of command-line arguments passed to the script.
* **`os.exec(cmd: string) string`**: Spawns a raw shell command and returns `stdout` as a string. Halts if `popen` fails.
* **`os.spawn(cmd: string) val`**: Safely spawns a subprocess. Returns a dictionary containing `exit_code`, `stdout`, and `stderr`.
* **`os.assert(proc: val, msg: string) val`**: Validates a dictionary returned by `os.spawn`. If the `exit_code` != 0, it halts the pipeline, prints the `msg`, dumps `stderr`, and exits.
* **`os.ls(path: string) val`**: Returns a string containing all files in a directory (separated by `\n`). Returns an error `val` if the directory does not exist.
* **`os.is_dir(path: string) bool`** / **`os.is_file(path: string) bool`**: Validates file system types.
* **`os.file_size(path: string) val`**: Returns the size of a file in bytes (as an `int` inside a `val`).
* **`os.mkdir(path: string) val`** / **`os.rm(path: string) val`**: Directory and file removal/creation. Returns an error `val` on failure.
* **`os.copy(src: string, dest: string) val`**: Performs a Kernel-space zero-copy (`sendfile()`) clone of a file.

---

## 2. `io` (Input / Output)
Functions for raw disk reading and writing.

* **`io.read_file(path: string) val`**: Uses `mmap` to read a file with zero-copy. Returns a `val` containing the string, or an error `val` if the file doesn't exist.
* **`io.write_file(text: string, path: string) val`**: Writes a string to disk. Returns a boolean `val` or an error `val` on failure.

---

## 3. `strings` (Zero-Copy Manipulation)
Text processing functions. None of these functions duplicate memory; they return fat pointers (slices) to the original Arena allocation.

* **`strings.split(text: string, delimiter: string) arr`**: Splits a string into an array of string slices.
* **`strings.lines(text: string) arr`**: Shorthand for `split(text, "\n")`.
* **`strings.join(parts: arr, sep: string) string`**: Allocates a new string combining all elements of an array.
* **`strings.trim(text: string) string`**: Removes whitespace from both ends.
* **`strings.grep(lines: arr, pattern: string) arr`**: Filters an array of strings, returning only those containing the pattern.
* **`strings.count_matches(text: string, pattern: string) int`**: Returns the number of times a pattern appears.
* **`strings.concat(a: string, b: string) string`**: Joins two strings.
* **`strings.to_str(v: val) string`** / **`strings.to_int(v: val) int`**: Extracts native types from boxed `val` envelopes.

---

## 4. `http` (Network)
* **`http.fetch(url: string) val`**: Performs an HTTP GET request using native `libcurl`. Returns the response body as a string inside a `val`, or an error `val` on failure.

---

## 5. `json` (Data Parsing)
* **`parse_json_as(StructName, payload: string) StructName`**: AOT compiler built-in. Maps a JSON string directly into a physical C struct layout. Returns the strongly-typed struct.