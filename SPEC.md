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

The self-hosted documentation extractor recognizes public documentation
comments before the main Rust lexer discards comments:

- `;;;;` starts a module/file documentation line.
- `;;;` starts an outer item documentation line attached to the next supported
  top-level item: value `define`, function `define`, `extern`, `defenum`, or
  `defstruct`.
- `;` and `;;` remain ordinary comments and are not public documentation.
- Outer item doc lines must be contiguous. A blank line, ordinary comment,
  module doc, unsupported top-level form, or unrelated source text clears the
  pending item doc block. A pending block at EOF is ignored.

Documentation tests are fenced examples inside those public documentation
comments. `typelisp doc --test <file.tl>` recognizes Markdown code fences whose
info string starts with `typelisp` or `tl`, extracts them from `;;;;` module docs
and attached `;;;` item docs, and checks each example as a standalone TypeLisp
source file. An example passes when it parses, resolves imports, and type-checks.
Adding `expect-error` after the language tag inverts the expectation so the
example must fail during loading, parsing, or type checking. Other fence
languages are ignored; unknown TypeLisp fence options, empty TypeLisp examples,
and unterminated TypeLisp fences are malformed doctests.

The self-hosted Markdown generator driver is `selfhost/doc.tl`. In this slice it
renders one input file to one output path via `typelisp run selfhost/doc.tl --
input.tl output.md`; package/module graph traversal is not part of this driver.

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
- A named top-level function can be used as a non-capturing function pointer
  value, e.g. `(apply1 inc 41)` where `apply1` takes a `(-> i64 i64)`.
- Non-capturing `lambda` literals are lifted to deterministic synthetic
  top-level functions and materialized as raw function pointer values.
- Capturing `lambda` literals build heap-allocated closure environments and
  evaluate to closure descriptor values. Supported captures are scalars,
  function values, `String`, dynamic arrays, and tuples of scalars (see §5.14).

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

#### 3.4.3 C-compatible `repr c` structs (specified, selfhost pending)

Default TypeLisp struct layout is compiler-owned and may use aggregate-handle
rules that are not a C ABI contract. FFI-facing structs must opt into a stable
C-compatible layout with metadata immediately after the struct name and before
the first field:

```lisp test=ignore name=repr-c-struct-syntax reason="selfhost repr c parsing is tracked by #987"
(defstruct Stat
  (:repr c)
  (size i64)
  (mtime i64))
```

V1 accepts only the metadata form `(:repr c)`. Omitting it preserves the default
TypeLisp layout. Metadata forms must appear before all fields; a metadata form
after a field is rejected. Duplicate `:repr` metadata is rejected. Unknown
metadata keys and unknown representation names are rejected. `packed`,
`(:repr packed)`, and equivalent packed-layout spellings are reserved and
rejected until an unsafe packed-field slice exists.

V1 `repr c` fields are restricted to ABI-safe types:

- Fixed-width scalar types supported by the backend: `i8`, `u8`, `i16`, `u16`,
  `i32`, `u32`, `i64`, `u64`, `f64`, `bool`, and `char`. `f32` remains rejected
  until the backend supports it.
- Raw pointer types once the raw-pointer surface from #955 lands.
- Nested structs that are themselves marked `repr c`.

Default-layout structs, strings, dynamic arrays, enums, tuples, fixed arrays,
functions/closures, safe references, region-tagged references, unresolved
types, and any other aggregate handle are not ABI-safe `repr c` fields in v1.
They must be rejected with a source-located diagnostic rather than silently
lowered as C-compatible storage.

Recursive by-value `repr c` struct cycles are rejected. Recursive structures
through raw pointers can be accepted only after raw pointers exist.

`repr c` layout uses declaration order. Each field starts at the next offset
aligned for that field. The total size is rounded up to the maximum field
alignment. Empty `repr c` structs are rejected in v1.

Supported v1 targets use an x86_64 data model: fixed-width integer and floating
types use their explicit sizes; `bool` and `char` are one byte; raw pointers are
8 bytes with 8-byte alignment on both Linux x86_64 System V and Windows x64.
If future targets need different pointer sizes or alignments, layout queries are
target-sensitive compile-time results and tests must either pin the target or
assert the target-specific values.

### 3.5 Type aliases

There are no explicit type aliases. Identifiers naming enums or structs are resolved to their nominal types during type checking.

### 3.6 Abstraction policy: comptime generation, not generics/traits

TypeLisp does not plan Rust-style source-level generics, traits, interfaces,
`impl` blocks, or generic type constructors such as `Option<T>` and
`Result<T,E>`. Generic-looking top-level forms are reserved only to produce a
diagnostic that points users at comptime-generated concrete declarations.

Reusable abstractions should be built by compile-time code that inspects type
values and emits concrete `defstruct`, `defenum`, `define`, and related
implementation declarations. The current implementation path is tracked by
#893 (concrete type and implementation bundles), #913 (type reflection
primitives), and #483 (stable generated functions/type constructors).

Until that path is complete, write explicit monomorphic declarations such as
`MaybeI64`, `ResultStringI64`, or domain-specific structs/enums.

### 3.7 Type conversions (casts)

```lisp test=ignore name=cast-placeholder reason=placeholder
(cast expr : target_type)
```

- Narrowing keeps the low N bits, where N is the target width. The resulting
  bits are interpreted using the target type's signedness.
- Widening sign-extends signed integer sources and zero-extends unsigned
  integer sources.
- `char` → integer: zero-extends the byte value.
- Integer → `char`: truncates to the low byte.
- Floating-point casts are not supported yet. `f64` arithmetic, comparison,
  arguments, returns, and `print-float` are supported, but `(cast ...)`
  currently accepts only integer/char source and target types.
- No implicit conversions.

### 3.8 Region-tagged types (v1)

A value allocated inside a `(with-region r ...)` scope carries a **region tag**
in its type, written `(in r T)` where `r` is the region name and `T` is the
underlying heap-allocated type. Region tags are a compile-time-only
annotation; they do not change ABI representation, runtime size, or data
layout. The tag exists solely to enable static escape checking.

**Region-taggable types** are the heap-allocated aggregate kinds whose storage
can be created inside a region scope:
- `String`
- `(Array T)` — dynamic array
- Enum and struct values returned from functions inside the region
- Tuple values (when tuple-by-value ABI support lands)

