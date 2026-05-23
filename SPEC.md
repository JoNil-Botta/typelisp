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
Optimizer → Constant folding, basic-block CSE, DCE, strength reduction, copy propagation
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
| `Char` | `#x'` / `#\\x'` | Single character literal |
| `String` | `"..."` | ASCII string literal (type `String`) |
| `Ident` | `[a-zA-Z_][a-zA-Z0-9_!?+-=*/<>:]*` | Identifier |
| `Unit` | `unit` | The unit value |
| `Colon` | `:` | Type separator |
| `Arrow` | `->` | Function return type arrow |
| `Quote` | `'` | |
| `Backtick` | `` ` `` | |
| `Comma` | `,` | |
| `CommaAt` | `,@` | |
| `Dot` | `.` | |
| `Eof` | | End of file |

### 2.2 Comments

Semicolon starts a line comment. The lexer skips everything from `;` through
the next newline. Double semicolons are just two semicolon characters; the first
one starts the comment.

### 2.3 String escapes

| Escape | Meaning |
|--------|---------|
| `\\n` | Newline (LF, `0x0A`) |
| `\\t` | Tab (`0x09`) |
| `\\r` | Carriage return (`0x0D`) |
| `\\\` | Backslash |
| `\\"` | Double quote |

Other escaped characters are accepted literally by the lexer today. For
example, `\0` in a string is the character `0`, not a NUL byte.

### 2.4 Numeric literals and type inference

Integer literals have type `i64`. Use `(cast expr : target_type)` when a
narrower or unsigned integer is required. Floating-point literals are always
`f64`.

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
| `f32` | 4 bytes | Parsed/typechecked in some positions, rejected by backend validation |
| `bool`| 1 byte  | `true` (1) or `false` (0) |
| `char`| 1 byte  | Single ASCII/byte value |
| `unit`| 0 bytes | Sentinels for "no value" (similar to `void` or `()`) |

### 3.2 Aggregate types

**Tuple:** `(Tuple t1 t2 ... tn)`
- Fixed-size, heterogeneous. Layout is sequential with natural alignment per element.
- Tuple literals lower to pointer values over inline element storage, and
  `tuple-ref` reads tuple values in local/expression positions.
- Tuple function parameters and by-value returns are not first-class values in
  the backend ABI today.

**Fixed array:** `(Array type size)`
- Size must be a compile-time constant.
- Fixed-array literals lower to inline element storage. Values are passed around
  by pointer handle inside compiled code.
- `array-ref` and `array-set!` on fixed arrays are bounds-checked and use the
  compile-time length. By-value fixed-array returns are still rejected by backend
  validation.

**Dynamic array:** `(Array type)` - written without a size
- Runtime-sized element buffer allocated with `tl_alloc`.
- `make-array` rejects negative lengths and traps if `length * sizeof(type)`
  would overflow an `i64` byte count before calling `tl_alloc`.
- A dynamic-array value is a pointer to inline fat storage
  `(data_ptr : u64, length : i64)` - 16 bytes total.
- The stored `length` field is always non-negative.
- Not valid as a global initializer.

### 3.3 Function types

`(-> arg1 arg2 ... ret)`
- Function pointers exist in the type system and ABI.
- Direct calls are resolved at compile time; indirect calls through function pointer values use `call *%rax`.
- Lambda expressions parse and type-check for scalar returns, but backend
  lowering for lambda literals is incomplete. Closures (captured environment)
  are not supported.

### 3.4 User-defined types

#### 3.4.1 Enums (sum types)

```lisp test=ignore name=enum-template reason=template
(defenum Name
  (Variant1 field1_type field2_type ...)
  (Variant2)
  (Variant3 single_field_type)
  ...)
```

- Each variant has a numeric **tag** (0-based index).
- Layout: `(tag : u64, payload ...)` — tag word + maximum payload size across all variants.
- Nullary variants have no payload; they occupy only the tag word.
- Variant constructor and pattern names are global, unqualified value names.
  Reusing the same variant name in another enum is rejected.
