# Flint Language Specification (v1.7)

This document defines the formal syntax, semantics, and data types of the Flint programming language. It serves as the single source of truth for the compiler implementation.

## 1. Core Philosophy

Flint is a statically-typed, ahead-of-time (AOT) compiled language that prioritizes zero-copy memory manipulation and linear data flow. It uses C99 as its intermediate representation (IR) and relies on a 4GB Virtual Arena allocator.

## 2. Primitive Types

Flint enforces strict typing at the boundary, but allows dynamic payloads via the `val` boxed type for I/O and JSON.

| Type | C Representation | Description |
| :--- | :--- | :--- |
| `int` | `long long` | 64-bit signed integer. |
| `bool` | `bool` | Boolean value (`true` or `false`). |
| `string` | `flint_str` | Fat pointer slice (`{ const char* ptr; size_t len; }`). Strings are immutable and zero-copy. |
| `val` | `FlintValue` | A tagged union (Box) that can hold any type, including Errors and Dictionaries. Used for dynamic data from OS/Network. |
| `arr` | `flint_array` | Dynamic array structure with `items`, `count`, and `capacity`. |
| `void` | `void` | Used strictly for function return signatures that yield no value. |

### 2.1. String Interpolation
Flint supports robust string interpolation using the `$` prefix for both standard strings and multiline strings (backticks). Expressions inside `{}` are automatically evaluated and safely boxed.

```flint
const code = 200;
const log = $"API returned status {code}";

const html = $`
<div>
    <h1>{payload["title"]}</h1>
</div>
`;
```

## 3. Variables & Mutability

Flint enforces explicit immutability by default.

```flint
const x: int = 10;   # Immutable variable (Type is explicitly declared)
var y = "Hello";     # Mutable variable (Type is inferred from the literal)

# The discard identifier ignores the return value of an expression
_ = os.rm("file.txt"); 
```

## 4. Control Flow

### 4.1. If / Else
Standard conditional branching. Parentheses around the condition are mandatory.

```flint
if (code == 0) {
    print("Success");
} else {
    exit(1);
}
```

### 4.2. For Loops
Flint supports iteration over iterables (`arr` or string lines).

```flint
for line in file_content ~> strings.lines() {
    print(line);
}
```

## 5. Functions & Externs

Functions must declare the types of their arguments and their return type. 
`extern fn` declarations are used to link Flint code directly to C functions provided by the `flint_rt.h` runtime without writing the body in Flint.

```flint
# Native C Runtime Hook
extern fn flint_file_exists(path: string) bool;

# Flint Function
fn is_ready(path: string) bool {
    return flint_file_exists(path);
}
```

## 6. The Pipeline Operator (`~>`)

The pipeline operator is the syntactic core of Flint. It passes the evaluated expression on its **left** side as the **first argument** to the function call on its **right** side.

**Syntax Rule:**
`A ~> B(C)` is transformed at AST generation into `B(A, C)`.

```flint
# Traditional nested call (Ugly)
write_file(join(grep(lines(exec("ps aux")), "root"), "\n"), "out.log");

# Flint Pipeline (Linear Data Flow)
exec("ps aux")
    ~> lines()
    ~> grep("root")
    ~> join("\n")
    ~> write_file("out.log");
```

*Restriction:* The right side of a pipeline operator `~>` **must** be a function call.

### 6.1. The Pipeline Placeholder (`_`)
By default, the pipeline operator passes the left expression as the *first* argument to the right function. If you need to route the data to a different argument, or access its properties mid-pipeline, use the `_` placeholder.

```flint
# Routing to a specific argument
const data = fetch("[https://api.dev](https://api.dev)")
    ~> parse_json(_)
    ~> ensure(_["code"] == 200, "API Failed") # Mid-pipeline validation!
    ~> print(_["data"]);
```

## 7. Error Handling (`catch`)

Flint does not have exceptions or stack unwinding. Errors are values propagated inside the `val` box. The `catch` operator intercepts `FLINT_VAL_ERROR` types inline.

```flint
# If `fetch` fails, the catch block intercepts the error value
const payload = fetch("https://api") catch |err| {
    print("Failed to fetch:");
    print(err);
    exit(1);
};
```

## 8. Operator Precedence

Operators in Flint are evaluated according to the following precedence hierarchy (from highest to lowest). This mirrors the recursive descent parsing sequence.

| Level | Operator(s) | Description | Associativity |
| :--- | :--- | :--- | :--- |
| 1 | `()` `[]` `.` | Function call, Indexing, Property access | Left-to-Right |
| 2 | `!` `-` | Unary logical NOT, Unary minus | Right-to-Left |
| 3 | `*` `/` `%` | Multiplication, Division, Module | Left-to-Right |
| 4 | `+` `-` | Addition, Subtraction | Left-to-Right |
| 5 | `<` `>` `<=` `>=` | Relational comparisons | Left-to-Right |
| 6 | `==` `!=` | Equality | Left-to-Right |
| 7 | `~>` | **Pipeline Operator** | Left-to-Right |
| 8 | `=` `catch` | Assignment, Error Interception | Right-to-Left |

### 8.1 Universal Indexing & Equality
Flint uses a universal bracket notation `[]` to access `arr`, `struct`, and dynamic JSON `val` types without explicit type casting.
Deep equality (`==`, `!=`) is safely evaluated at runtime even across different boxed types.

```flint
const user_name = json_payload["data"]["users"][0]["name"];

if (user_name == "Admin") {
    print("Welcome!");
}
```

## 9. Modules and Imports

Flint features a Canonical Module Linker.

* **Standard Library Imports:** Using `import identifier;` tells the compiler to search the `FLINT_LIB_PATH` (or local `./std/`) for the standard module.
* **Relative Imports:** Using `import "./path.fl" as alias;` links a local file.
* **Aliasing:** The Linker resolves all calls to their canonical source. Importing the same file under different aliases will map to the same C compilation unit, avoiding binary bloat.

```flint
import os;                         # Resolves to std/os.fl
import "std/strings.fl" as str;    # Resolves to std/strings.fl
```

## 10. Structs and AOT Mapping

Flint supports static data structures. Structs are compiled Ahead-Of-Time (AOT) and bypass dynamic reflection.

```flint
struct Config {
    ip: string,
    port: int,
    secure: bool
}
```
*Note:* Nested structs are currently not supported in v1.7.

When parsing JSON, the built-in `parse_json_as(StructName, payload)` generates a native C deserializer at compile-time that maps JSON keys directly to the struct's physical memory offsets.