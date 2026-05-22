# TypeLisp Language Specification

> **Version:** 0.1.0-dev  
> **Target:** x86_64 Linux (System V AMD64 ABI)  
> **Constraint:** Rust `std` only — zero third-party dependencies.

This document specifies the TypeLisp language as implemented today. It is the ground truth for what compiles, what types mean, and what the backend promises.

---

## 1. Overview

TypeLisp is a statically typed Lisp/Scheme dialect that compiles to native x86_64 assembly. Every expression has a known type at compile time. There is no runtime type tagging, no garbage collector, and no interpreter.

### Compilation pipeline

```
Source (.tl)
    ↓
Lexer → Tokens
    ↓
Parser → AST
    ↓
Type Checker → Typed AST
    ↓
Lowerer → IR (3-address code, basic blocks, SSA)
    ↓
Optimizer → Constant folding, DCE, strength reduction, copy propagation
    ↓
Backend → x86_64 Assembly (.s)
    ↓
as + ld → ELF binary
```

---

## 2. Lexical structure

### 2.1 Tokens

| Token | Lexeme | Notes |
|-------|--------|-------|
| `LParen` | `(` | |
| `RParen` | `)` | |
| `LBracket` | `[` | Used in type annotations and parameter lists |
| `RBracket` | `]` | |
| `Define` | `define` | Top-level definition |
| `Lambda` | `lambda` | Anonymous function |
| `If` | `if` | Conditional |
| `Let` | `let` | Local bindings |
| `While` | `while` | Loop |
| `Begin` | `begin` | Sequence |
| `Set` | `set!` | Mutation |
| `Extern` | `extern` | External symbol declaration |
| `Ann` | `ann` | Type annotation expression |
| `Import` | `import` | Module import |
| `Int` | `[-]?[0-9]+` | Decimal integer literal, default type `i64` |
| `Float` | `[-]?[0-9]+\.[0-9]+` | `f64` literal |
| `Bool` | `true` / `false` | |
| `Char` | `#\\x` | Single character literal |
| `String` | `"..."` | ASCII string literal (type `String`) |
| `Ident` | `[a-zA-Z_][a-zA-Z0-9_!?+-=*/<>:]*` | Identifier |
| `Unit` | `unit` | The unit value |
| `Colon` | `:` | Type separator |
| `Arrow` | `->` | Function return type arrow |
| `ColonColon` | `::` | Enum variant constructor (see §5.1) |
| `Quote` | `'` | |
| `Backtick` | `` ` `` | |
| `Comma` | `,` | |
| `CommaAt` | `,@` | |
| `Dot` | `.` | |
| `Eof` | | End of file |

### 2.2 Comments

TypeLisp does **not** have comment syntax. Use semicolons at the top level or inside `begin` blocks as no-ops if needed.

### 2.3 String escapes

| Escape | Meaning |
|--------|---------|
| `\\n` | Newline (LF, `0x0A`) |
| `\\t` | Tab (`0x09`) |
| `\\\` | Backslash |
| `\\"` | Double quote |
| `\\0` | NUL (`0x00`) — **note:** collides with digit char literal `#\0` |

### 2.4 Numeric literals and type inference

Integer literals default to `i64`. They implicitly narrow to the type demanded by context (e.g., a parameter of type `i8` accepts the literal `42`). Floating-point literals are always `f64`.

---

## 3. Type system

### 3.1 Primitive types

| Type | Size | Notes |
|------|------|-------|
| `i64` | 8 bytes | Signed 64-bit integer |
| `i32` | 4 bytes | Signed 32-bit |
| `i16` | 2 bytes | Signed 16-bit |
| `i8`  | 1 byte  | Signed 8-bit |
| `u64` | 8 bytes | Unsigned 64-bit |
| `u32` | 4 bytes | Unsigned 32-bit |
| `u16` | 2 bytes | Unsigned 16-bit |
| `u8`  | 1 byte  | Unsigned 8-bit |
| `f64` | 8 bytes | IEEE-754 double precision |
| `bool`| 1 byte  | `true` (1) or `false` (0) |
| `char`| 1 byte  | Single ASCII/byte value |
| `unit`| 0 bytes | Sentinels for "no value" (similar to `void` or `()`) |