- Pattern matching via `match` (§5.13) is exhaustive and type-checked.
- Enum values are heap-allocated when returned from functions (to avoid variable-sized stack slots).
- Module-qualified or enum-qualified variant names are future work; write `Red`
  or `(Some x)` today, not `Color.Red` or `Color::Red`.

#### 3.4.2 Structs (product types)

```lisp test=check name=struct-declaration
(defstruct Point
  (x i64)
  (y i64))
```

- Layout: fields stored sequentially with natural alignment per field. No tag word.
- Constructor syntax: `(Point 10 20)` — a call-like expression.
- Field access: `(struct-get p x)` — generates a GEP+load at the field's byte offset.
- Structs are heap-allocated when returned from functions (same rule as enums).
- Not valid as global variables.

### 3.5 Type aliases

There are no explicit type aliases. Identifiers naming enums or structs are resolved to their nominal types during type checking.

### 3.6 Type conversions (casts)

```lisp test=ignore name=cast-placeholder reason=placeholder
(cast expr : target_type)
```

- Narrowing keeps the low N bits, where N is the target width. The resulting
  bits are interpreted using the target type's signedness.
- Widening sign-extends signed integer sources and zero-extends unsigned
  integer sources.
- `char` → integer: zero-extends the byte value.
- Integer → `char`: truncates to the low byte.
- No implicit conversions.

---

## 4. Top-level forms

### 4.1 `(define name [: type] init)` — global variable

Declares a global variable with a constant literal initializer.

**Supported global types:** scalar integers, `bool`, `char`, `f64`, `unit`.
**Not supported:** `String`, structs, enums, arrays, dynamic arrays, function pointers.

Example:
```lisp test=check name=scalar-globals
(define answer : i64 42)
(define pi : f64 3.14)
(define flag : bool true)
```

### 4.2 `(define (name [param : type] ...) [: ret_type] body)` — function

Defines a named function.

- Parameters must be explicitly typed.
- Return type defaults to `unit` when omitted.
- The entry point is a function named `main` with return type `i64` or `unit`. If `main` is missing, the compiler synthesizes one that returns 0.
- Recursion is supported.
- Varargs are **not** supported.

### 4.3 `(extern name : (-> args ... ret))` — external symbol

Declares an external function to link against. The name is an identifier, not a
string. External symbols are emitted without the `_tl_` TypeLisp function
prefix. Identifier punctuation is converted to assembler-safe symbol text; for
example, hyphens become underscores and `?` becomes `_question`. Extern
signatures may use the backend ABI value types, including pointer-valued
`String`, dynamic array, enum, and struct values.

Example:
```lisp test=check name=extern-declaration
(extern foreign-add : (-> i64 i64 i64))
```

### 4.4 `(import "path.tl")` — module import

Imports another TypeLisp file. All top-level definitions from the imported file become available.

- Relative paths are resolved from the importing file's directory.
- Absolute filesystem paths are accepted by the underlying path resolver.
- Circular imports currently terminate by loading each module once; they are not rejected.
- Import paths are normalized; importing via different relative paths to the same file deduplicates.
- The repository's `stdlib/` directory is currently just source files. Importing
  `stdlib/string.tl` works only when that path is reachable from the importing
  file, such as by staging or copying the `stdlib/` directory next to the entry
  source, unless the CLI is given one or more `--stdlib-root <dir>` options or
  `TYPELISP_STDLIB_ROOT` is set.
- For relative imports that start with `stdlib/`, the loader first tries the
  importer-relative path. If that path cannot be loaded, each configured stdlib
  root is searched by stripping the leading `stdlib/` and joining the remainder
  to the root. Explicit `--stdlib-root` entries are searched before the optional
  `TYPELISP_STDLIB_ROOT` fallback. Local project files therefore take precedence
  over configured stdlib roots. Configured stdlib roots only serve normal
  relative suffixes under the root; suffixes containing components such as `..`
  are not resolved through stdlib root fallback.
