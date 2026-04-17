# Flint Language Reference (v1.13.0)

This is how Flint works. Types, syntax, operators, everything.

---

## 1. Core Philosophy

Flint is static typed, compiled ahead-of-time (AOT). 
It prioritizes zero-copy memory and linear data flow.
Compiles to C99 and uses a 4GB Virtual Arena allocator.

---

## 2. Primitive Types

Flint is strict with types. But allow dynamic payloads with `val`
for I/O and JSON.

| Type | C Representation | Description |
| :--- | :--- | :--- |
| `int` | `long long` | 64-bit signed integer. |
| `float` | `uint64_t` | 64-bit signed float. |
| `bool` | `bool` | Boolean (`true` or `false`). |
| `string` | `flint_str` | Fat pointer slice. Immutable and zero-copy. |
| `val` | `FlintValue` | Tagged union (Box) that hold any type. Used for dynamic data from OS/Network. Dict require `string` keys. |
| `arr` | `flint_array` | Dynamic array. **Must be homogeneous** (all elements same type). |
| `void` | `void` | Only for function returns. Can't assign to variable or store in array. |

> The arr type is generic, it he has some representations like (`arr<string>`, `arr<int>`, `arr<bool>`, `arr<float>`, etc.)

### 2.1. String Interpolation

Use `$` prefix. Full UTF-8 offset tracking for correct error diagnostics.
Under the hood, Flint uses a variadic O(1) builder (`build_str`) that
assemble the string direct in the Arena, without expensive temp concatenations.

```flint
const code = 200;
const log = $"API returned status {code} with acénts!";
```

---

## 3. Variables & Mutability

Immutable by default.

```flint
import fs;

const X: int = 10;   # Immutable
var y = "Hello";     # Mutable (type inferred)

# Discard identifier, ignore return value
_ = fs.rm("file.txt");
```

---

## 4. Control Flow & Error Interception

### 4.1. If / Else

The parentheses around the condition are not mandatory.

```flint
if (code == 0) {
    print("Success");
}

# or

if code == 0 {
    print("Success, but without parentheses.");
}
```

### 4.2. Stream Statement (Auto-Arena GC)


Each iteration is a memory boundary — arena resets automatic when iteration finish.
Made for process large data without blow up memory.

Example:

```flint
import fs;
import str;

stream file in fs.ls(FILES_DIRECTORY_HERE) ~> lines() {
    file ~> fs.read_file()
        ~> lines()
        ~> grep("ERROR")
        ~> str.join("\n")
        ~> fs.write_file("error_log.txt");
}
```

> Process gigabytes of text without blowing up memory

- auto arena reset per iteration
- optimized for large data process
- pipeline ideal

### 4.3. Error Catching (`catch`)

Flint handle native errors (like missing files) as `val` payloads.
`catch` block intercept the error for side-effects (log, exit) without
break the type flow.

```flint
const file = io.read_file("data.json") catch |err| {
    print($"Failed to read: {err}");
    os.exit(1);
};
```

You can also use the built-in `if_fail`, which basically checks if the first parameter resulted in an error. If so, it stops the script execution and prints the message; otherwise, it propagates the value.

Example:

```flint
import fs;

const file = fs.read_file("data.json") ~> if_fail("Failed to read data.json");
```

> This shows the error automatically.

Like:

```
ERROR: Pipeline Expectation Failed
  --> ~> if_fail()
   |
   | Message: Failed to read data.json
   | System : No such file or directory
   |
```

---

## 5. The Pipeline Operator (`~>`)

This is the core of Flint.
Pass the left expression as the **first argument** to the right function.
Type Checker strictly validates injected argument types and arity.

```flint
import process;
import fs;
import str;

process.exec("ps aux")
    ~> lines()
    ~> grep("root")
    ~> str.join("\n")
    ~> fs.write_file("out.log");
```

---

## 6. Operator Precedence

| Level | Operator(s) | Description | Associativity |
| :--- | :--- | :--- | :--- |
| 1 | `()` `[]` `.` | Function call, Indexing, Property access | Left-to-Right |
| 2 | `!` `-` | Unary NOT, Unary minus | Right-to-Left |
| 3 | `*` `/` `%` | Multiplication, Division, Modulo | Left-to-Right |
| 4 | `+` `-` | Addition, Subtraction | Left-to-Right |
| 5 | `<` `>` `<=` `>=` | Relational | Left-to-Right |
| 6 | `==` `!=` | Equality | Left-to-Right |
| 7 | `~>` | **Pipeline** | Left-to-Right |
| 8 | `=` `catch` | Assignment, Error Interception | Right-to-Left |

### 6.1 Universal Indexing

`[]` works for `arr`, `struct`, `string` and dynamic JSON `val`.
Index a primitive like `int` or `bool` is blocked at compile-time.

```flint
const item = my_arr[0];
const name = json_data["user"]["name"];

# slices
my_string[0..];
my_string[..5];
my_string[3..];
```