### 3.2 Aggregate types

**Tuple:** `(Tuple t1 t2 ... tn)`
- Fixed-size, heterogeneous. Layout is sequential with natural alignment per element.
- Tuples are **not** first-class values in the backend ABI today; they exist at the IR level for GEP lowering but are not passed by value.

**Fixed array:** `(Array type size)`
- Size must be a compile-time constant.
- Stored contiguously. Addressable via GEP.

**Dynamic array:** `(Array type)` — written without a size
- Runtime-sized, heap-allocated.
- Fat pointer layout: `(data_ptr : u64, length : i64)` — 16 bytes total.
- Not valid as a global initializer.

### 3.3 Function types

`(-> arg1 arg2 ... ret)`
- First-class function pointers exist in the type system.
- Direct calls are resolved at compile time; indirect calls through function pointer values use `call *%rax`.
- Closures (captured environment) are **not** supported.

### 3.4 User-defined types

#### 3.4.1 Enums (sum types)

```lisp
(defenum Name
  (Variant1 field1_type field2_type ...)
  (Variant2)
  (Variant3 single_field_type)
  ...)
```

- Each variant has a numeric **tag** (0-based index).
- Layout: `(tag : u64, payload ...)` — tag word + maximum payload size across all variants.
- Nullary variants have no payload; they occupy only the tag word.
- Pattern matching via `match` (§6.4) is exhaustive and type-checked.
- Enum values are heap-allocated when returned from functions (to avoid variable-sized stack slots).

#### 3.4.2 Structs (product types)

```lisp
(defstruct Point
  [x : i64]
  [y : i64])
```

- Layout: fields stored sequentially with natural alignment per field. No tag word.
- Constructor syntax: `(Point 10 20)` — a call-like expression.
- Field access: `(Point-x p)` — generates a GEP+load at the field's byte offset.
- Structs are heap-allocated when returned from functions (same rule as enums).
- Not valid as global variables.

### 3.5 Type aliases

There are no explicit type aliases. Identifiers naming enums or structs are resolved to their nominal types during type checking.

### 3.6 Type conversions (casts)

```lisp
(cast expr target_type)
```

- Narrowing: truncates to the target width.
- Widening: sign-extends for signed types, zero-extends for unsigned types.
- `char` → integer: zero-extends the byte value.
- Integer → `char`: truncates to low byte.
- No implicit conversions except literal narrowing.

---

## 4. Top-level forms

### 4.1 `(define name : type init)` — global variable

Declares a global variable with a constant literal initializer.

**Supported global types:** scalar integers, `bool`, `char`, `f64`, `unit`.
**Not supported:** `String`, structs, enums, arrays, dynamic arrays, function pointers.

Example:
```lisp
(define answer : i64 42)
(define pi : f64 3.14)
(define flag : bool true)
```

### 4.2 `(define (name [param : type] ...) : ret_type body)` — function

Defines a named function.

- Parameters must be explicitly typed.
- Return type must be explicitly typed.
- The entry point is a function named `main` with return type `i64` or `unit`. If `main` is missing, the compiler synthesizes one that returns 0.
- Recursion is supported.
- Varargs are **not** supported.

### 4.3 `(extern "name" : (-> args ... ret))` — external symbol

Declares an external function to link against. The string `"name"` is the raw assembly symbol; no mangling is applied. Hyphens in names are preserved as-is.

Example:
```lisp
(extern "printf" : (-> i64 i64))
```

### 4.4 `(import "path.tl")` — module import

Imports another TypeLisp file. All top-level definitions from the imported file become available.