- The current stdlib source-tree layout and verification convention is
  documented in `stdlib/README.md`.
- A local package manifest/build command exists, but package dependencies,
  package-qualified import syntax, namespace isolation, and implicit preludes
  are not defined yet.

### 4.5 `typelisp.pkg` — local package manifest

`typelisp.pkg` is an S-expression package manifest for local builds:

```lisp test=ignore name=package-manifest reason="manifest file, not TypeLisp source"
(package
  (name "my-app")
  (version "0.1.0")
  (entry "src/main.tl"))
```

- `name`, `version`, and `entry` are required string fields.
- `entry` is resolved relative to the manifest directory.
- `typelisp build --manifest-path path/to/typelisp.pkg` builds the entry file
  through the same module loader and compiler pipeline as `compile`.
- `typelisp build` without `--manifest-path` searches for `typelisp.pkg` from
  the current directory upward.
- Build output is assembly under
  `target/typelisp/<package-name>/<package-name>.s` in the package root.
- This first package layer has no dependency resolver, package-qualified import
  syntax, namespace isolation, lockfile, workspace model, registry, or native
  executable build promise.

### 4.6 `(defenum ...)` and `(defstruct ...)`

See §3.4.

---

## 5. Expressions

### 5.1 Literals

| Literal | Syntax | Type |
|---------|--------|------|
| Integer | `42`, `-7` | `i64` |
| Float | `3.14`, `-0.5` | `f64` |
| Boolean | `true`, `false` | `bool` |
| Character | `#A'`, `#\n'`, `#\t'`, `#\0'` | `char` |
| String | `"hello"` | `String` |
| Unit | `unit` | `unit` |

### 5.2 Variables and scoping

- Global variables: visible everywhere after their definition.
- Function parameters: visible in the function body.
- `let` bindings: visible in the `let` body only.
- `set!` mutates variables in scope (locals and globals).
- Variables are looked up in order: local bindings → function parameters → globals.

### 5.3 Function calls

