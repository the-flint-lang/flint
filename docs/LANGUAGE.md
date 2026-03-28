# Flint Language Specification (v1.8.1)

This document defines the formal syntax, semantics, and data types of the Flint programming language. It serves as the single source of truth for the compiler implementation.

## 1. Core Philosophy

Flint is a statically-typed, ahead-of-time (AOT) compiled language that prioritizes zero-copy memory manipulation and linear data flow. It uses C99 as its intermediate representation (IR) and relies on a 4GB Virtual Arena allocator.

## 2. Primitive Types

Flint enforces strict typing at the boundary, but allows dynamic payloads via the `val` boxed type for I/O and JSON.

| Type | C Representation | Description |
| :--- | :--- | :--- |
| `int` | `long long` | 64-bit signed integer. |
| `bool` | `bool` | Boolean value (`true` or `false`). |
| `string` | `flint_str` | Fat pointer slice. Strings are immutable and zero-copy. |
| `val` | `FlintValue` | A tagged union (Box) that can hold any type. Used for dynamic data from OS/Network. Dictionaries require `string` keys. |
| `arr` | `flint_array` | Dynamic array. **Must be homogeneous** (all elements must share the same type). Cannot contain `void`. |
| `void` | `void` | Used strictly for function returns. Cannot be assigned to variables or stored in arrays. |

### 2.1. String Interpolation

Flint supports robust string interpolation using the `$` prefix, with full UTF-8 offset tracking for flawless error diagnostics. Under the hood, Flint uses a variadic O(1) builder (`build_str`) to assemble the string directly in the Arena without expensive temporary concatenations.

```flint
const code = 200;
const log = $"API returned status {code} with acénts!";
```

## 3. Variables & Mutability

Flint enforces explicit immutability by default.

```flint
const x: int = 10;   # Immutable variable
var y = "Hello";     # Mutable variable (Type inferred)

# The discard identifier ignores the return value
_ = os.rm("file.txt");
```

## 4. Control Flow & Error Interception

### 4.1. If / Else

Standard conditional branching. Parentheses around the condition are mandatory.

```flint
if (code == 0) {
    print("Success");
}
```

### 4.2. For Loops (Auto-Arena GC)

Every `for` loop iteration automatically acts as a memory boundary. Memory allocated inside the loop body is instantly released when the iteration finishes.

### 4.3. Error Catching (`catch`)

Flint handles native errors (like missing files) as `val` payloads. The `catch` block intercepts an error strictly for side-effects (like logging or exiting) without breaking the type flow.

```flint
const file = io.read_file("data.json") catch |err| {
    print($"Failed to read: {err}");
    os.exit(1);
};
```

## 5. The Pipeline Operator (`~>`)

The pipeline operator is the syntactic core of Flint. It passes the evaluated expression on its **left** side as the **first argument** to the function call on its **right** side. The Type Checker strictly validates injected argument types and arity.

```flint
# Flint Pipeline (Linear Data Flow)
os.exec("ps aux")
    ~> lines()
    ~> grep("root")
    ~> io.write_file(_, "out.log");
```

## 6. Operator Precedence

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

### 6.1 Universal Indexing

Flint uses a universal bracket notation `[]` to access `arr`, `struct`, and dynamic JSON `val` types. Attempting to index a primitive like `int` or `bool` is blocked at compile-time by the Type Checker to prevent C-level undefined behavior.