- Relative paths are resolved from the importing file's directory.
- Circular imports are detected and rejected.
- Import paths are normalized; importing via different relative paths to the same file deduplicates.

### 4.5 `(defenum ...)` and `(defstruct ...)`

See §3.4.

---

## 5. Expressions

### 5.1 Literals

| Literal | Syntax | Type |
|---------|--------|------|
| Integer | `42`, `-7` | `i64` (contextually narrows) |
| Float | `3.14`, `-0.5` | `f64` |
| Boolean | `true`, `false` | `bool` |
| Character | `#\a`, `#\n`, `#\t`, `#\0` | `char` |
| String | `"hello"` | `String` |
| Unit | `unit` | `unit` |

### 5.2 Variables and scoping

- Global variables: visible everywhere after their definition.
- Function parameters: visible in the function body.
- `let` bindings: visible in the `let` body only.
- `set!` mutates variables in scope (locals and globals).
- Variables are looked up in order: local bindings → function parameters → globals.

### 5.3 Function calls

```lisp
(func arg1 arg2 ...)
```

- Direct calls: the callee is a known function name.
- Indirect calls: the callee is a variable/parameter of function type.
- Arguments are evaluated left-to-right.
- System V AMD64 ABI: integer args in `%rdi`, `%rsi`, `%rdx`, `%rcx`, `%r8`, `%r9`; float args in `%xmm0-%xmm7`; independent counters.
- Stack arguments (beyond register capacity) are passed on the stack.

### 5.4 Arithmetic and logical operators

All operators are prefix functions (or special forms):

| Operator | Signature | Description |
|----------|-----------|-------------|
| `+` | integer integer → integer | Addition |
| `-` | integer integer → integer | Subtraction |
| `*` | integer integer → integer | Multiplication |
| `/` | integer integer → integer | Signed division |
| `mod` | integer integer → integer | Signed remainder |
| `and` | bool bool → bool | Logical AND (short-circuit: **no** — both evaluated) |
| `or` | bool bool → bool | Logical OR (short-circuit: **no** — both evaluated) |
| `not` | bool → bool | Logical NOT |
| `bit-and` | integer integer → integer | Bitwise AND |
| `bit-or` | integer integer → integer | Bitwise OR |
| `bit-xor` | integer integer → integer | Bitwise XOR |
| `bit-not` | integer → integer | Bitwise NOT |
| `shl` | integer i64 → integer | Left shift |
| `shr` | integer i64 → integer | Right shift (arithmetic for signed, logical for unsigned) |
| `neg` | integer → integer | Unary negation |
| `+.` | f64 f64 → f64 | Float addition |
| `-.` | f64 f64 → f64 | Float subtraction |
| `*.` | f64 f64 → f64 | Float multiplication |
| `/.` | f64 f64 → f64 | Float division |
| `neg.` | f64 → f64 | Float negation |

- Integer operators propagate the operand type; i.e., `i32` + `i32` = `i32`.
- Division by zero is **undefined behavior** at runtime.

### 5.5 Comparison operators

| Operator | Signature | Description |
|----------|-----------|-------------|
| `=` | integer integer → bool | Equality |
| `!=` | integer integer → bool | Inequality |
| `<` | integer integer → bool | Less than |
| `<=` | integer integer → bool | Less than or equal |
| `>` | integer integer → bool | Greater than |
| `>=` | integer integer → bool | Greater than or equal |

- Float comparisons use the same operators; type checking disambiguates.
- String equality: `(string-eq s1 s2)` or `s1 ? s2` (alias).

### 5.6 `(if cond then else)` — conditional

- `cond` must be `bool`.
- Both branches must have the same type.
- Returns the value of the taken branch.

### 5.7 `(let ([name : type init] ...) body)` — local bindings

- Declares one or more immutable local variables.
- Variables are in scope for `body` and for subsequent bindings in the same `let` (sequential, not parallel).
- Type annotation is mandatory.