```lisp test=ignore name=call-placeholder reason=placeholder
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
| `neg` | integer → integer | Unary negation |
| `/` | integer integer → integer | Signed division |
| `%` | integer integer → integer | Remainder |
| `and` | bool bool → bool | Logical AND (short-circuit: **no** — both evaluated) |
| `or` | bool bool → bool | Logical OR (short-circuit: **no** — both evaluated) |
| `bit-and` | integer integer → integer | Bitwise AND |
| `bit-or` | integer integer → integer | Bitwise OR |
| `bit-xor` | integer integer → integer | Bitwise XOR |
| `shl` | integer integer → integer | Left shift |
| `shr` | integer integer → integer | Right shift (arithmetic for signed, logical for unsigned) |

- Integer arithmetic operators require matching operand types and return that type.
- Integer `+`, `-`, `*`, and `neg` wrap modulo 2^N, where N is the result type
  width. Signed integer results use two's-complement interpretation of those
  wrapped bits.
- Bitwise and shift operators accept integer operands and return the left-hand
  operand type.
- `+`, `-`, `*`, `/` also operate on `f64`; `%` on floating-point values is
  rejected by backend validation.
- Integer `/` and `%` trap at runtime when the divisor is zero, or when a
  signed dividend is the minimum value for its width and the divisor is `-1`
  (since the mathematical result is not representable). Both cases abort
  the process with a diagnostic written to stderr and exit status 135.
- `shl` and `shr` trap at runtime when the shift count is outside the range
  `0 <= count < bit_width(lhs)`. Negative counts and counts equal to or
  greater than the left-hand operand's bit width are rejected. Both cases
  abort the process with a diagnostic written to stderr and exit status 129.

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
- String equality uses `(string-eq s1 s2)` or `(string=? s1 s2)`.

### 5.6 `(if cond then else)` — conditional

- `cond` must be `bool`.
- Both branches must have the same type.
- Returns the value of the taken branch.

### 5.7 `(let ([name [: type] init] ...) body)` — local bindings

- Declares one or more local variables.
- Variables are in scope for `body` and for subsequent bindings in the same `let` (sequential, not parallel).
- Type annotation is optional. If omitted, the initializer type is inferred.
- The body is a single expression; use `begin` for a multi-expression body.

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

### 5.12 `(cast expr : type)` — type conversion

See §3.6.

### 5.13 `(match scrutinee [pattern expr] ...)` — pattern matching

- Enum scrutinees support variant patterns such as `Red` and `(Some value)`.
- Scalar scrutinees support literal patterns plus `_`.
- Bindings in enum patterns introduce variables for payload fields.
- A bare identifier at the top level of an enum `match` arm is resolved as a
  nullary variant name. It is not a fresh catch-all binding; use `_` for that.
- The `_` wildcard matches any remaining value (used for exhaustiveness).
- All arms must return the same type.
- Enum values are heap-allocated on return from functions (see §3.4.1).

### 5.14 `(lambda ([param : type] ...) [: ret_type] body)` — anonymous function

- Parses and type-checks as a function value for supported scalar returns.
- Backend lowering for lambda literals is incomplete today.
- No closure captures.

---

## 6. Built-in functions and runtime

### 6.1 Builtin functions (lowered to IR calls)

| Builtin | Signature | Description |
|---------|-----------|-------------|
| `print` | `i64 → unit` | Print integer to stdout + newline |
| `print-bool` | `bool → unit` | Print `true`/`false` to stdout + newline |
| `print-float` | `f64 → unit` | Print floating-point value to stdout + newline |
| `print-char` | `char → unit` | Print ASCII character to stdout |
| `print-newline` | `→ unit` | Print newline to stdout |
| `print-string` | `String → unit` | Print string bytes to stdout |
| `print-str` | `String → unit` | Alias for `print-string` |
| `print-error` | `String → unit` | Print string bytes to stderr |
| `arg-count` | `→ i64` | Get Linux process `argc` |
| `arg` | `i64 → String` | Get argv entry as an owned String |
| `read-file` | `String → String` | Read whole file contents; panics on error |
| `write-file` | `String String → unit` | Write whole file contents; panics on error |
| `file-exists?` | `String → bool` | Return true when a filesystem path exists; panics on unexpected syscall/path errors |
| `length` | `(Array t) → i64` | Get dynamic array length |
| `length` | `String → i64` | Get string byte length |
| `array-length` | `(Array t) → i64` | Get dynamic array length |
| `make-array` | `type i64 → (Array type)` | Allocate dynamic array element buffer; invalid lengths trap |
| `array-ref` | `(Array t) i64 → t` | Read dynamic or fixed array element (bounds checked) |
| `array-set!` | `(Array t) i64 t → unit` | Write dynamic or fixed array element (bounds checked) |
| `string-ref` | `String i64 → char` | Read byte from string (bounds checked) |
| `string-length` | `String → i64` | Get string byte length |
| `string-eq` | `String String → bool` | Byte-wise string comparison |
| `string=?` | `String String → bool` | Alias for `string-eq` |
| `string-append` | `String String → String` | Concatenate two strings |
| `string-concat` | `String String → String` | Alias for `string-append` |
| `substring` | `String i64 i64 → String` | Fresh string of `len` bytes starting at byte offset `start` (a `[start, start+len)` slice). Bounds checked. |
| `string-slice` | `String i64 i64 → String` | Alias for `substring` |
| `string->int` | `String → i64` | Parse decimal integer from string |
| `int->string` | `i64 → String` | Format integer as decimal string |
| `panic` | `String → never` (internal) | Print message to stderr and abort |
| `error` | `String → never` (internal) | Alias for `panic` |

- `make-array` checks the runtime length before allocation. Negative lengths and
  `length * sizeof(type)` overflow call the same `tl_oob_abort` runtime trap
  used by bounds checks.
- `array-ref`, `array-set!`, `string-ref`, and `substring`/`string-slice`
  perform runtime bounds checks. Out-of-bounds calls the `tl_oob_abort` runtime
  trap (writes to stderr and exits with code 134). The slice range is checked
  with unsigned arithmetic, so a negative `start`/`len` wraps to a huge value
  and traps.
- The `char-at` operator is an alias for `string-ref`.

### 6.2 Runtime functions (emitted by the backend)

The compiler emits helper routines into the generated assembly when needed.
They are not implemented by a separate C runtime.

| Symbol | Purpose |
|--------|---------|
| `tl_print_i64` | Print integer |
| `tl_print_bool` | Print boolean |
| `tl_print_f64` | Print floating-point value |
| `tl_print_char` | Print character |
| `tl_print_newline` | Print newline |
| `tl_print_str` | Print string bytes |
| `tl_alloc` | Allocate bump-allocator memory |
| `tl_string_eq` | String comparison |
| `tl_string_concat` | String concatenation |
| `tl_substring` | String slicing |
| `tl_string_to_int` | Parse integer |
| `tl_int_to_string` | Format integer |
| `.L_tl_arg_count` | Return captured process argc |
| `.L_tl_arg` | Return copied argv entry |
| `.L_tl_read_file` | Read whole file |
| `.L_tl_write_file` | Write whole file |
| `.L_tl_abort` | Print and abort (used by `panic`/`error`) |
| `tl_oob_abort` | Bounds-check trap |

### 6.3 Builtin operator aliases

| Alias | Expands to |
|-------|------------|
| `string=?` | `string-eq` |
| `string-concat` | `string-append` |
| `string-slice` | `substring` |
| `char-at` | `string-ref` |
| `print-str` | `print-string` |

---

## 7. Memory model

### 7.1 Stack

- Function parameters and local variables are allocated in RBP-relative stack slots.
- Stack grows downward. Frame size is computed at compile time.
- Stack is aligned to 16 bytes at every call site (System V ABI requirement).

### 7.2 Heap

- Dynamic array element buffers and escaping returned aggregates (enums,
  structs, strings, dynamic-array fat values) are heap-allocated.
- Non-escaping aggregate fat/inline storage is usually kept in the current stack frame.
- Allocation goes through `tl_alloc`, a backend-emitted bump allocator.
- There is **no garbage collector** or `free`. Memory is leaked on every dynamic allocation.

### 7.3 Globals

- Stored in the `.data` or `.rodata` section.
- Mutable globals use `.data` with an initializer.
- String literal bytes are stored in `.rodata`; a `String` value points to
  inline `{ptr,len}` storage whose `ptr` field points into `.rodata`.

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
- Strings: literals, `string-ref`/`char-at`, `string-length`/`length`,
  `string-eq`/`string=?`, `string-append`/`string-concat`,
  `substring`/`string-slice`, `string->int`, `int->string`,
  `print-string`/`print-str`, `print-error`.
- Bootstrap I/O helpers: `arg-count`, `arg`, `read-file`, `write-file`,
  `file-exists?`.
- `extern` declarations.
- Multi-file modules via `import`.
- Builtin `print`, `print-bool`, `print-float`, `print-char`,
  `print-newline`, `print-string`/`print-str`, `print-error`,
  `string-append`/`string-concat`, `read-file`, `write-file`, `file-exists?`,
  `panic`/`error`.

### 8.2 What does NOT work (yet)

| Feature | Status |
|---------|--------|
| `f32` type | Rejected by backend validation |
| `f32` local/parameter type | Rejected by backend validation |
| Tuple by-value ABI | Function parameters/returns rejected by backend validation |
| Fixed-array by-value return | Rejected by backend validation |
| Tuple/Struct/Enum/String globals | Rejected by backend validation |
| Closures (capturing lambdas) | Not implemented |
| Tail call optimization | Not implemented |
| `struct-set!` | Not implemented |
| Garbage collection / `free` | Not implemented (memory leaks) |
| Windows target | Not implemented |
| Complete source locations for all semantic errors | Partial |
| REPL | Not implemented |
| Package manager | Not implemented |
| LSP / IDE support | Not implemented |

---

## 9. Error handling

TypeLisp has one built-in error-handling mechanism today: **panic**.

```lisp test=ignore name=panic-expression reason=not-standalone
(panic "message")
```

- Prints the message to stderr.
- Calls the private runtime helper `.L_tl_abort` (which prints and exits).
- Panic is a terminal operation; it never returns normally.
- `error` is an alias for `panic`.

The type checker gives builtin `panic` and `error` a compiler-internal bottom
type. It is not user-denotable syntax, but it can satisfy any expected type and
can merge with concrete `if` branch or `match` arm result types. The lowerer
still emits a destination-less `.L_tl_abort` call; the internal type is never a
runtime value.

```lisp test=compile name=panic-never-branch
(define (parse-or-zero [ok : bool]) : i64
  (if ok
    1
    (panic "parse failed")))