Scalars (`i64`, `bool`, `char`, `f64`, etc.), function values, and fixed-size
arrays are **not** region-tagged because they do not allocate through `tl_alloc`.

A region-tagged type `(in r T)` is a **subtype** of the plain type `T` for
operations that do not escape the region: field access, `array-ref`,
`array-set!`, `match` arms, `print-string`, and function calls whose parameter
types accept `T`. It is **not** a subtype where the value would leave the
region's scope: as the result of the `with-region` form, stored into an outer
`let` or global, captured by an escaping closure, or returned from an enclosing
function.

**v1 confinement rule:** Region-tagged values do not cross function boundaries.
A function parameter or return type is written without a region tag; passing a
region-tagged value to a function or returning it from one is an escape error.
Region-polymorphic functions (`(forall (r) ...)`) are deferred to a follow-up
slice; every function type in v1 is region-agnostic and therefore cannot
accept or produce region-tagged handles.

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
`String`, dynamic array, enum, and struct values. Exact external symbol
metadata, including symbols that should not be derived from the TypeLisp
identifier spelling, is owned by #911 and is separate from TypeLisp
module-prefixed user symbols.

Example:
```lisp test=check name=extern-declaration
(extern foreign-add : (-> i64 i64 i64))
```

### 4.4 `(import "path.tl")` — module import

Imports another TypeLisp file. The current Rust stage0 loader still behaves as
a legacy whole-program concatenation model: all top-level definitions from the
imported file become available in one flat namespace. The selfhost module model
specified below replaces that with canonical module identities, explicit
exports, and qualified lookup.

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
- During package builds, imports of the form `pkg:<alias>/<path>` resolve
  from a dependency package root declared in the current `typelisp.pkg`.
  Package import suffixes must stay below that dependency root. Under the
  legacy loader, imported declarations still share the same flat top-level
  namespace as ordinary modules, so duplicate value or type names are errors.

#### 4.4.1 Selfhost module identities and imports (specified, pending slices)

A module has a canonical identity independent of the source path spelling that
loaded it. If a source file contains an explicit `(module ident)` declaration,
that identity is the canonical module identity for following declarations until
another `(module ident)` declaration appears. During migration, files without an
explicit module declaration use the loader's normalized source identity as their
canonical identity. Different path spellings that normalize to the same source
file must load one module instance.

The canonical identity is a slash-separated identifier path such as
`stdlib/string`, `compiler/lower`, or `math/vector`. It must be stable across
platform path separators and package-root spellings. A `pkg:<alias>/...` import
contributes the package alias to the loader identity, but an explicit `(module
...)` declaration inside the file remains the public source-level identity.

Importing a module loads it and binds a module alias; it does not merge exported
declarations into the local unqualified namespace by default. The default alias
is the final segment of the imported module identity. If that alias would
collide with an existing module alias, the import is rejected unless the source
uses an explicit alias:

```lisp test=ignore name=module-import-alias-syntax reason="selfhost module aliases are tracked by #952"
(import "math/vector.tl" :as vec)
(import "io/vector.tl" :as io-vec)
```

Selected imports remain deferred in v1. Spellings such as
`(import "math/vector.tl" :only (dot norm))` are reserved and must be rejected
until a follow-up specifies their shadowing and re-export rules.

#### 4.4.2 Exports and visibility

Module declarations are private by default. Other modules may use only exported
items through a qualified name. Value and type namespaces remain separate:

- Value exports cover function `define`s, variable `define`s, and TypeLisp
  declarations for `extern`s.
- Type exports cover enum and struct type names.
- Enum variant constructors and struct constructors/accessors are value-space
  capabilities that must be exported explicitly or through a transparent type
  export.

V1 export syntax is an explicit top-level form:

```lisp test=ignore name=module-export-syntax reason="selfhost exports are tracked by #910/#952"
(module geometry)

(defstruct Point
  (x i64)
  (y i64))

(export
  (type Point)
  (constructor Point)
  (field Point x)
  (field Point y))
```

`(export (type Point))` exports only the nominal type name. For structs this is
an opaque type export: external modules can mention `geometry/Point` but cannot
construct it or read fields unless the constructor and fields are also exported.
For enums, exporting only the type keeps variants private; variants can be
exported separately with `(variant VariantName)`. A transparent convenience
form such as `(type Point :transparent)` may be added later, but v1 semantics
are defined by the explicit item forms above.

Duplicate exports of the same item are accepted as idempotent only if they name
the same namespace item. Unknown export names and namespace mistakes, such as
exporting a type as a value, are rejected.

#### 4.4.3 Qualified lookup

Qualified names use `/`: `alias/name` for one alias segment and
`module/path/name` for canonical module paths when no local alias is used.
Unqualified lookup searches only local declarations and local bindings. It does
not search imported modules.

Qualified lookup applies to:

- Values: `(vec/dot a b)`, `config/default-timeout`.
- Types: `[p : geometry/Point]`.
- Enum variants and patterns: `(json/Some value)` and `[(json/Err e) ...]`.
- Struct constructors: `(geometry/Point 3 4)`.
- Struct fields: `(struct-get p x)` resolves `x` through the receiver's struct
  type; exporting the field controls whether external modules may use it.
- Generated declarations: generated family keys include the generator module
  identity plus the generated declaration identity.

Missing module aliases, ambiguous aliases, missing qualified members, private
members, and using a value-qualified name where a type is required are
source-located errors.

Example with colliding local names:

```lisp test=ignore name=qualified-colliding-modules reason="selfhost qualified imports are tracked by #952"
;; left.tl
(module left)
(export (value get))
(define same : i64 20)
(define (get) : i64 same)

;; right.tl
(module right)
(export (value get))
(define same : i64 22)
(define (get) : i64 same)

;; main.tl
(import "left.tl")
(import "right.tl")
(define (main) : i64 (+ (left/get) (right/get)))
```

#### 4.4.4 TypeLisp linker symbols

The TypeLisp declaration identity used by lowering and backend symbol emission
is `(canonical-module-identity, declaration-identity)`. User TypeLisp linker
symbols are deterministic assembler-safe encodings of both parts, with one
special entry rule: the selected entry declaration named `main` emits the host
entry symbol `main`, while any other declaration named `main` receives a normal
module-prefixed TypeLisp symbol.