### 5.8 `(begin expr ... last_expr)` — sequence

- Evaluates expressions in order.
- Returns the value of `last_expr`.

### 5.9 `(while cond body)` — loop

- Evaluates `body` while `cond` is `true`.
- Returns `unit`.
- No `break` or `continue`.

### 5.10 `(set! var expr)` — mutation

- Mutates an existing local or global variable.
- Type of `expr` must match `var`'s type.
- Returns `unit`.

### 5.11 `(ann expr : type)` — type annotation

- Forces `expr` to have the given type.
- Useful for disambiguating literal types.

### 5.12 `(cast expr type)` — type conversion

See §3.6.

### 5.13 `(match scrutinee [(Variant pat ...) expr] ... [(Wildcard) expr])` — pattern matching

- `scrutinee` must be an enum value.
- Each arm matches one variant.
- Bindings in patterns introduce variables for payload fields.
- The `_` wildcard matches any remaining variant (used for exhaustiveness).
- All arms must return the same type.
- Enum values are heap-allocated on return from functions (see §3.4.1).

### 5.14 `(lambda ([param : type] ...) : ret_type body)` — anonymous function

- Creates a function value (pointer).
- No closure captures — all free variables must be globals.
- The lambda body cannot reference local variables from the enclosing scope.

---

## 6. Built-in functions and runtime

### 6.1 Builtin functions (lowered to IR calls)

| Builtin | Signature | Description |
|---------|-----------|-------------|
| `print` | `i64 → unit` | Print integer to stdout + newline |
| `print-bool` | `bool → unit` | Print `true`/`false` to stdout + newline |
| `print-char` | `char → unit` | Print ASCII character to stdout |
| `length` | `(Array t) → i64` | Get dynamic array length |
| `make-array` | `i64 t → (Array t)` | Allocate dynamic array of given length, fill with value |
| `array-ref` | `(Array t) i64 → t` | Read element (bounds checked) |
| `array-set!` | `(Array t) i64 t → unit` | Write element (bounds checked) |
| `string-ref` | `String i64 → char` | Read byte from string (bounds checked) |
| `string-length` | `String → i64` | Get string byte length |
| `string-eq` | `String String → bool` | Byte-wise string comparison |
| `string-to-int` | `String → i64` | Parse decimal integer from string |
| `int-to-string` | `i64 → String` | Format integer as decimal string |
| `panic` | `String → unit` | Print message to stderr and abort |

- `array-ref`, `array-set!`, and `string-ref` perform runtime bounds checks. Out-of-bounds calls the `tl_oob_abort` runtime trap (writes to stderr and exits with code 1).
- The `?` operator is an alias for `string-eq`.
- The `char-at` operator is an alias for `string-ref`.

### 6.2 Runtime functions (linked C implementation)

The compiler emits references to these runtime symbols when needed. They are implemented in C and linked against `libc`.

| Symbol | Purpose |
|--------|---------|
| `tl_print_i64` | Print integer |
| `tl_print_bool` | Print boolean |
| `tl_print_char` | Print character |
| `tl_alloc` | Allocate heap memory (`malloc` wrapper) |
| `tl_string_eq` | String comparison |
| `tl_string_to_int` | Parse integer |
| `tl_int_to_string` | Format integer |
| `tl_abort` | Print and abort (used by `panic`; NOT reentrant) |
| `tl_oob_abort` | Bounds-check trap |

### 6.3 Builtin operator aliases

| Alias | Expands to |
|-------|------------|
| `?` | `string-eq` |
| `char-at` | `string-ref` |

---

## 7. Memory model

### 7.1 Stack

- Function parameters and local variables are allocated in RBP-relative stack slots.
- Stack grows downward. Frame size is computed at compile time.
- Stack is aligned to 16 bytes at every call site (System V ABI requirement).

### 7.2 Heap