```

The older dummy-value style also remains valid, but it is no longer required
for builtin `panic`/`error`:

```lisp test=compile name=panic-dummy-value
(define (parse-or-zero-compat [ok : bool]) : i64
  (if ok
    1
    (begin
      (panic "parse failed")
      0)))
```

Recoverable failures are represented with ordinary monomorphic enums. There
are no built-in generic `Option<T>` / `Result<T,E>` types, no `?` operator,
and no early-return sugar yet. Code that can recover should define an explicit
domain enum and handle every variant with `match`.

- Use `Maybe*` names for absence-only APIs, such as lookup hit/miss.
- Use `Result*` names for APIs that distinguish success from an error value.
- Matches must be exhaustive; omitted variants are rejected by the type checker.

```lisp test=compile name=monomorphic-maybe-result
(defenum MaybeI64
  (NoneI64)
  (SomeI64 i64))

(defenum ResultI64
  (OkI64 i64)
  (ErrI64 String))

(define (find-answer [name : String]) : MaybeI64
  (if (string-eq name "answer")
    (SomeI64 42)
    NoneI64))

(define (read-small [text : String]) : ResultI64
  (if (string-eq text "7")
    (OkI64 7)
    (ErrI64 (string-append "bad: " text))))

(define (maybe-score [m : MaybeI64]) : i64
  (match m
    [(SomeI64 value) value]
    [(NoneI64) 0]))

