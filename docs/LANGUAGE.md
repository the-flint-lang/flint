# Flint Language Specification (v1.7.5)

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
Flint supports robust string interpolation using the `$` prefix. Under the hood, Flint uses a variadic O(1) builder (`build_str`) to assemble the string directly in the Arena without expensive temporary concatenations.

```flint
const code = 200;
const log = $"API returned status {code}";
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

### 4.2. For Loops (Auto-Arena GC)
Flint supports iteration over iterables (`arr` or string `lines()`).
**Crucial Concept:** Every `for` loop iteration automatically acts as a memory boundary. Memory allocated inside the loop body is instantly released when the iteration finishes, meaning you can iterate over infinite streams without leaking RAM.

```flint
for line in lines(file_content) {
    print(line); # Memory used here is recycled on the next loop tick
}
```

## 6. The Pipeline Operator (`~>`)

The pipeline operator is the syntactic core of Flint. It passes the evaluated expression on its **left** side as the **first argument** to the function call on its **right** side.

```flint
# Flint Pipeline (Linear Data Flow)
exec("ps aux")
    ~> lines()
    ~> grep("root")
    ~> write_file(_, "out.log");
```

## 8. Operator Precedence

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
Flint uses a universal bracket notation `[]` to access `arr`, `struct`, and dynamic JSON `val` types without explicit type casting. Thanks to **Compile-Time Hashing**, static dictionary lookups happen in O(1) time without runtime string hashing.