Exact external FFI linker names are not defined by this module model. `extern`
declarations keep a TypeLisp declaration identity for lookup and visibility,
but backend calls may bypass TypeLisp prefixing only when explicit external
symbol metadata from #911 says to do so. Runtime helper symbols and
backend-local labels are likewise outside module-prefixing and must not be
accidentally rewritten as user declarations.

### 4.5 `(test name body...)` - inline test item

Declares a source-owned inline test. The name is an identifier. The body must
contain one or more expressions; multiple expressions are sequenced like
`begin`.

Normal production commands (`check`, `compile`, `build`, and `run`) ignore
`test` items. `typelisp test <file.tl>` loads the import graph, lowers every
inline test into a private unit-returning function, skips any production
`main`, generates a test-owned `main`, and runs the resulting executable.
`typelisp test --check <file.tl>` type-checks that generated harness without
assembling or linking. The current runner is intended for unit-returning test
bodies; assertion helpers in `stdlib/test.tl` panic on failure.

Example:
```lisp test=check name=inline-test-declaration
(define (inc [x : i64]) : i64 (+ x 1))

(test inc-basic
  (if (= (inc 41) 42)
    unit
    (panic "inc result")))
```

### 4.6 `typelisp.pkg` — local package manifest

`typelisp.pkg` is an S-expression package manifest for local builds:

```lisp test=ignore name=package-manifest reason="manifest file, not TypeLisp source"
(package
  (name "my-app")
  (version "0.1.0")
  (entry "src/main.tl")
  (dependencies
    (math "../math")))
```

- `name`, `version`, and `entry` are required string fields.
- `dependencies` is optional. Each entry has an alias symbol and a string root
  path: `(alias "relative/or/absolute/path")`.
- Dependency aliases use the same character rules as package names: ASCII
  letters, digits, `-`, and `_`; duplicate aliases are rejected.
- `entry` is resolved relative to the manifest directory.
- Relative dependency paths are resolved relative to the manifest directory;
  absolute dependency paths are used as written.
- `typelisp build --manifest-path path/to/typelisp.pkg` builds the entry file
  through the same module loader and compiler pipeline as `compile`.
- `typelisp build` without `--manifest-path` searches for `typelisp.pkg` from
  the current directory upward.
- Build output is assembly under
  `target/typelisp/<package-name>/<package-name>.s` in the package root.
- Package-root-qualified imports use the reserved string prefix
  `pkg:<alias>/...`, for example `(import "pkg:math/src/lib.tl")`.
- This first package layer has no registry, semantic-version solving,
  transitive manifest loading, implicit preludes, lockfile, workspace model, or
  native executable build promise for package manifests. Namespace isolation and
  qualified symbol access are specified by the selfhost module model in section
  4.4, not by package resolution itself.

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
- Indirect calls: the callee is a variable/parameter of function type, or a
  named top-level function has been passed as a function pointer value.
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

`(cond [test expr] ... [else fallback])` is a Lisp-native else-if surface
form. It parses to nested `if` expressions, so each test must type-check as
`bool` and all branch result types must merge using the normal `if` rules.
The final arm is required and must be `[else fallback]`; `else` is only special
as the head of the final `cond` arm.

```lisp test=ignore name=cond-expression reason=fragment
(cond
  [(= x 0) 10]
  [(= x 1) 20]
  [else 30])
```

### 5.7 `(let [name [: type] init] ... body)` — local bindings

- Declares one or more local variables.
- Bindings are the leading bracket forms after `let`; the first non-bracket form is the body expression.
- Variables are in scope for `body` and for subsequent bindings in the same `let` (sequential, not parallel).
- Type annotation is optional. If omitted, the initializer type is inferred.
- The body is a single expression; use `begin` for a multi-expression body.
- Empty binding lists are rejected.

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

See §3.7. Casts currently cover integer/char widening, narrowing, and
truncation only; floating-point conversions are deferred.

### 5.13 `(match scrutinee [pattern expr] ...)` — pattern matching

- Enum scrutinees support variant patterns such as `Red` and `(Some value)`.
- Scalar scrutinees support literal patterns plus `_`.
- String literal patterns compare string contents, not pointer identity.
- Bindings in enum patterns introduce variables for payload fields.
- A bare identifier at the top level of an enum `match` arm is resolved as a
  nullary variant name. It is not a fresh catch-all binding; use `_` for that.
- The `_` wildcard matches any remaining value (used for exhaustiveness).
- All arms must return the same type.
- Enum values are heap-allocated on return from functions (see §3.4.1).

### 5.14 `(lambda ([param : type] ...) [: ret_type] body)` — anonymous function

- Parses and type-checks as a function value for backend-supported return
  types.
- Non-capturing lambdas lower to deterministic synthetic top-level functions
  and evaluate to static closure descriptor values.