(define (result-score [r : ResultI64]) : i64
  (match r
    [(OkI64 value) value]
    [(ErrI64 message) (string-length message)]))

(define (main) : i64
  (+ (maybe-score (find-answer "answer"))
     (result-score (read-small "no"))))
```

Issue #45 tracks the remaining design work around generics, `?`-style
propagation, and richer diagnostic payloads.

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
  build       Build nearest typelisp.pkg to package assembly

Options:
  compile -o <file>       Write assembly to the given path
  compile --emit-ir       Write the lowered and optimized IR instead of assembly
  build --manifest-path <file>
                          Use an explicit package manifest path
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
| 7th | Stack (8-byte aligned) | `%xmm6` |
| 8th | Stack (8-byte aligned) | `%xmm7` |
| 9th+ | Stack (8-byte aligned) | Stack |

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
| `i64`/`u64`/`f64`/func ptr | 8 | 8 |
| `String`/`DynArray`/`Enum`/`Struct` values | 8 | 8 |

- Structs: sequential layout with natural alignment per field. No padding minimization (fields are placed in declaration order).
- Enums: tag word (8 bytes) + max payload size, aligned to 8 bytes.
- `String`, dynamic-array, enum, and struct values are pointers in IR/ABI
  slots. Their pointed-to inline storage is larger: strings and dynamic arrays
  are 16-byte `{ptr,len}` records; structs and enum payload storage depend on
  their declared fields.

---

## 12. Examples

### Hello world (factorial)

```lisp test=run name=factorial exit=120 stdout=""
(define (factorial [n : i64]) : i64
  (if (= n 0)
      1
      (* n (factorial (- n 1)))))