- Dynamic arrays and returned aggregates (enums, structs, strings) are heap-allocated.
- Allocation goes through `tl_alloc` (a `malloc` wrapper).
- There is **no garbage collector** or `free`. Memory is leaked on every dynamic allocation.

### 7.3 Globals

- Stored in the `.data` or `.rodata` section.
- Mutable globals use `.data` with an initializer.
- String literals are stored in `.rodata` as null-terminated bytes; the `String` value at runtime is a fat pointer `(ptr, len)` pointing into `.rodata`.

---

## 8. Backend capabilities and limitations

### 8.1 What works

- Full integer arithmetic (i64, i32, i16, i8, u64, u32, u16, u8) with correct-width instruction selection.
- `f64` arithmetic and comparisons via SSE2.
- Booleans, characters, unit.
- Control flow: `if`, `while`, `begin`.
- Direct and indirect function calls.
- Local and global variables, `let`, `set!`.
- `cast` with sign/zero extension and truncation.
- Enums with pattern matching.
- Structs with construction and field access.
- Dynamic arrays: `make-array`, `array-ref`, `array-set!`, `length`.
- Strings: literals, `string-ref`, `string-length`, `string-eq`, `string-to-int`, `int-to-string`.
- `extern` declarations.
- Multi-file modules via `import`.
- Builtin `print`, `print-bool`, `print-char`, `panic`.

### 8.2 What does NOT work (yet)

| Feature | Status |
|---------|--------|
| `f32` type | Rejected by backend validation |
| `f32` local/parameter type | Rejected by backend validation |
| Tuple by-value return | Rejected by backend validation |
| Struct/Enum/String globals | Rejected by backend validation |
| Closures (capturing lambdas) | Not implemented |
| Tail call optimization | Not implemented |
| `struct-set!` | Not implemented |
| `array-set!` on fixed arrays | Not implemented |
| Garbage collection / `free` | Not implemented (memory leaks) |
| Windows target | Not implemented |
| Source locations in error messages | Not implemented (no span tracking in diagnostics) |
| REPL | Not implemented |
| Package manager | Not implemented |
| LSP / IDE support | Not implemented |

---

## 9. Error handling

TypeLisp has one error-handling mechanism today: **panic**.

```lisp
(panic "message")
```

- Prints the message to stderr.
- Calls the runtime `tl_abort` function (which prints and exits).
- Panic is a terminal operation — it never returns normally.

There is no `Result` or `Option` type yet. Request was filed as issue #45 (research stage).

---

## 10. CLI

```
typelisp <command> [file.tl] [options]

Commands:
  tokenize    Print token stream
  parse       Print AST
  check       Run type checker
  compile     Generate assembly (.s)
  run         Compile, assemble, link, and run binary
  ir          Generate and print intermediate representation
```

---

## 11. ABI reference

### 11.1 Calling convention (System V AMD64)

| Argument index | Integer register | Float register |
|----------------|------------------|----------------|
| 1st | `%rdi` | `%xmm0` |
| 2nd | `%rsi` | `%xmm1` |
| 3rd | `%rdx` | `%xmm2` |
| 4th | `%rcx` | `%xmm3` |
| 5th | `%r8` | `%xmm4` |
| 6th | `%r9` | `%xmm5` |
| 7th+ | Stack (8-byte aligned) | Stack |

- Integer and float arguments consume **independent** register sequences.
- Return value: `%rax` (integer), `%xmm0` (float).
- Callee-saved: `%rbx`, `%rbp`, `%r12-%r15`.
- Stack aligned to 16 bytes before `call`.

### 11.2 Data layout

| Type | Size | Alignment |
|------|------|-----------|
| `i8`/`u8`/`bool`/`char` | 1 | 1 |
| `i16`/`u16` | 2 | 2 |
| `i32`/`u32` | 4 | 4 |
| `i64`/`u64`/`f64`/`String`/`DynArray`/`Enum`/`Struct`/func ptr | 8 | 8 |