- Capturing lambdas snapshot supported captures into heap-allocated closure
  environments. Supported captured values are integer widths, `bool`, `char`,
  `f64`, function values, `String`, dynamic arrays, tuples/structs/enums
  (including ones with nested aggregate fields), and a directly-captured fixed
  `(Array T N)` of scalar elements. `String` and dynamic-array captures snapshot
  their fat `{ ptr, len }` value onto the heap so the environment can outlive
  the frame that created the handle without dangling; the underlying buffer
  (`.rodata` for string literals, `tl_alloc` for dynamic arrays) is shared,
  matching aggregate-handle reference semantics. A tuple/struct/enum capture
  shallow-copies its inline storage onto the heap and then recursively
  re-snapshots any nested aggregate fields/payloads so they cannot dangle
  (#584). A scalar fixed-array capture shallow-copies its inline element storage
  and reconstructs the array view on capture-load (#571).
- Lambda literals can return scalar values and pointer-backed aggregate
  values supported by named function returns, including `String`, enums,
  structs, and dynamic arrays. Tuple and fixed-array by-value returns remain
  unsupported by the backend.
- `set!` to captured names is rejected. A fixed array of aggregate elements, and
  a fixed array reached through an aggregate field, are also rejected: array
  elements live inline (not as pointer-sized handles), so their per-element
  deep-copy is not yet wired (tracked under #571/#435).

```lisp test=ignore name=lambda-lift-immediate reason="integration tests cover executable lambda lifting"
((lambda ([x : i64]) : i64 (+ x 1)) 41)
```

### 5.15 SPMD `foreach`

This section defines the initial SPMD source surface. The current compiler
parses and type-checks `foreach`, lowers it to scalar reference loops, and has
an AVX2 backend path for a first contiguous map/zip subset. The reduction
surface below is the next source contract; parser/typechecker, scalar lowering,
IR, and backend support are tracked by follow-up issues.

Initial syntax:

```lisp test=ignore name=spmd-foreach-map reason="illustrative function; integration tests cover executable foreach programs"
(define (add-arrays [a : (Array i64)]
                    [b : (Array i64)]
                    [out : (Array i64)]
                    [n : i64]) : unit
  (foreach ([i : i64 0 n])
    (array-set! out i (+ (array-ref a i) (array-ref b i)))))
```

Semantics:

- `(foreach ([i : i64 start end]) body)` executes one logical program instance
  for each integer `i` in the half-open range `[start, end)`.
- `start` and `end` are uniform `i64` expressions evaluated once before the
  loop. If `end <= start`, the loop has zero logical iterations.
- `body` must have type `unit`; the `foreach` expression has type `unit`.
- The semantic result must match an ordinary scalar loop over the same range.
  SIMD lowering may group iterations into lanes, but programs must not depend
  on lane width or on an ordering between distinct logical iterations.
- Existing dynamic-array bounds checks still apply. If a `foreach` indexes past
  an array's length, the program traps the same way `array-ref`/`array-set!`
  traps today.

Initial dynamic-array use cases:

- Contiguous map and zip-style kernels over dynamic arrays.
- Reads through `array-ref` and writes through `array-set!`.
- Array indexes must be the loop index or a simple uniform offset from it, such
  as `i` or `(+ base i)`. Gather/scatter through an index array is deferred.
- Supported lane element types for the first slice are `i32`, `i64`, and `f64`.
  `f32` waits for scalar backend support; narrow integers, unsigned integers,
  `bool`, `String`, structs, enums, tuples, and arrays as lane elements are
  deferred.

Uniform and varying rules:

- Values are uniform by default.
- The `foreach` index binding is varying: each logical program instance has its
  own `i`.
- Arithmetic and comparisons involving a varying value produce varying values.
- `array-ref` with a varying index produces a varying element value.
- `array-set!` with a varying index or value performs one write per active
  logical program instance.
- There is no public `(varying T)` or mask type in the first source surface.
  Varying information is inferred inside `foreach` and masks are internal to
  lowering.
- `let` bindings inside the `foreach` body may be uniform or varying by
  inference. `set!` to a binding declared outside the `foreach` is rejected;
  reductions and cross-lane updates are separate future work.
- Calls with varying arguments are rejected until an SPMD function ABI is
  designed. The first slice only permits built-in arithmetic/comparison
  operators and array operations over supported lane types.
- `if` and `while` conditions must be uniform in the first slice. Divergent
  varying control flow is deferred until mask semantics are implemented.

Lane builtins:

- Public lane builtins equivalent to ISPC `programIndex` and `programCount` are
  explicitly deferred from the first slice.
- Reserve the names `program-index` and `program-count` for a later design.
  They should only become valid after target selection and vector/mask IR exist,
  because their semantics depend on gang width and tail-mask behavior.

Tail behavior:

- The language-level range has exactly `max(end - start, 0)` logical
  iterations.
- Scalar fallback lowering executes those iterations one at a time.
- SIMD lowering must use an internal active-lane mask for tails so lengths `0`,
  less than the lane width, exactly one lane width, and not divisible by the
  lane width all produce the same observable result.
- Inactive tail lanes must not perform bounds checks, loads, stores, calls, or
  other side effects.

SPMD reductions:

The first reduction surface is an explicit expression form:

```lisp test=check name=spmd-reduce-sum-i64
(define (sum-i64 [xs : (Array i64)] [n : i64]) : i64
  (spmd-reduce sum ([i : i64 0 n]) 0 (array-ref xs i)))
```

```lisp test=check name=spmd-reduce-any-bool
(define (contains-zero [xs : (Array i64)] [n : i64]) : bool
  (spmd-reduce any ([i : i64 0 n]) false (= (array-ref xs i) 0)))
```

```lisp test=check name=spmd-reduce-max-seeded
(define (max-i64-seeded [xs : (Array i64)] [n : i64] [seed : i64]) : i64
  (spmd-reduce max ([i : i64 0 n]) seed (array-ref xs i)))
```

Syntax:

- `(spmd-reduce op ([i : i64 start end]) init value)` evaluates to one scalar
  result.
- `op` is a fixed operator symbol, not an expression. The first supported
  operators are `sum`, `min`, `max`, `all`, and `any`.
- The range clause has the same half-open `[start, end)` meaning as `foreach`.

Evaluation and empty ranges:

- `start`, `end`, and `init` are uniform expressions evaluated once before any
  logical iteration. `init` is the accumulator seed and the empty-range result.
- `value` is evaluated once for each logical `i` in increasing index order in
  the scalar semantics. If `end <= start`, `value` is not evaluated.
- The semantic result is the same as a scalar left fold:
  - `sum`: `acc = (+ acc value)`.
  - `min`: `acc = (if (< value acc) value acc)`.
  - `max`: `acc = (if (> value acc) value acc)`.
  - `all`: `acc = (and acc value)`.
  - `any`: `acc = (or acc value)`.
- Integer `sum` uses the existing modulo-wrapping integer `+` semantics.
- `f64 sum` uses the same ordered scalar `+` semantics as an explicit loop.
  SIMD backends must preserve that observable result or leave `f64 sum` on the
  scalar path until a future relaxed-floating-point mode exists.

Type rules for the first slice:

- `sum` supports `i32`, `i64`, and `f64`.
- `min` and `max` support `i32` and `i64`.
- `all` and `any` support `bool`.
- `init` and `value` must have the same supported type for the chosen `op`, and
  the result type is that same type.
- `f32`, narrow integer widths, unsigned integer widths, `char`, `String`,
  structs, enums, tuples, arrays, function values, public vector types, and
  public mask types are rejected in the first reduction slice.

Purity and varying rules for the first slice:

- The `value` expression may use the varying index, dynamic-array reads,
  arithmetic/comparison/boolean operators over supported types, and local `let`
  bindings whose values satisfy the same rules.
- `value` must not perform writes or other side effects. In particular, `set!`,
  `array-set!`, `print*`, file I/O, `panic`/`error`, nested `foreach`, nested
  `spmd-reduce`, and user-defined calls with varying arguments are rejected in
  the first slice.
- Reductions by mutating an outer variable inside `foreach` remain rejected.
  Use `spmd-reduce` so scalar fallback and SIMD lowering have one explicit
  accumulator contract.

Cross-lane operations:

- `spmd-reduce` is the only public cross-lane source operation in this slice.
- Scans/prefix reductions, shuffles, broadcasts, lane extraction/insertion,
  public `program-index`/`program-count`, gathers/scatters, atomics, task
  parallelism, and public vector/mask values remain deferred.
- IR and backend work may add private horizontal-reduction primitives as needed
  to implement `spmd-reduce`; those primitives are not user-denotable source
  operations.

Unsupported in the initial SPMD surface:

- Public vector types, public mask types, `program-index`, and `program-count`.
- Gather/scatter, indirect indexing through arrays, and non-contiguous memory.
- Scans, general cross-lane operations, atomics, and overlapping writes.
- Reduction-by-mutation through `set!` to an outer accumulator.
- Varying `if`/`while`, early exits, `break`, and `continue`.
- User-defined function calls with varying arguments or varying returns.
- Struct, enum, tuple, string, function, and nested array lane values.
- Task parallelism, multicore scheduling, CPU dispatch, and AVX-specific codegen.

Negative examples for later parser/typechecker tests:

```lisp test=ignore name=spmd-reject-varying-if reason="future SPMD negative example"
(define (clamp-positive [xs : (Array i64)] [out : (Array i64)] [n : i64]) : unit
  (foreach ([i : i64 0 n])
    (if (< (array-ref xs i) 0)
        (array-set! out i 0)
        (array-set! out i (array-ref xs i)))))
```

```lisp test=ignore name=spmd-reject-mutation-reduction reason="future SPMD negative example"
(define (sum-array [xs : (Array i64)] [n : i64]) : i64
  (let
    [sum : i64 0]
    (begin
      (foreach ([i : i64 0 n])
        (set! sum (+ sum (array-ref xs i))))
      sum)))
```

```lisp test=ignore name=spmd-reject-f64-min reason="rejected by the type checker; the spec example harness only asserts positive check/compile/run"
(define (min-f64 [xs : (Array f64)] [n : i64] [seed : f64]) : f64
  (spmd-reduce min ([i : i64 0 n]) seed (array-ref xs i)))
```

```lisp test=ignore name=spmd-reject-shuffle reason="rejected by the parser; the spec example harness only asserts positive check/compile/run"
(define (bad-cross-lane [xs : (Array i64)] [n : i64]) : i64
  (spmd-reduce shuffle ([i : i64 0 n]) 0 (array-ref xs i)))
```

```lisp test=ignore name=spmd-reject-varying-call reason="future SPMD negative example"
(define (inc [x : i64]) : i64 (+ x 1))

(define (map-inc [xs : (Array i64)] [out : (Array i64)] [n : i64]) : unit
  (foreach ([i : i64 0 n])
    (array-set! out i (inc (array-ref xs i)))))
```

---

### 5.16 `(with-region ident body ...)` — scoped region

Introduces a temporary allocation region named `ident` whose lifetime is
the lexical scope of the form's body. The body is a non-empty expression
sequence; the last expression is the result. Subregions are expressed by
nesting `with-region` forms.

```lisp test=check name=with-region-basic
(define (main) : i64
  (with-region r
    (let
      [s : String (int->string 42)]
      (begin
        (print-string s)
        0))))
```

**Static escape checking:** Values allocated inside a region are typed as
`(in r T)` (see §3.8). The typechecker rejects any attempt to let a
region-tagged value escape its scope:

- As the result of the `with-region` form (`(with-region r (make-array i64 5))`).
- Stored into an outer `let`, `set!`, or global binding.
- Captured by a lambda whose closure outlives the region.
- Returned from an enclosing function.
- Passed to a function call (v1 confinement — function parameters have no
  region tag).

**Nested regions:** Inner and outer regions are distinct. A value allocated in
an inner region may not escape to the outer region, and a value from an outer
region may be used inside an inner region (it does not gain the inner tag).

**Lowering contract:** Each `with-region` lowers to a `tl_region_mark` at
entry, the body with all region-allocating operations implicitly targeting the
active region, and a `tl_region_reset` at exit that restores the mark. Because
the body result must be region-free, the reset is safe: no live handle refers
to storage allocated after the mark.

**Non-Linux targets:** `with-region` remains a typechecked scope. On targets
where `tl_region_mark` / `tl_region_reset` are unavailable the runtime does
not perform a reset; the semantics match minus reclamation. The form still
prevents escapes, so programs compile and run identically, but allocations
accumulate in the process-lifetime arena instead of being reclaimed.

### 5.17 Layout queries (specified, selfhost pending)

The selfhost FFI layout surface reserves three comptime-only query forms:

```lisp test=ignore name=repr-c-layout-query-syntax reason="layout queries are tracked by #989"
(defstruct Stat
  (:repr c)
  (size i64)
  (mtime i64))

(define stat-size : i64 (comptime (size-of (type Stat))))
(define stat-align : i64 (comptime (align-of (type Stat))))
(define stat-mtime-offset : i64 (comptime (offset-of (type Stat) mtime)))
```

- `(size-of type-expr)` returns the byte size as `i64`.
- `(align-of type-expr)` returns the ABI alignment as `i64`.
- `(offset-of type-expr field-name)` returns the byte offset of `field-name`
  inside a `repr c` struct as `i64`; `field-name` is a bare field identifier,
  not a string and not an evaluated expression.

`type-expr` must evaluate at compile time to a type value, usually from
`(type T)` or a comptime type parameter. `offset-of` requires a `repr c` struct
type and a field that exists on that struct. All three forms are valid only in
compile-time-required contexts such as comptime parameters, generated
declaration evaluation, and explicit `(comptime expr)` folds. To use a query
result at runtime, the program must fold it through normal comptime evaluation
and store the resulting `i64`; the compiler must not expose type or layout
metadata as a runtime value.

Queries reject wrong arity, missing or runtime-only type operands, non-type
operands, non-`repr c` structs where a C layout is required, unsupported field
types, invalid field names, and use outside a compile-time-required context.

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
| `read-file-status` | `String → i64` | Return 0 when `read-file` should succeed, otherwise a positive host status code |
| `write-file-status` | `String String → i64` | Write whole file contents and return 0 on success or a positive host status code |
| `file-exists-status` | `String → i64` | Return 0 when a path exists, otherwise a positive host status code such as not-found |
| `read-stdin-line` | `→ String` | Read one stdin line without trailing newline; blank line returns `""` and does not set EOF |
| `read-stdin-bytes` | `i64 → String` | Read up to `n` stdin bytes; negative counts panic, short reads occur only at EOF |
| `stdin-eof?` | `→ bool` | Report whether the most recent stdin read hit EOF before a full line/requested byte count |
| `flush-stdout` | `→ unit` | Flush stdout where the target has buffered stdout; panics on flush error |
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
| `tl_region_mark` | Return the current allocator region mark, or `0` before allocation |
| `tl_region_reset` | Restore a region mark; mark `0` clears all current arenas |
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

TypeLisp currently has no source-level reference, borrow, lifetime, move-only,
destructor, `drop`, `free`, or garbage-collector model. The implementation uses
pointer-sized handles for several aggregate values, but those handles are not
checked references in the source language. Future ownership/borrowing work is a
separate design track.

### 7.1 Stack

- Function parameters and local variables are allocated in RBP-relative stack slots.
- Stack grows downward. Frame size is computed at compile time.
- Stack is aligned to 16 bytes at every call site (System V ABI requirement).

### 7.2 Heap

- Dynamic array element buffers and escaping returned aggregates (enums,
  structs, strings, dynamic-array fat values) are heap-allocated.
- Non-escaping aggregate fat/inline storage is usually kept in the current stack frame.
- Allocation goes through `tl_alloc`, a backend-emitted bump allocator.
- There is **no garbage collector** or general `free`.
- Heap allocations are process-lifetime allocations by default: once allocated,
  they remain live until the compiled program exits unless an explicit
  tool-owned region reset discards them.

### 7.3 V1 reclamation direction

Issue #320 chose the near-term reclamation policy. The current
process-lifetime arena remains the default because it is simple, deterministic,
and correct for one-shot compiled programs. It covers all current heap
allocation kinds: fresh string storage from `substring`, `string-append`,
`read-file`, `arg`, and `int->string`; dynamic array element buffers and fat
values; returned enum and struct storage; and self-hosted data structures built
from those primitives. Future closures are expected to allocate in the same
heap until a more precise model exists.

General per-object `free`, destructors, move-only ownership, and borrowed
references are not part of this v1 policy. Aggregate handles are freely copied
today, and dynamic arrays are shared mutable buffers, so adding arbitrary
`free` before ownership/reference semantics would make double-free and
use-after-free errors expressible. Ownership, borrowing, and reference work is a
separate design track (#25, #182).

A tracing garbage collector is also not the first reclamation step. It would
need object metadata, root discovery or stack maps, runtime scanning policy, and
coverage across every aggregate allocation shape. That may be revisited later,
but it is larger than the immediate need for long-running tools.

The first reclamation mechanism is explicit region reset at tool-owned phase
boundaries (#418, #419). TypeLisp provides two surfaces for this:

#### Source-level scoped region (v1) — `with-region`

The `(with-region ident body ...)` form (§5.16) gives programs a lexically
scoped, type-safe region. The typechecker ensures no region-tagged value
escapes the body, so the lowering can safely insert `tl_region_mark` at entry
and `tl_region_reset` at exit without risk of use-after-free. This is the
preferred v1 surface for long-running tools that want deterministic, safe
reclamation between phases.

```lisp test=check name=with-region-example
(define (process-phase [input : String]) : i64
  (with-region phase
    (let
      [buf : (Array i64) (make-array i64 100)]
      (begin
        (array-set! buf 0 42)
        (array-ref buf 0)))))
```

Allocation sites inside a `with-region` scope target the active region:
- String operations that create fresh storage (`substring`, `string-append`,
  `string-concat`, `read-file`, `int->string`, `arg`), `make-array`, and
  returned aggregate storage from calls inside the region.
- The body result must be region-free (scalars, or aggregates allocated *before*
  the `with-region`).

The arena-model terminology calls the default allocation target the
program-lifetime arena and calls each nested `with-region` body a scoped arena.
The current source spelling remains `(with-region ...)`; issue #801 tracks the
planned `(with-arena ...)` spelling/alias. Unless a function explicitly says
otherwise, allocation always uses the active arena: the innermost scoped arena,
or the default program-lifetime arena when no scoped arena is active.

#### Standard library and builtin allocation policy

Current stdlib signatures cannot write arena lifetimes yet (#802), so the
checker conservatively treats aggregate results from calls inside a scoped
arena as tagged with that arena. This is stricter than the future model for
functions that may return caller-owned data, but it prevents active-arena
values from escaping until explicit lifetime signatures exist.

| Category | Members | Arena behavior |
|----------|---------|----------------|
| Non-allocating inspection | `length`/`array-length` on arrays, `length`/`string-length`, `string-ref`/`char-at`, `string-eq`/`string=?`, `string->int`, stdlib string predicates such as `string-contains` | Reads caller-provided handles and returns scalars. |
| Returns active-arena owned data | `make-array`, `arg`, `read-file`, `read-stdin-line`, `read-stdin-bytes`, `string-append`/`string-concat`, `substring`/`string-slice`, `int->string`, stdlib trimming/replacement helpers when they build a new string | Fresh storage is allocated in the active arena and cannot escape a scoped arena. |
| Returns caller-provided data | `stdlib/string.tl` `string-replace` when no match is found; `stdlib/io.tl` `read-file-or` when the path is missing | The current type system cannot express this borrowed/caller-owned distinction, so calls inside a scoped arena are still treated conservatively as arena-tagged aggregate results. |
| Mutates caller-provided storage | `array-set!` | Mutates the array buffer named by the caller; it does not allocate. Region checks reject storing shorter-lived aggregate handles into longer-lived containers. |
| Host/runtime IO | `print*`, `panic`/`error`, `flush-stdout`, `write-file`, `file-exists?`, stdlib IO helpers | Performs target IO; any temporary strings used by the helper allocate in the active arena. |

No current stdlib function returns a borrow-typed `str`, because owned
`String`/borrowed `str` is still tracked by #807. No current stdlib function
manually resets arenas; safe scoped cleanup is owned by `with-region`/the
future `with-arena` form, while raw `tl_region_mark` and `tl_region_reset`
remain low-level unsafe-by-convention helpers.

Nested `with-region` forms create independent subregions whose values do not
mix. Inner-region values cannot escape to the outer region; outer-region values
can be used inside the inner region without restriction (they carry the outer
tag, not the inner one).

On non-Linux targets `with-region` still type-checks and scopes but does not
reclaim, matching the semantic contract minus the reset.

#### Low-level extern helpers (unsafe by convention)

Programs that need manual control may still declare the raw backend externs:

```lisp test=check name=region-extern-helpers
(extern tl_region_mark : (-> u64))
(extern tl_region_reset : (-> u64 unit))
```

`tl_region_mark` returns the current arena bump pointer, or `0` if no arena has
been allocated. `tl_region_reset` restores a nonzero mark by discarding newer
arenas and moving the marked arena's bump pointer back to the mark. Passing mark
`0` discards all current arenas and returns allocation to lazy initialization.
An invalid nonzero mark traps with exit status 134.
The region helpers are currently emitted only for the Linux x86_64 System V
target; unsupported targets reject programs that reference them.

A region reset mark invalidates every heap handle allocated after that mark, so
it is only valid when the caller can prove those values are dead, such as after a
compiler, formatter, package-tooling, or REPL iteration has discarded all
phase-local results. It is not a safe arbitrary source-level `free`
replacement.

### 7.4 Globals

- Stored in the `.data` or `.rodata` section.
- Mutable globals use `.data` with an initializer.
- String literal bytes are stored in `.rodata`; a `String` value points to
  inline `{ptr,len}` storage whose `ptr` field points into `.rodata`.

### 7.5 Aggregate handles and aliasing

- Passing or assigning an aggregate value copies the value handle, not the
  pointed-to storage. This applies to `String`, dynamic-array, enum, and struct
  values in the current IR/ABI.
- `String` values are immutable at the source level. String literals may share
  `.rodata`; `substring`, `string-slice`, `string-append`, `string-concat`,
  `read-file`, `arg`, and `int->string` return fresh heap-allocated string
  storage. There is no source operation that mutates a string's bytes.
- Dynamic arrays are shared mutable heap buffers. Copying or passing an
  `(Array T)` value aliases the same `{ptr,len}` record and element buffer, so
  `array-set!` through one handle is observable through another.
- Struct and enum values are pointer-sized aggregate handles internally.
  Structs are read-only at the source level today because `struct-set!` is not
  implemented. Enum payloads are read by `match`; there is no enum mutation
  operation.
- Function calls pass aggregate handles by value. Returning an aggregate may
  heap-promote storage that would otherwise be frame-local; this is storage
  placement for safety, not ownership transfer or borrow checking.

```lisp test=run name=dynamic-array-aliasing exit=42 stdout=""
(define (main) : i64
  (let
    [a : (Array i64) (make-array i64 1)]
    (let
      [b : (Array i64) a]
      (begin
        (array-set! a 0 42)
        (array-ref b 0)))))
```

---

## 8. Backend capabilities and limitations

### 8.1 What works

- Full integer arithmetic (i64, i32, i16, i8, u64, u32, u16, u8) with correct-width instruction selection.
- `f64` arithmetic and comparisons via SSE2.
- Booleans, characters, unit.
- Control flow: `if`, `while`, `begin`.
- Direct and indirect function calls.
- Non-capturing lambda literals as raw function pointer values.
- Capturing lambda literals with heap closure environments; captures may be
  scalars, function values, `String`, and dynamic arrays.
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
  `file-exists?`, `read-stdin-line`, `read-stdin-bytes`, `stdin-eof?`,
  `flush-stdout`.
- Low-level extern-only allocator region helpers: `tl_region_mark`,
  `tl_region_reset`.
- `extern` declarations.
- Multi-file modules via `import`.
- Native x86_64 executable targets: `linux-x86_64` by default, and
  `windows-x86_64` for Windows x64 ABI output with CRT-linked runtime helpers.
- Builtin `print`, `print-bool`, `print-float`, `print-char`,
  `print-newline`, `print-string`/`print-str`, `print-error`,
  `string-append`/`string-concat`, `read-file`, `write-file`, `file-exists?`,
  `read-stdin-line`, `read-stdin-bytes`, `stdin-eof?`, `flush-stdout`,
  `panic`/`error`.

### 8.2 What does NOT work (yet)

| Feature | Status |
|---------|--------|
| `f32` type | Rejected by backend validation |
| `f32` local/parameter type | Rejected by backend validation |
| Floating-point casts in `(cast ...)` | Not implemented; casts currently support integer/char conversions only |
| Tuple by-value ABI | Function parameters/returns rejected by backend validation |
| Fixed-array by-value return | Rejected by backend validation |
| Tuple/Struct/Enum/String globals | Rejected by backend validation |
| Aggregate-element / nested fixed-array captures in lambdas | Not implemented (scalars, String, dynamic-array, recursively-nested tuple/struct/enum, and top-level scalar fixed-array captures work; tracked in #435/#571) |
| Mutable captures (`set!` to captured names) in lambdas | Not implemented |
| Tail call optimization | Not implemented |
| `struct-set!` | Not implemented |
| Garbage collection / general `free` | Not implemented; allocation is process-lifetime by default with unsafe explicit region reset for tool-owned phase boundaries |
| SPMD / SIMD `foreach` | Scalar reference lowering implemented; AVX2 supports a first contiguous map/zip subset |
| SPMD reductions and public cross-lane ops | Source semantics specified; parser/typechecker/lowering/backend support pending |
| Windows region helpers | `tl_region_mark`/`tl_region_reset` are Linux-only |
| Complete source locations for all semantic errors | Partial |
| REPL evaluation | Minimal stdio command loop exists; form evaluation is not implemented |
| Package manager | Not implemented |
| LSP / IDE support | Stdio diagnostics server implemented; richer IDE features pending |

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

Comptime-generated concrete `Option`/`Result` families and implementation
bundles are tracked by #893/#913/#483. `?`-style propagation and richer
diagnostic payload policy remain separate language design work.

---

## 10. CLI

```
typelisp <command> [file.tl] [options]

Commands:
  debug tokenize    Print token stream
  debug parse       Print AST
  debug check       Run type checker
  repl              Minimal stdio command loop
  compile           Generate assembly (.s)
  build <file.tl>   Compile, assemble, and link a native executable
  run               Compile, assemble, link, and run binary
  build             Build nearest typelisp.pkg to package assembly
  test              Run inline `(test ...)` items

Options:
  compile -o <file>       Write assembly to the given path
  compile --emit-ir       Write the lowered and optimized IR instead of assembly
  compile --target <target>
  run --target <target>
  build --target <target>
  test --target <target>
                          Select linux-x86_64 or windows-x86_64;
                          linux-x86_64 is the default output target, while
                          test defaults to the host target
  compile --backend-mode <mode>
  run --backend-mode <mode>
  build --backend-mode <mode>
                          Select scalar, avx2, or avx512 backend mode;
                          scalar is the only implemented mode
  test --check <file.tl>
                          Type-check the generated inline test harness without
                          assembling or running it
  build <file.tl> -o <exe>
                          Write the native executable to the given path
  build --manifest-path <file>
                          Use an explicit package manifest path
```

For source-file builds, the default executable path is the source path with the
`.tl` extension removed on Linux and with `.exe` on Windows. Source-file
`build` does not run the executable. The package build form continues to write
deterministic package assembly rather than native executables.

Linux native build/run uses `as` and `ld`. Windows native build/run uses
`clang --target=x86_64-pc-windows-msvc` and `lld-link`, links against the CRT,
and emits a console `.exe`.

`tokenize`, `parse`, and `check` are also accepted as top-level compatibility
aliases for the corresponding `debug` commands.

`repl` currently supports `.help`, `.type <expr>`, and `.exit`. Top-level
declarations are remembered for later `.type` commands. `.type` parses and
typechecks the expression against the current session and prints the inferred
type without compiling or running native code. Form evaluation is reserved for
later work.

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

### 11.2 Calling convention (Windows x64)

| Argument index | Integer register | Float register |
|----------------|------------------|----------------|
| 1st | `%rcx` | `%xmm0` |
| 2nd | `%rdx` | `%xmm1` |
| 3rd | `%r8` | `%xmm2` |
| 4th | `%r9` | `%xmm3` |
| 5th+ | Stack after 32-byte shadow space | Stack after 32-byte shadow space |

- Integer and float arguments share the four register slots.
- Return value: `%rax` (integer), `%xmm0` (float).
- Callers reserve 32 bytes of shadow space before each call.
- The CRT owns process startup; Windows output emits `main` and no Linux
  `_start` wrapper.

### 11.3 Data layout

Default TypeLisp layout is the compiler's internal representation. It is stable
enough for TypeLisp code generation, but it is not the C FFI contract. Use
`repr c` only when a struct must be shared with external ABI code.

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

For `repr c` structs, field layout follows section 3.4.3 instead of the
aggregate-handle rule. A by-value nested `repr c` struct contributes its C
layout size and alignment, not a TypeLisp pointer-sized handle. Unsupported
fields are rejected before lowering.

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
  (let
    [p : Point (Point 3 4)]
    (+ (struct-get p x) (struct-get p y))))  ; returns 7
```

### Dynamic array

```lisp test=run name=dynamic-array exit=30 stdout=""
(define (main) : i64
  (let
    [arr : (Array i64) (make-array i64 5)]
    (begin
      (array-set! arr 0 10)
      (array-set! arr 1 20)
      (+ (array-ref arr 0) (array-ref arr 1)))))  ; returns 30
```

### String operations

```lisp test=run name=string-length exit=5 stdout=""
(define (main) : i64
  (let
    [s : String "hello"]
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
                | module-decl
                | import-decl
                | export-decl
                | defenum
                | defstruct
                | test-decl

define-var    ::= "(" "define" ident [":" type] expr ")"
define-func   ::= "(" "define" "(" ident param* ")" [":" type] expr ")"
extern-decl   ::= "(" "extern" ident ":" type ")"
module-decl   ::= "(" "module" module-ident ")"
import-decl   ::= "(" "import" string [":as" ident] ")"
export-decl   ::= "(" "export" export-item+ ")"
export-item   ::= "(" "value" ident ")"
                | "(" "type" ident ")"
                | "(" "constructor" ident ")"
                | "(" "field" ident ident ")"
                | "(" "variant" ident ")"
defenum       ::= "(" "defenum" ident variant+ ")"
defstruct     ::= "(" "defstruct" ident struct-meta* field+ ")"
struct-meta   ::= "(" ":repr" "c" ")"
test-decl     ::= "(" "test" ident expr+ ")"

param         ::= "[" ident ":" type "]"
field         ::= "(" ident type ")"
variant       ::= "(" ident type* ")"

expr          ::= literal
                | ident
                | "(" "if" expr expr expr ")"
                | "(" "cond" cond-arm+ ")"
                | "(" "let" binding+ expr ")"
                | "(" "while" expr expr ")"
                | "(" "begin" expr+ ")"
                | "(" "set!" ident expr ")"
                | "(" "ann" expr ":" type ")"
                | "(" "cast" expr ":" type ")"
                | "(" "match" expr match-arm+ ")"
                | "(" "foreach" foreach-clause expr ")"
                | "(" "spmd-reduce" reduce-op foreach-clause expr expr ")"
                | "(" "lambda" "(" param* ")" [":" type] expr ")"
                | "(" "with-region" ident expr+ ")"
                | "(" "comptime" expr ")"
                | "(" "type" type ")"
                | "(" "size-of" expr ")"
                | "(" "align-of" expr ")"
                | "(" "offset-of" expr ident ")"
                | "(" expr expr* ")"          ; function call

binding       ::= "[" ident [":" type] expr "]"
foreach-clause ::= "(" "[" ident ":" type expr expr "]" ")"
reduce-op     ::= "sum" | "min" | "max" | "all" | "any"
cond-arm      ::= "[" expr expr "]"
                | "[" "else" expr "]"         ; required final arm
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
                | "(" "in" ident type ")"              ; region-tagged (v1)
                | ident                                ; enum or struct name

module-ident  ::= ident ("/" ident)*
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