(define (main) : i64
  (factorial 5))  ; returns 120
```

### Enum with match

```lisp test=run name=enum-match exit=42 stdout=""
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

```lisp test=run name=struct-access exit=7 stdout=""
(defstruct Point (x i64) (y i64))

(define (main) : i64
  (let ([p : Point (Point 3 4)])
    (+ (struct-get p x) (struct-get p y))))  ; returns 7
```

### Dynamic array

```lisp test=run name=dynamic-array exit=30 stdout=""
(define (main) : i64
  (let ([arr : (Array i64) (make-array i64 5)])
    (begin
      (array-set! arr 0 10)
      (array-set! arr 1 20)
      (+ (array-ref arr 0) (array-ref arr 1)))))  ; returns 30
```

### String operations

```lisp test=run name=string-length exit=5 stdout=""
(define (main) : i64
  (let ([s : String "hello"])
    (string-length s)))  ; returns 5
```

```lisp test=run name=print-string exit=0 stdout="hello\n"
(define (main) : i64
  (begin
    (print-string "hello\n")
    0))  ; prints hello + newline, returns 0
```

### Extern call

```lisp test=run name=extern-tl-alloc exit=0 stdout=""
(extern tl_alloc : (-> i64 u64))

(define (main) : i64
  (begin
    (tl_alloc 16)
    0))
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

define-var    ::= "(" "define" ident [":" type] expr ")"
define-func   ::= "(" "define" "(" ident param* ")" [":" type] expr ")"
extern-decl   ::= "(" "extern" ident ":" type ")"
import-decl   ::= "(" "import" string ")"
defenum       ::= "(" "defenum" ident variant+ ")"
defstruct     ::= "(" "defstruct" ident field+ ")"

param         ::= "[" ident ":" type "]"
field         ::= "(" ident type ")"
variant       ::= "(" ident type* ")"

expr          ::= literal
                | ident
                | "(" "if" expr expr expr ")"
                | "(" "let" "(" binding* ")" expr ")"
                | "(" "while" expr expr ")"
                | "(" "begin" expr+ ")"
                | "(" "set!" ident expr ")"
                | "(" "ann" expr ":" type ")"
                | "(" "cast" expr ":" type ")"
                | "(" "match" expr match-arm+ ")"
                | "(" "lambda" "(" param* ")" [":" type] expr ")"
                | "(" expr expr* ")"          ; function call

binding       ::= "[" ident [":" type] expr "]"
match-arm     ::= "[" pattern expr "]"
pattern       ::= "_"
                | literal
                | ident
                | "(" ident ident* ")"

literal       ::= integer | float | bool | char | string | "unit"

type          ::= "i64" | "i32" | "i16" | "i8"
                | "u64" | "u32" | "u16" | "u8"
                | "f64" | "f32" | "bool" | "char" | "unit"
                | "String"
                | "(" "Tuple" type+ ")"
                | "(" "Array" type [integer] ")"
                | "(" "->" type+ ")"
                | ident                                ; enum or struct name

ident         ::= [a-zA-Z_][a-zA-Z0-9_!?+-=*/<>:]*
integer       ::= [-]?[0-9]+
float         ::= [-]?[0-9]+\.[0-9]+
bool          ::= "true" | "false"
char          ::= "#" . "'" | "#\\" . "'"
string        ::= \"...\"
```

---

## 14. Changelog

### 0.1.0-dev

- Initial specification covering the language as implemented.