- Structs: sequential layout with natural alignment per field. No padding minimization (fields are placed in declaration order).
- Enums: tag word (8 bytes) + max payload size, aligned to 8 bytes.

---

## 12. Examples

### Hello world (factorial)

```lisp
(define (factorial [n : i64]) : i64
  (if (= n 0)
      1
      (* n (factorial (- n 1)))))

(define (main) : i64
  (factorial 5))  ; returns 120
```

### Enum with match

```lisp
(defenum Color (Red i64) (Green i64) (Blue i64))

(define (color-value [c : Color]) : i64
  (match c
    [(Red v) v]
    [(Green v) (+ v 10)]
    [(Blue v) (+ v 20)]))

(define (main) : i64
  (color-value (Green 32)))  ; returns 42
```

### Struct

```lisp
(defstruct Point [x : i64] [y : i64])

(define (main) : i64
  (let ([p : Point (Point 3 4)])
    (+ (Point-x p) (Point-y p))))  ; returns 7
```

### Dynamic array

```lisp
(define (main) : i64
  (let ([arr : (Array i64) (make-array 5 0)])
    (array-set! arr 0 10)
    (array-set! arr 1 20)
    (+ (array-ref arr 0) (array-ref arr 1))))  ; returns 30
```

### String operations

```lisp
(define (main) : i64
  (let ([s : String "hello"])
    (string-length s)))  ; returns 5
```

### Extern call

```lisp
(extern "puts" : (-> i64 i64))

(define (main) : i64
  (puts "hello")
  0)
```

---

## 13. Grammar (informal)

```
program       ::= top-level*

top-level     ::= define-var
                | define-func
                | extern-decl
                | import-decl
                | defenum
                | defstruct

define-var    ::= "(" "define" ident ":" type init ")"
define-func   ::= "(" "define" "(" ident param* ")" ":" type expr ")"
extern-decl   ::= "(" "extern" string ":" type ")"
import-decl   ::= "(" "import" string ")"
defenum       ::= "(" "defenum" ident variant+ ")"
defstruct     ::= "(" "defstruct" ident field+ ")"

param         ::= "[" ident ":" type "]"
field         ::= "[" ident ":" type "]"
variant       ::= "(" ident type* ")"

expr          ::= literal
                | ident
                | "(" "if" expr expr expr ")"
                | "(" "let" "(" binding* ")" expr ")"
                | "(" "while" expr expr ")"
                | "(" "begin" expr+ ")"
                | "(" "set!" ident expr ")"
                | "(" "ann" expr ":" type ")"
                | "(" "cast" expr type ")"
                | "(" "match" expr match-arm+ ")"
                | "(" "lambda" "(" param* ")" ":" type expr ")"
                | "(" expr expr* ")"          ; function call
                | "(" ident "::" ident expr* ")"  ; enum constructor

binding       ::= "[" ident ":" type expr "]"
match-arm     ::= "(" "[" ident ident* "]" expr ")"
                | "(" "_" expr ")"

literal       ::= integer | float | bool | char | string | "unit"

type          ::= "i64" | "i32" | "i16" | "i8"
                | "u64" | "u32" | "u16" | "u8"
                | "f64" | "bool" | "char" | "unit"
                | "String"
                | "(" "Tuple" type+ ")"
                | "(" "Array" type [integer] ")"
                | "(" "->" type+ ")"
                | ident                                ; enum or struct name

ident         ::= [a-zA-Z_][a-zA-Z0-9_!?+-=*/<>:]*
integer       ::= [-]?[0-9]+
float         ::= [-]?[0-9]+\.[0-9]+
bool          ::= "true" | "false"
char          ::= "#\\" .
string        ::= \"...\"
```

---

## 14. Changelog

### 0.1.0-dev

- Initial specification covering the language as implemented.
