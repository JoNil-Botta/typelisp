# TypeLisp Language Specification

> **Version:** 0.1.0-dev  
> **Target:** x86_64 Linux (System V AMD64 ABI)  
> **Constraint:** Rust `std` only — zero third-party dependencies.

This document specifies the TypeLisp language as implemented today. It is the ground truth for what compiles, what types mean, and what the backend promises.

---

## 1. Overview

TypeLisp is a statically typed Lisp/Scheme dialect that compiles to native x86_64 assembly. Every expression has a known type at compile time. There is no runtime type tagging, no garbage collector, and no interpreter.

### Safe code: no undefined behavior

Safe TypeLisp programs do not have undefined behavior. A conforming compiler
and runtime must handle every accepted safe-code operation with exactly one of
these outcomes:

- **Static reject:** the program is rejected before lowering/code generation.
- **Deterministic runtime trap:** the program aborts through a documented
  runtime trap path instead of continuing with an invalid value or invalid
  memory access.
- **Defined result:** the operation produces the specified value, including
  specified wrapping behavior where the language says arithmetic wraps.

Safe code is source outside an `(unsafe ...)` context and outside helpers
documented as unsafe by convention. An unsafe context does not disable ordinary
type checking; it only moves responsibility for raw-pointer, foreign-ABI, and
manual resource-reset invariants to the programmer. Optimizations may rely on
the static type, move, borrow, and region facts below, but must not reinterpret
accepted safe code as having behavior outside this table.

| Safety area | Safe-code outcome | Binding rule and owner |
|-------------|-------------------|------------------------|
| Integer `+`, `-`, `*`, and `neg` overflow | Defined wrap | Wrap modulo 2^N for the result type width; signed results interpret the wrapped bits as two's-complement values. See section 5.4 and #1101. |
| Integer `/` and `%` invalid operands | Deterministic runtime trap | Divisor zero and signed minimum divided/remaindered by `-1` trap through the integer division/remainder abort path. See section 5.4 and #1101. |
| Integer shift counts | Deterministic runtime trap | `shl`/`shr` trap when the count is negative or not less than the left operand's bit width. See section 5.4. |
| Scalar numeric casts | Defined result | Integer/integer, integer/`char`, `f64` ↔ `f32`, and integer/`char` ↔ float casts use defined truncation, sign/zero-extension, and round-to-nearest/truncate-toward-zero rules. See section 3.8 and #1101. |
| Non-numeric casts | Static reject | Casts touching non-numeric types are rejected before lowering. See section 3.8 and #1101. |
| Array, string, slice, and generated collection bounds | Deterministic runtime trap | Out-of-bounds indexing, invalid slice ranges, negative dynamic-array lengths, and allocation byte-count overflow trap through the bounds-check abort path. SPMD inactive tail lanes do not perform bounds checks or memory accesses. See sections 5.15 and 6.1. |
| Initialized-before-use and no use-after-move | Static reject | Safe code cannot read an uninitialized place or a place whose move-only value has been moved. Move-only aggregate semantics are specified in section 4.6.2 and #1046; enforcement is tracked by #1048 and #805. |
| Borrow/reference validity and arena escape | Static reject | Safe references and region-tagged aggregate handles cannot outlive their lifetime/arena, be returned or stored into a longer-lived slot, or be captured by an escaping closure. Current region-tagged escape checks are in sections 3.9, 5.16, and 7.3; immutable borrow rules are owned by #1033/#1034/#1035. |
| Mutation through shared references | Static reject | Safe code cannot write through an immutable/shared reference. Mutable-reference writes require exclusive access; that checker work is owned by #806. Current aggregate-handle mutation is governed by the move-only and aliasing rules in sections 4.6.2 and 7.6. |
| SPMD safe-code data-race freedom | Static reject | Safe `foreach`/SPMD code rejects varying calls, unsupported varying control flow, unsafe shared mutation, and reduction shapes that cannot be proven race-free by the SPMD rules. See section 5.15 and #937/#1012. |
| Invalid enum/struct states | Static reject | Safe code constructs enums and structs only through their checked constructors and pattern forms. Arbitrary bit construction, invalid variants, invalid field layouts, packed-field access, and recursive-by-value `repr c` states are rejected. See sections 3.5, 4.6, and 5.13. |
| Raw pointer dereference/write/arithmetic/casts, foreign ABI assumptions, and manual arena reset | Static reject | Safe code may pass, return, compare, and null-test raw pointer values as specified, but dereference, write, offset, pointer/integer cast, foreign ABI invariants beyond the declared signature, and invalidating manual arena operations require `(unsafe ...)`. See sections 3.4, 5.19, 7.3, and 7.4; design/implementation owners are #954, #809, #812, #1052, #1054, and #1055. |
| Invalid comptime-to-runtime values | Static reject | Comptime generation and reflection cannot smuggle invalid runtime values, invalid types, or unstable compiler-internal identities into safe runtime code. Runtime observation of comptime-only metadata is rejected. See sections 3.7 and 5.17; reflection surface owner is #970. |
| Valid comptime-generated runtime values | Defined result | Accepted generated declarations and values have ordinary valid runtime representations and follow the same safe-code contract as hand-written declarations. See sections 3.7 and 5.17; reflection surface owner is #970. |

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

- `;#` starts a module/file documentation line.
- `;:` starts an outer item documentation line attached to the next supported
  top-level item: value `define`, function `define`, `extern`, `defenum`, or
  `defstruct`.
- `;#` and `;:` are the only public documentation comment syntaxes.
- `;` and `;;` remain ordinary comments and are not public documentation.
- Outer item doc lines must be contiguous. A blank line, ordinary comment,
  module doc, unsupported top-level form, or unrelated source text clears the
  pending item doc block. A pending block at EOF is ignored.

Documentation tests are fenced examples inside those public documentation
comments. `typelisp doc --test <file.tl>` recognizes Markdown code fences whose
info string starts with `typelisp` or `tl`, extracts them from `;#` module docs
and attached `;:` item docs, and checks each example as a standalone TypeLisp
source file. An example passes when it parses, resolves imports, and type-checks.
Adding `expect-error` after the language tag inverts the expectation so the
example must fail during loading, parsing, or type checking. `run` is a reserved
doctest option for runnable examples and is mutually exclusive with
`expect-error`. A runnable fence must include `;; doctest-exit: <integer>` in
the example body and may include `;; doctest-stdout: -` / `;; doctest-stderr: -`
or `literal:<escaped text>` with `\n`, `\t`, `\r`, and `\\` escapes. Runnable
metadata is parsed and retained by the selfhost doctest model; execution is a
follow-up. Other fence languages are ignored; unknown TypeLisp fence options,
empty TypeLisp examples, and unterminated TypeLisp fences are malformed
doctests.

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
| `f32` | 4 bytes | IEEE-754 single precision |
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

**Owned string:** `String`
- `String` is an owned, immutable byte-string handle. The handle is a
  pointer-sized aggregate value whose pointed-to inline storage is a
  `{data_ptr, length}` pair.
- String literals have type `String` in v1. Their bytes live in static
  read-only data, but the source value is still an owned `String` handle, not a
  borrowed `str`.
- Runtime-created strings from `string-append`, `substring`, `read-file`,
  `arg`, `int->string`, stdin/file reads, and stdlib helpers allocate fresh
  `String` storage in the active arena.
- `String` is move-only under the aggregate handle rules in section 4.6.2.
  Non-consuming string operations are borrow-like compatibility operations
  until the borrowed `str` API migration lands.

**Borrowed string referent:** `str` (specified, selfhost pending)
- `str` is an immutable borrowed byte-string referent. It is not a first-class
  value type in v1.
- Bare `str` is rejected in value positions: parameters, returns, locals,
  globals, fields, enum payloads, tuple elements, and array element types.
- The only accepted source form for borrowed text in v1 is an immutable
  reference `(& lifetime str)`. Mutable string references `(&mut lifetime str)`
  are reserved and rejected until mutable byte-buffer policy exists.
- `str` is not NUL-terminated. Its length is carried with the borrowed view.

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

### 3.4 Raw pointer types (v1 design; implemented)

Raw pointer syntax is implemented for the v1 FFI/low-level memory surface. The
design is intentionally separate from safe references and borrowing (#182): raw
pointers are explicit unsafe values, not checked references.

```lisp test=ignore name=raw-pointer-type-template reason="requires the selfhost raw-pointer checker path"
(extern read-byte : (-> (Ptr u8) u8))
(extern write-byte : (-> (MutPtr u8) u8 unit))
```

Type forms:

- `(Ptr T)` is a raw pointer to a value of type `T` that may be read through
  unsafe operations but may not be written through source-level pointer write
  operations.
- `(MutPtr T)` is a raw pointer to mutable storage for a value of type `T`;
  unsafe reads and writes are allowed.
- `Ptr`/`MutPtr` are source-level types, not ownership or lifetime types. They
  carry no borrow, aliasing, provenance, bounds, initialization, alignment, or
  non-null guarantee.
- Raw pointer values are pointer-sized, nullable, freely copyable ABI values.
  Copying a pointer copies only the address.
- There is no implicit conversion between `Ptr` and `MutPtr` in v1. Use the
  explicit unsafe `ptr-cast` operation.
- `T` may be any backend ABI value type that can be loaded or stored as a
  value. Tuple and fixed-array by-value ABI limitations still apply.

Safe code may mention raw pointer types, bind/copy/pass/return raw pointer
values, call `extern` functions whose signatures contain raw pointers, construct
typed null pointers, and test pointers for null. Safe code may not dereference,
write through, offset, or cast raw pointers.

#### 3.4.1 Arena-owned `(Box T)` indirection (specified, pending implementation)

`(Box T)` is an explicit, safe, arena-owned indirection type. A box value is a
pointer-shaped owning handle to storage that contains one `T`, allocated in the
active arena. It is the source-level escape hatch for recursive aggregate
layouts once structs and enums can opt into Rust-like inline representation.

`(Box T)` is distinct from every other pointer-like surface:

- `(Ptr T)` / `(MutPtr T)` are unsafe, nullable, copyable raw addresses for
  FFI/runtime work. They do not own the pointed-to value.
- `(& r T)` / `(&mut r T)` are non-owning checked references tied to an owner
  lifetime or arena.
- `(Box T)` owns the allocated `T` value. The box handle is move-only, not
  copyable, and its storage is reclaimed only with the arena that owns it.

Box type syntax is a built-in type constructor like `(Array T)`, `(Tuple ...)`,
and raw pointer types. It is not source-level generics. The parser must reject
malformed box types such as `(Box)`, `(Box A B)`, and `(Box T extra)` with a
source-located type diagnostic.

`(box expr)` allocates storage for the value produced by `expr` in the active
arena and returns `(Box T)`, where `T` is the type of `expr`. In the
program-lifetime default arena the result type is `(Box T)`. Inside
`(with-arena r ...)`, allocation targets `r` and the result type is
`(in r (Box T))`; it follows the same region escape rules as other
arena-owned handles.

`(box-get b)` projects the boxed value for read and pattern use. If `b` has
type `(Box T)`, the projection has type `T`. If `b` has type `(in r (Box T))`,
the projection has type `(in r T)` when `T` is region-taggable, otherwise `T`.
The projection does not copy the box handle and does not by itself consume the
box. Subsequent use of the projected value is still governed by the move rules:
copyable `T` values may be copied out, but moving a move-only `T` out of a box
is an aggregate path move and is rejected until the path-move and borrow slices
define a sound operation. Immutable inspection through `box-get` is therefore
v1's stable surface; destructive `box-take`, assignment through boxes, and
mutable dereference are deferred to the mutable-reference/path-move work.

Examples:

```lisp test=ignore name=box-recursive-list reason="Box is specified before selfhost implementation"
(defenum ListI64
  (ListNil)
  (ListCons i64 (Box ListI64)))

(define one-two : ListI64
  (ListCons 1 (box (ListCons 2 (box ListNil)))))
```

```lisp test=ignore name=box-recursive-tree reason="Box is specified before selfhost implementation"
(defenum Tree
  (Leaf i64)
  (Node (Box Tree) (Box Tree)))

(define small-tree : Tree
  (Node (box (Leaf 1)) (box (Leaf 2))))
```

```lisp test=ignore name=box-get-copyable-field reason="Box is specified before selfhost implementation"
(defstruct Counter
  (label String)
  (count i64))

(define (boxed-count [c : (Box Counter)]) : i64
  (struct-get (box-get c) count))
```

### 3.5 User-defined types

#### 3.5.1 Enums (sum types)

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

#### 3.5.2 Structs (product types)

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

#### 3.5.3 C-compatible `repr c` structs (specified, selfhost pending)

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

For layout, v1 accepts only the metadata form `(:repr c)`. Omitting it
preserves the default TypeLisp layout. Metadata forms must appear before all
fields; a metadata form after a field is rejected. Duplicate `:repr` metadata
is rejected. Unknown metadata keys and unknown representation names are
rejected. Cleanup ownership metadata is specified separately in section 4.6 and
is not a layout contract. `packed`, `(:repr packed)`, and equivalent
packed-layout spellings are reserved and rejected until an unsafe packed-field
slice exists.

V1 `repr c` fields are restricted to ABI-safe types:

- Fixed-width scalar types supported by the backend: `i8`, `u8`, `i16`, `u16`,
  `i32`, `u32`, `i64`, `u64`, `f64`, `f32`, `bool`, and `char`.
- Raw pointer types once the raw-pointer surface is implemented (#809/#896).
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

### 3.6 Type aliases

There are no explicit type aliases. Identifiers naming enums or structs are resolved to their nominal types during type checking.

### 3.7 Abstraction policy: comptime generation, not generics/traits

TypeLisp does not plan Rust-style source-level generics, traits, interfaces,
`impl` blocks, or generic type constructors such as `Option<T>` and
`Result<T,E>`. Generic-looking top-level forms are reserved only to produce a
diagnostic that points users at comptime-generated concrete declarations.

Reusable abstractions should be built by compile-time code that inspects type
values and emits concrete `defstruct`, `defenum`, `define`, and related
implementation declarations. The current implementation path is tracked by
#893 (concrete type and implementation bundles), #913 (type reflection
primitives), and #902 (generated concrete Option/Result families). Historical
generic/type-constructor work in #483 is superseded by this comptime-generation
chain.

Until that path is complete, write explicit monomorphic declarations such as
`MaybeI64`, `ResultStringI64`, or domain-specific structs/enums.

#### 3.7.1 Typed expression macros (v1 design)

V1 macros are compile-time expression transformers. They are declared with
`defmacro`, checked through a function-type-like `macro` type, and expanded
before ordinary runtime typechecking and lowering. A macro is not a runtime
value and cannot be stored in variables, passed to functions, placed in fields,
or called indirectly.

Macro signatures use ordinary produced types. The operands received by the
macro body are unevaluated code fragments of the single compiler-provided
`Expr` type, but each operand slot in the signature states the ordinary type
that the operand expression must produce at the call site. For example, a macro
with type `(macro (bool bool) bool)` takes two operand expressions that must
each typecheck as `bool` and produces an expression that must typecheck as
`bool`. A final slot may be variadic, written `T ...`; the macro body receives
those remaining operands as an `ExprList`.

`Expr` and `ExprList` are compile-time-only types. They are valid in macro
bodies and explicit `(comptime ...)` helper code, but they have no runtime
representation. The compiler tracks the checked produced type of each `Expr`
internally; there is no source-level `Expr<T>` and no generic macro type
parameter.

Macro bodies build expression values with quote forms. The reader accepts both
prefix shorthand and the equivalent list-headed forms:

```lisp test=ignore name=macro-quote-surface reason="typed macro expansion is staged across #1133-#1140"
'form        ; (quote form)
`form        ; (quasiquote form)
,expr        ; (unquote expr), valid inside quasiquote
,@expr       ; (unquote-splicing expr), valid in quasiquote list positions
```

`quote` produces an `Expr` for the template without evaluating it.
`quasiquote` produces an `Expr` while evaluating `unquote` operands as
compile-time `Expr` values and inserting their checked AST. `unquote-splicing`
evaluates to an `ExprList` and splices that list into the surrounding template
list. `unquote` and `unquote-splicing` outside quasiquote are rejected.

The source surface is:

```lisp test=ignore name=macro-defmacro-surface reason="typed macro declarations are specified before selfhost implementation"
(defmacro (and2 [lhs : bool] [rhs : bool]) : bool
  (expr-if lhs rhs (expr-bool false)))

(defmacro (all [first : bool] [rest : bool ...]) : bool
  ;; `first` is an Expr; `rest` is an ExprList.
  (fold-bool-and first rest))
```

The canonical binding types for those declarations are `(macro (bool bool)
bool)` and `(macro (bool bool ...) bool)`. The `defmacro` operand list names
the macro body's compile-time parameters and their call-site produced types.
Fixed operands bind as `Expr`; a variadic final operand binds as `ExprList`.
The macro body must typecheck as `Expr`, and the produced fragment must
post-expand typecheck as the declared result type.

Typed expansion has three checks:

1. The macro call site is checked from the macro signature before expansion.
   Operand type errors are reported at the operand source span.
2. The macro body is checked as compile-time TypeLisp over `Expr`/`ExprList`.
3. The expanded expression is checked again by the ordinary typechecker as a
   safety net; failures are compiler or macro diagnostics with expansion spans.

Expansion runs after parsing/import loading and before runtime typechecking.
The expander resolves a list head in the macro namespace first; if no macro is
found, the form is left for ordinary value-call checking. A module may not
declare a local value/function and a local macro with the same unqualified name
in v1. Hygiene and binding-introducing macros are not part of v1; the initial
stdlib macros (`and`, `or`, `when`, `unless`, and `cond`) must expand without
introducing new user-visible bindings.

### 3.8 Type conversions (casts)

```lisp test=ignore name=cast-placeholder reason=placeholder
(cast expr : target_type)
```

- Narrowing keeps the low N bits, where N is the target width. The resulting
  bits are interpreted using the target type's signedness.
- Widening sign-extends signed integer sources and zero-extends unsigned
  integer sources.
- `char` → integer: zero-extends the byte value.
- Integer → `char`: truncates to the low byte.
- `f64` ↔ `f32`: precision conversions (`f64` → `f32` rounds to binary32,
  `f32` → `f64` widens exactly).
- Integer/`char` → float: produces the nearest representable float (the source
  is treated as a signed value).
- Float → integer/`char`: truncates toward zero, then keeps the low N bits of
  the target width. The runtime result of converting a float outside the target
  range is unspecified but defined (it does not trap or invoke UB).
- Casts are defined across the full scalar numeric matrix (integers, `char`,
  `f32`, `f64`); casts touching non-numeric types are statically rejected.
- No implicit conversions.

### 3.9 Region-tagged types (v1)

A value allocated inside a `(with-arena r ...)` scope carries a **region tag**
in its type, written `(in r T)` where `r` is the region name and `T` is the
underlying heap-allocated type. Region tags are a compile-time-only
annotation; they do not change ABI representation, runtime size, or data
layout. The tag exists solely to enable static escape checking.

`(with-arena r ...)` creates the scoped arena, produces `(in r T)` region tags
for allocations inside the body, shadows the program-lifetime default arena,
and lowers to `tl_region_mark` / `tl_region_reset` around the body.

**Region-taggable types** are the heap-allocated aggregate kinds whose storage
can be created inside a region scope:
- `String`
- `(Box T)` - arena-owned boxed storage
- `(Array T)` — dynamic array
- Enum and struct values returned from functions inside the region
- Tuple values (when tuple-by-value ABI support lands)

Scalars (`i64`, `bool`, `char`, `f64`, etc.), function values, and fixed-size
arrays are **not** region-tagged because they do not allocate through `tl_alloc`.

A region-tagged type `(in r T)` is a **subtype** of the plain type `T` for
operations that do not escape the region: field access, `array-ref`,
`array-set!`, `match` arms, `print-string`, and function calls whose parameter
types accept `T`. It is **not** a subtype where the value would leave the
region's scope: as the result of the `with-arena` form, stored into an outer
`let` or global, captured by an escaping closure, or returned from an enclosing
function.

**v1 confinement rule:** Region-tagged values do not cross function boundaries.
A function parameter or return type is written without a region tag; passing a
region-tagged value to a function or returning it from one is an escape error.
Region-polymorphic functions (`(forall (r) ...)`) are deferred to a follow-up
slice; every function type in v1 is region-agnostic and therefore cannot
accept or produce region-tagged handles.

### 3.10 Reference types and immutable borrow expressions (v1 design)

The selfhost compiler accepts written lifetime-bearing reference type forms:

```lisp test=ignore name=reference-type-syntax reason=syntax-only
(& arena T)
(&mut arena T)
```

- `(& arena T)` is an immutable reference type to `T` tied to lifetime/arena
  name `arena`.
- `(&mut arena T)` is a mutable reference type to `T` tied to lifetime/arena
  name `arena`.
- The lifetime name is a bare identifier. It matches the current
  `(with-arena arena ...)` binder shape.
- Immutable references are copyable pointer/provenance values. Copying an
  immutable reference aliases the same immutable referent and does not move or
  copy the referent.
- Mutable reference expression syntax, mutable exclusivity, returned/stored
  lifetime parameters, closure-capture details, and non-lexical lifetimes are
  follow-up borrow-checker work. Borrowed `str` source semantics are specified
  in section 3.11. Source programs using reference types are rejected before
  lowering until the selfhost borrow-checker slices land.

Immutable borrow expressions are specified as:

```lisp test=ignore name=immutable-borrow-expression-syntax reason="borrow expressions are specified before selfhost implementation"
(& place)
(& arena place)
```

- `(& place)` creates an immutable reference and lets the checker infer the
  lifetime/arena name.
- `(& arena place)` creates the same reference but requires the inferred
  lifetime/arena name to be `arena`; otherwise the checker reports a type error.
- Borrow expressions are explicit. There is no implicit conversion from `T` to
  `(& arena T)` in v1.
- The referent type is the place's value type, except that borrowing a `String`
  place produces `(& lifetime str)`. When the place type is an arena-tagged
  wrapper `(in arena T)`, the reference type is `(& arena T)`, not
  `(& arena (in arena T))`; for `(in arena String)`, the reference type is
  `(& arena str)`.

**Borrowable places in lexical v1.** The checker accepts immutable borrows of
places whose owner/provenance is statically known:

- Local bindings and function parameters.
- Aggregate field and element projections rooted in a borrowable place. In a
  borrow expression, forms such as `(struct-get p field)`, `(tuple-ref t 0)`,
  and `(array-ref items i)` are treated as projections, not by-value reads.
- Arena-owned aggregate handles: `String`, dynamic-array, struct, enum, and
  tuple handles allocated in the active arena. Handles with type `(in phase T)`
  infer lifetime `phase`; untagged heap handles allocated in the default
  program-lifetime arena infer the reserved lifetime name `program`.

The checker rejects immutable borrows of arbitrary rvalues and temporaries whose
owner cannot be named. Bind the value first if it should have a lexical owner.

**Lifetime name selection.** For `(& place)`, the checker chooses the reference
lifetime from the owner:

- A local or parameter root named `x` gives references rooted in `x` the
  lifetime name `x`.
- A field, tuple element, fixed-array element, or dynamic-array element
  projection inherits the lifetime name of its root place.
- A region-tagged aggregate `(in phase T)` gives references to its owned storage
  the lifetime name `phase`.
- An untagged default-arena aggregate gives references to its owned storage the
  reserved lifetime name `program`.

For `(& name place)`, `name` must match the inferred lifetime. In function
parameter types, lifetime names are signature-local binders for incoming
references. Multiple parameters using the same name require the same caller
lifetime.

The first #804 stored-reference slice accepts reference lifetimes written
directly in structural container types and nominal aggregate declarations:
fixed arrays such as `(Array (& n i64) 1)`, tuple elements, struct fields, and
enum payloads. Those lifetimes are preserved through array-ref, tuple-ref,
field access, constructors, and match bindings. A nominal constructor result
that stores references carries hidden lifetime facts while it remains local;
passing or returning such a nominal value is rejected until explicit nominal
lifetime-argument syntax lands. Structural return types that expose the
reference lifetime directly, such as `(& n T)`, `(Tuple (& n T))`, and
`(Array (& n T) k)`, may return when the lifetime is tied to an input.

**Lexical v1 lifetime rule.** A borrow created in v1 lives until the end of the
innermost lexical scope that contains the borrow expression. Lexical scopes are
function/lambda bodies, `let` bodies, `with-arena` bodies, resource `with`
bodies, and individual `match` arms; `begin` alone does not shorten the borrow.
The checker does not shorten a borrow at last use. Non-lexical lifetimes are
deferred to #810.

While an immutable borrow is live, later move-only by-value moves, `set!`
assignment to the borrowed place, and mutable borrows/mutations of the same
place are rejected by the relevant move/borrow slices (#806/#1050). Multiple
immutable borrows of the same place are allowed.

**Invalid escapes in v1.** The checker rejects references that would outlive
their owner or arena:

- Returning a reference to a local, parameter stack slot, temporary, or scoped
  arena unless a later #804 lifetime-parameter rule explicitly proves the return
  is tied to an input or arena that outlives the call.
- Assigning or storing a shorter-lived reference into a longer-lived local,
  global, aggregate field, enum payload, tuple element, or array element.
- Capturing a reference in a closure that may escape the reference's lexical
  scope. Detailed closure borrow capture rules are deferred to #808.
- Letting a reference to `(in inner T)` data escape the `with-arena inner`
  body. Outer-arena references may be used inside inner arenas without gaining
  the inner lifetime.

Mutable reference creation and exclusivity are #806. Returned/stored lifetime
parameters are #804. Closure capture detail is #808. Non-lexical lifetime
shortening is #810.

```lisp test=ignore name=borrow-local-param-ok reason="borrow expressions are specified before selfhost implementation"
(define (takes-i64 [x : (& n i64)]) : i64
  0)

(define (borrow-param [n : i64]) : i64
  (let [r (& n)]
    (takes-i64 r)))
```

```lisp test=ignore name=borrow-field-element-ok reason="borrow expressions are specified before selfhost implementation"
(defstruct Pair (left i64) (right i64))

(define (takes-two [x : (& p i64)] [y : (& items i64)]) : i64
  0)

(define (borrow-places [p : Pair] [items : (Array i64)]) : i64
  (let [left (& (struct-get p left))]
    (let [first (& (array-ref items 0))]
      (takes-two left first))))
```

```lisp test=ignore name=borrow-arena-owned-ok reason="borrow expressions are specified before selfhost implementation"
(define (takes-string [s : (& phase str)]) : i64
  0)

(define (borrow-arena-owned) : i64
  (with-arena phase
    (let [s (int->string 42)]
      (let [rs : (& phase str) (& phase s)]
        (takes-string rs)))))
```

```lisp test=ignore name=borrow-reject-return-local reason="negative example for future immutable borrow checker"
(define (bad-return-local [x : i64]) : (& x i64)
  (& x))
```

```lisp test=ignore name=borrow-reject-temporary reason="negative example for future immutable borrow checker"
(define (bad-temporary) : i64
  (let [r (& (int->string 42))]
    0))
```

```lisp test=ignore name=borrow-reject-arena-escape reason="negative example for future immutable borrow checker"
(define (bad-arena-return) : (& phase str)
  (with-arena phase
    (let [s (int->string 42)]
      (& phase s))))
```

```lisp test=ignore name=borrow-reject-closure-capture reason="negative example for future immutable borrow checker"
(define (takes-captured [x : (& n i64)]) : i64
  0)

(define (bad-capture [n : i64]) : (-> i64)
  (let [r (& n)]
    (lambda () (takes-captured r))))
```

### 3.11 Owned `String` and borrowed `str` (v1 design)

This section defines the source contract for the owned `String` / borrowed
`str` split. The syntax and API migration are staged: `String` exists today,
reference syntax exists in the selfhost checker, and `str` frontend/API support
lands through #1453 and #1454. Until those implementation slices land, current
compiler and stdlib signatures still use the compatibility `String` forms in
section 6.1.

#### Source model

- `String` is the owned text value type. It is immutable, move-only, and may
  own active-arena storage or refer to static read-only literal bytes.
- `str` is a borrowed referent type, not a by-value type. A source program may
  write `str` only as the referent of an immutable reference:
  `(& lifetime str)`.
- Bare `str` in a parameter, return, local binding, global, field, enum
  payload, tuple element, or array element position is rejected.
- `(&mut lifetime str)` is reserved and rejected in v1 because strings are
  immutable. Mutable byte buffers should use a future buffer/slice type rather
  than mutable `str`.
- String literals keep type `String`. There is no static-borrowed string
  literal type and no implicit static lifetime in v1.

Borrowing a `String` place produces a borrowed `str` reference:

```lisp test=ignore name=string-borrow-produces-str reason="borrowed str is specified before selfhost implementation"
(define (text-len [text : (& input str)]) : i64
  (string-length text))

(define (borrow-owned-string [input : String]) : i64
  (let [view : (& input str) (& input)]
    (text-len view)))
```

Borrow expressions stay explicit. A call that expects `(& lifetime str)` does
not implicitly borrow a `String` argument:

```lisp test=ignore name=string-borrow-reject-implicit reason="negative example for future borrowed str checker"
(define (text-len [text : (& input str)]) : i64
  (string-length text))

(define (bad-implicit-borrow [input : String]) : i64
  (text-len input))
```

Bare `str` is rejected even when it appears to be used read-only:

```lisp test=ignore name=string-borrow-reject-bare-str reason="negative example for future borrowed str checker"
(define (bad-by-value-str [text : str]) : i64
  0)
```

Returned and stored borrowed string lifetimes require the lifetime-parameter
rules from #804. Until that slice lands, returning or storing a borrowed `str`
is rejected unless the checker can prove the reference is purely local to the
current lexical scope:

```lisp test=ignore name=string-borrow-reject-stored-returned reason="returned/stored borrowed lifetimes are deferred to #804"
(defstruct SavedText
  (text (& input str)))

(define (bad-return-borrow [input : String]) : (& input str)
  (& input))
```

Arena escape checks apply to borrowed string views exactly like other
references. A borrowed view of a scoped-arena `String` cannot escape the scoped
arena:

```lisp test=ignore name=string-borrow-reject-arena-escape reason="negative example for future borrowed str checker"
(define (bad-scoped-text) : (& phase str)
  (with-arena phase
    (let [text : String (int->string 42)]
      (& phase text))))
```

Borrowing a `String` is non-consuming. Moving the owner while a borrowed view is
live is rejected by the move/borrow checker:

```lisp test=ignore name=string-borrow-reject-move-while-borrowed reason="negative example for future move and borrowed str checker"
(define (bad-move-while-borrowed [input : String]) : i64
  (let [view : (& input str) (& input)]
    (let [moved : String input]
      (string-length view))))
```

#### API classification

The current implementation still exposes `String` parameters for these
builtins and stdlib helpers. After #1453/#1454, signatures should use
borrowed `str` for non-consuming text inputs while preserving owned `String`
results for allocation sites.

| Category | Members | v1 ownership contract |
|----------|---------|-----------------------|
| Non-consuming text inspection | `string-length`/`length`, `string-ref`/`char-at`, `string-eq`/`string=?`, `string->int`, stdlib predicates such as `string-contains`, `string-contains-char`, and `is-string-prefix-at` | Accept borrowed `(& r str)` inputs and return scalars. They do not move or allocate text. |
| Text output and diagnostics | `print-string`/`print-str`, `print-error`, `panic`/`error`, `stdout-write`, `stderr-write`, `write-file`, append/write status helpers, process stdin strings | Accept borrowed `(& r str)` text/path/message inputs. Host I/O may copy bytes outside the language heap but does not take TypeLisp ownership. |
| Active-arena owned string results | `arg`, `read-file`, `file-read-chunk-bytes`, `read-stdin-line`, `read-stdin-bytes`, `int->string`, `string-append`/`string-concat`, `substring`/`string-slice`, stdlib trim/replacement helpers when they build text, env/path split/join helpers | Return owned `String` storage allocated in the active arena. Results created inside a scoped arena cannot escape that arena. |
| Caller-provided fallback/result values | `stdlib/string.tl` `string-replace` when no match is found, `stdlib/io.tl` `read-file-or` fallback paths | Preserve the caller-owned value instead of allocating. Precise returned/stored lifetime signatures are deferred to #804; until then these remain conservatively checked. |
| Mutable or binary byte storage | dynamic arrays today; future byte-buffer/slice work | Not modeled as `str`. `str` is immutable borrowed text/bytes and should not become the mutable buffer type. |

#### ABI and lowering representation

`String` keeps the current aggregate-handle representation: a pointer-sized
source value points at a 16-byte string record containing `(data_ptr, length)`.
The record may describe static literal bytes or active-arena storage.

`(& lifetime str)` is a pointer-sized reference/provenance value whose referent
is an immutable 16-byte `(data_ptr, length)` string view. Borrowing a `String`
place may point the reference at the owned `String` record itself; borrowing a
future substring/slice view may point at a compiler-created view record. The
reference does not own, free, or extend the lifetime of the bytes. Its lifetime
is enforced only by the source checker, and the runtime representation carries
no NUL terminator guarantee.

Lowering may pass `(& lifetime str)` to runtime helpers using the same
pointer-sized reference slot shape as other immutable references. Runtime
helpers that read text must consume the view's pointer and length and must not
retain the view beyond the call unless a later API explicitly models that
stored lifetime.

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

### 4.3 `(extern name [metadata...] : (-> args ... ret))` - external symbol

Declares an external function to link against. The name is a TypeLisp
identifier used for source lookup. The legacy form `(extern name : type)`
defaults to target C ABI and uses `name` as the external linker symbol.

Metadata may appear before `:`:

- `(:abi c)` selects the C ABI. Unknown ABI names are rejected.
- `(:symbol "exact_name")` supplies the external linker symbol independently of
  the local TypeLisp name.
- `(:link-lib "name")` adds a native library input for source `build`/`run`.
- `(:link-search "dir")` adds a native library search directory for source
  `build`/`run`.
- `(:link-arg "arg")` adds a raw linker argument for source `build`/`run`.

Extern link metadata strings must be non-empty. Link metadata may be repeated.
Source `build`/`run` collects extern-owned link inputs from the source and its
imports, then merges explicit CLI `--link-lib`, `--link-search`, and
`--link-arg` inputs after metadata inputs. Exact duplicate values within each
input class are removed while preserving stable first-seen order. CLI link flags
remain supported.

External calls and `.extern` declarations use the metadata symbol without the
`_tl_` TypeLisp function prefix. Symbol text is passed through the deterministic
assembler-safe encoder used by the backend, so unsupported symbol characters are
escaped consistently. Ordinary TypeLisp declarations still use module-prefixed
`_tl_...` linker symbols.

Extern signatures may use backend-supported scalar values, `unit`, function
pointers, raw pointers, and pointer-sized TypeLisp runtime handles such as
`String`, dynamic arrays, structs, and enums. Tuple values, fixed arrays,
references, regions, and unsupported aggregate forms are rejected
for extern parameters and returns; pass a raw pointer when a foreign API needs
aggregate storage.

Raw pointer signatures do not make the pointer safe: nullability, validity,
aliasing, lifetime, mutability, and target ABI correctness remain the caller and
callee's contract.

Example:
```lisp test=check name=extern-declaration
(extern foreign-add : (-> i64 i64 i64))
```

```lisp test=ignore name=extern-metadata-declaration reason="requires the selfhost parser metadata form"
(extern local-add (:abi c) (:symbol "foreign_add_exact") : (-> i64 i64 i64))
```

```lisp test=ignore name=extern-link-metadata-declaration reason="requires native library fixture"
(extern native-add (:link-search "native/lib") (:link-lib "native_math") : (-> i64 i64 i64))
```

```lisp test=ignore name=extern-raw-pointer-signature reason="requires the selfhost raw-pointer checker path"
(extern strlen : (-> (Ptr u8) u64))
(extern fill-bytes : (-> (MutPtr u8) u64 u8 unit))
```

### 4.4 `(import "path.tl")` — module import

Imports another TypeLisp file. The legacy stage0 loader behaved as a
whole-program concatenation model: all top-level definitions from the imported
file became available in one flat namespace. The selfhost module model specified
below replaces that with canonical module identities, explicit exports, and
qualified lookup.

- Relative paths are resolved from the importing file's directory.
- Absolute filesystem paths are accepted by the underlying path resolver.
- Circular imports currently terminate by loading each module once; they are not rejected.
- Import paths are normalized; importing via different relative paths to the same file deduplicates.
- The repository's `stdlib/` directory is currently just source files. Importing
  `stdlib/string.tl` works when that path is reachable from the importing file,
  such as by staging or copying the `stdlib/` directory next to the entry
  source, when the CLI is given one or more `--stdlib-root <dir>` options, when
  `TYPELISP_STDLIB_ROOT` is set, or from the compiler's embedded stdlib
  fallback.
- For relative imports that start with `stdlib/`, the loader first tries the
  importer-relative path. If that path cannot be loaded, each configured stdlib
  root is searched by stripping the leading `stdlib/` and joining the remainder
  to the root. Explicit `--stdlib-root` entries are searched before the optional
  `TYPELISP_STDLIB_ROOT` fallback, and the embedded stdlib is searched last.
  Local project files therefore take precedence over configured stdlib roots and
  embedded modules. Configured and embedded stdlib fallbacks only serve normal
  relative suffixes under the root; suffixes containing components such as `..`
  are not resolved through stdlib fallback.
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
- Macro exports cover top-level `defmacro` declarations. Macro exports live in
  a separate compile-time namespace from value and type exports; they are
  looked up only while expanding expression heads.
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

Macro exports use the same item-list shape:

```lisp test=ignore name=module-macro-export-syntax reason="macro exports are specified before #1140 implementation"
(module bool-macros)

(defmacro (and2 [lhs : bool] [rhs : bool]) : bool
  (expr-if lhs rhs (expr-bool false)))

(export (macro and2))
```

Duplicate exports of the same item are accepted as idempotent only if they name
the same namespace item and export kind. Unknown export names, private imported
names, and namespace mistakes, such as exporting a type as a value or exporting
a value as a macro, are rejected. A macro and value with the same spelling are
distinct export kinds in module metadata, but v1 rejects declaring both in the
same local module because expression-head lookup would otherwise be ambiguous.

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
- Macros: `(bool/and2 a b)` resolves `and2` in the imported module's macro
  namespace during expansion.
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

#### 4.4.4 Macro export/import and expansion ordering

Macro-bearing modules use the same loader identity and path-resolution rules as
ordinary imports. Relative paths, canonical module identities, stdlib-root
fallback, and `pkg:<alias>/...` package dependency resolution are shared with
sections 4.4 and 4.4.1; there is no separate macro search path.

Before expanding a module's non-import forms, the loader parses the module,
collects its import declarations, recursively loads imported modules, and builds
the imported macro namespace from each dependency's exported macro items.
Imported macros are then available to the importer for the entire expansion of
that module through qualified names such as `bool/and2`. The imported macro's
typed signature is used for call-site checking in the importing module; operand
expressions are not evaluated before expansion.

Local macros are source-order declarations. A local `defmacro` is available
only after its declaration has been parsed and checked; using a local macro
before its `defmacro` is a source-located error. A local macro may call imported
macros and earlier local macros while its body is checked and expanded, but it
may not depend on later local macros.

Macro export tables are complete only after the exporting module's own imports
and earlier local macro declarations have been processed. V1 rejects cycles
that require a macro export from a module whose macro table is still being
built. Non-macro import cycles keep the ordinary loader behavior described in
section 4.4 until the general module-cycle policy is tightened.

Diagnostics required by v1:

- Missing macro export: a qualified macro head names an imported module but no
  exported macro of that name.
- Private macro: the exporting module has a local macro of that name but does
  not export it with `(export (macro name))`.
- Duplicate macro export: two distinct macro declarations would be exported
  under the same `(module, macro-name)` identity.
- Unknown export item: `(export (macro name))` names no local macro.
- Late local macro use: an unqualified macro head appears before the local
  `defmacro` declaration that would bind it.

Cross-module macro use:

```lisp test=ignore name=module-exported-macro-use reason="macro export/import expansion is tracked by #1140"
;; bool_macros.tl
(module bool-macros)
(defmacro (and2 [lhs : bool] [rhs : bool]) : bool
  (expr-if lhs rhs (expr-bool false)))
(export (macro and2))

;; main.tl
(import "bool_macros.tl" :as bool)
(define (main) : i64
  (if (bool/and2 true true) 0 1))
```

Private or missing macro diagnostic:

```lisp test=ignore name=module-private-macro-diagnostic reason="negative macro visibility example for #1140"
;; hidden.tl
(module hidden)
(defmacro (private-and [lhs : bool] [rhs : bool]) : bool
  (expr-if lhs rhs (expr-bool false)))

;; main.tl
(import "hidden.tl" :as hidden)
(define (main) : i64
  (if (hidden/private-and true true) 0 1)) ; error: private macro hidden/private-and
```

Late local macro diagnostic:

```lisp test=ignore name=module-late-local-macro-diagnostic reason="negative macro ordering example for #1140"
(define eager : bool (late true)) ; error: local macro late is defined later

(defmacro (late [value : bool]) : bool
  value)
```

#### 4.4.5 TypeLisp linker symbols

The TypeLisp declaration identity used by lowering and backend symbol emission
is `(canonical-module-identity, declaration-identity)`. User TypeLisp linker
symbols are deterministic assembler-safe encodings of both parts, with one
special entry rule: the selected entry declaration named `main` emits the host
entry symbol `main`, while any other declaration named `main` receives a normal
module-prefixed TypeLisp symbol.

Exact external FFI linker names are defined by `extern` metadata, not by this
module model. `extern` declarations keep a TypeLisp declaration identity for
lookup and visibility, while backend calls use the declaration's exact external
symbol. Runtime helper symbols and backend-local labels are likewise outside
module-prefixing and must not be accidentally rewritten as user declarations.

#### 4.4.6 `(include-str name "path")` — embed a text file

Embeds the UTF-8 text contents of `path` as a string-valued global `name`,
equivalent to writing `(define name : String "…")` with the file's exact bytes
as a string literal. This is a module-loader directive, not a runtime operation:
the loader reads the file and expands the directive into an ordinary
string-valued `define` before typechecking, lowering, and codegen, so later
stages only ever see a normal global.

- Text-only: the file is read as UTF-8 source payload. Binary includes and
  arbitrary resource packaging are out of scope for this directive.
- `path` is resolved exactly like an `import` path (§4.4): relative paths resolve
  from the including file's directory, and `stdlib/...` paths use the same
  stdlib-root / embedded-provider precedence and the same parent-escape (`..`)
  rejection. The included file is read as raw text — it is not parsed as a
  module, runs no imports or tests, and does not participate in import
  deduplication.
- An include failure reports both the including file and the requested path.

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
  (dependencies
    (math "../math")))
```

- `name` and `version` are required string fields.
- `kind` is optional and defaults to `bin`. When present, it accepts `bin` and
  `staticlib` as symbols or strings; `lib` remains accepted as a compatibility
  alias for `staticlib`. `bin` produces a native executable; `staticlib`
  produces a static archive.
- `entry` is optional. It defaults to `src/main.tl` for `bin` packages and
  `src/lib.tl` for `staticlib` packages. An explicit `entry` string overrides
  the convention default.
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
- Build outputs are written under `target/typelisp/<package-name>/` in the
  package root. `bin` packages produce `<package-name>` on Linux and
  `<package-name>.exe` on Windows. `staticlib` packages produce
  `lib<package-name>.a` on Linux and `<package-name>.lib` on Windows.
- Package-root-qualified imports use the reserved string prefix
  `pkg:<alias>/...`, for example `(import "pkg:math/src/lib.tl")`.
- This first package layer has no registry, semantic-version solving,
  transitive manifest loading, implicit preludes, lockfile, workspace model, or
  dynamic/shared library output. Namespace isolation and qualified symbol access
  are specified by the selfhost module model in section 4.4, not by package
  resolution itself.

### 4.6 `(defenum ...)` and `(defstruct ...)`

See §3.5.

#### 4.6.1 Cleanup-owning aggregate declarations (specified, pending implementation)

Cleanup-required values are values that must be passed to a cleanup function
exactly once before their owner scope exits. Ordinary aggregates do not own
those values: a `defstruct` without cleanup metadata and every v1 `defenum`
payload must reject cleanup-required fields, cleanup-owning aggregate fields,
and cleanup-owning payloads. This prevents ordinary aggregate construction from
silently hiding cleanup responsibility in a value with no cleanup plan.

A cleanup-owning struct opts in with type-level `(:cleanup cleanup-fn)`
metadata immediately after the struct name and before all fields. The metadata
declares the cleanup function for the struct type and makes values of that type
move-only:

```lisp test=ignore name=cleanup-owning-buffered-file-struct reason="cleanup-owning aggregate declarations are specified before compiler support"
(defstruct FileHandle
  (:cleanup close-file-handle)
  (fd i64 (:cleanup close-fd)))

(defstruct TextBuffer
  (:cleanup close-text-buffer)
  (ptr i64 (:cleanup free-buffer)))

(defstruct BufferedFile
  (:cleanup close-buffered-file)
  (fd FileHandle (:owned))
  (buffer TextBuffer (:owned)))

(define (open-buffered-file [fd : i64] [ptr : i64]) : BufferedFile
  (BufferedFile (FileHandle fd) (TextBuffer ptr)))

(define (use-buffered-file [fd : i64] [ptr : i64]) : i64
  (with ([bf (open-buffered-file fd ptr) close-buffered-file])
    (struct-get (struct-get bf fd) fd)))
```

`cleanup-fn` names the type-level cleanup function for the aggregate. The
compiler must expose exactly one such function for each cleanup-owning struct
and reject another top-level value with the same name. Its type is `(-> T unit)`
where `T` is the struct type. The generated cleanup function owns its argument,
runs the struct field cleanup plan below, and returns `unit`. Source-level
custom cleanup hooks for the whole value are deferred; v1 cleanup behavior is
fully determined by field metadata and nested cleanup-owning field types.

Struct field metadata may include exactly one cleanup marker after the field
type:

- `(:cleanup field-cleanup-fn)` marks a direct resource field and names the
  cleanup function for that field. The function must have type `(-> F unit)`,
  where `F` is the field type.
- `(:owned)` marks a field whose type is itself cleanup-owning. The field uses
  that type's declared cleanup function.

Field-level cleanup metadata is accepted only inside a cleanup-owning struct.
A cleanup-owning struct may contain ordinary fields with no cleanup marker.
Every cleanup-required field must have `(:cleanup ...)`; every cleanup-owning
aggregate field must have `(:owned)`. A field may not specify both. Field
metadata is part of the owning contract, not layout, and is incompatible with
`(:repr c)` in v1: a C ABI struct cannot own cleanup-required resources.

Cleanup for a struct value is deterministic. When the owner scope cleans a
value of cleanup-owning struct type:

1. The value is marked moved so later reads, copies, stores, or returns of the
   same owner are rejected.
2. Fields with cleanup metadata are cleaned in reverse declaration order.
3. For `(:cleanup f)`, the compiler calls `f` with the field value.
4. For `(:owned)`, the compiler recursively calls the field type's declared
   cleanup function.
5. Fields without cleanup metadata are not cleaned.

Nested cleanup completes before the previous field begins. If a field has
already been moved out, that field is no longer cleaned by the containing
struct; responsibility moved with the field. Moving a field out of a
cleanup-owning struct leaves the whole struct partially moved, so the compiler
must reject later cleanup of the whole value unless the field is definitely
reinitialized before the owner scope exits. Partial moves are therefore expected
to remain rejected until the move checker can track field initialization.

Cleanup-owning structs are move-only. Assigning, passing as an ordinary by-value
argument, returning, storing in another aggregate, or binding to another name
transfers ownership unless the operation is explicitly a borrow in a future
borrow/reference model. After such a move, the source value cannot be used.
Copying a cleanup-owning value is never allowed. A cleanup-owning value cannot
be stored in a global, captured by an escaping closure, or returned from a
`with` scope that owns it.

```lisp test=ignore name=cleanup-owning-nested-struct reason="cleanup-owning aggregate declarations are specified before compiler support"
(defstruct FileHandle
  (:cleanup close-file-handle)
  (fd i64 (:cleanup close-fd)))

(defstruct BufferedFile
  (:cleanup close-buffered-file)
  (handle FileHandle (:owned)))

(defstruct LogWriter
  (:cleanup close-log-writer)
  (file BufferedFile (:owned))
  (bytes-written i64))
```

The example above ignores `bytes-written` and cleans `file`; cleaning `file`
recursively cleans `handle`.

```lisp test=ignore name=cleanup-owning-reject-ordinary-storage reason="negative example for future cleanup-required aggregate checks"
(defstruct FileHandle
  (:cleanup close-file-handle)
  (fd i64 (:cleanup close-fd)))

(defstruct BadWrapper
  (handle FileHandle))
```

`BadWrapper` is rejected because it stores a cleanup-owning value without
declaring its own cleanup ownership and without marking the field `(:owned)`.

```lisp test=ignore name=cleanup-owning-reject-copy reason="negative example for future move-only cleanup-owning aggregate checks"
(defstruct FileHandle
  (:cleanup close-file-handle)
  (fd i64 (:cleanup close-fd)))

(define (open-handle [fd : i64]) : FileHandle
  (FileHandle fd))

(define (bad-copy [fd : i64]) : i64
  (with ([h (open-handle fd) close-file-handle])
    (let ([copy h])
      (struct-get h fd))))
```

The `let` binding moves `h` into `copy`; the later read from `h` is rejected as
use-after-move. The compiler must also ensure the moved value still has exactly
one owner that will clean it.

```lisp test=ignore name=cleanup-owning-reject-escape reason="negative example for future cleanup-owning aggregate escape checks"
(defstruct FileHandle
  (:cleanup close-file-handle)
  (fd i64 (:cleanup close-fd)))

(define (open-handle [fd : i64]) : FileHandle
  (FileHandle fd))

(define (leak-handle [fd : i64]) : FileHandle
  (with ([h (open-handle fd) close-file-handle])
    h))
```

`leak-handle` is rejected because the `with` scope owns `h`; returning it would
escape the cleanup scope.

`with` is the v1 owner scope for cleanup-owning aggregates. If a `with` binding
initializes a cleanup-owning struct, its cleanup position must be the struct's
declared cleanup function; another cleanup function is rejected. A resource
value moved into a cleanup-owning aggregate is not also cleaned by the source
binding. Normal `let` still has no cleanup behavior; creating a cleanup-owning
value in `let` is valid only if the value is immediately moved into another
owner whose cleanup is statically known.

Cleanup runs when the owner scope exits normally and before recoverable `(try
...)` propagation leaves the scope. If initialization of a later `with` binding
propagates recoverably, already-initialized earlier cleanup-owning values are
cleaned in the same reverse-binding order as other resources. Cleanup functions
return `unit`; if a cleanup function panics, the program aborts and the
language does not guarantee that remaining field, nested, or outer cleanups
run. A direct `panic`/abort has no unwinding cleanup guarantee.

Cleanup-owning `defenum` declarations are deferred in v1. The reserved shape is
`(defenum Name (:cleanup cleanup-fn) variant+)`, but the parser/typechecker must
reject it until enum payload ownership is implemented. Ordinary enum payloads
must reject cleanup-required and cleanup-owning types. A future cleanup-owning
enum must clean only the active variant payload, in reverse payload declaration
order, using field-style `(:cleanup ...)` and `(:owned)` payload metadata.

#### 4.6.2 Move-only aggregate handle semantics (specified, pending implementation)

The v1 source semantics make aggregate handles move-only. The current compiler
may still accept copies until the selfhost move checker lands, but new source
and selfhost implementation work must follow this contract.

**Copyable v1 types.** A use of a copyable value duplicates the value and leaves
the source initialized. Copyable types are:

- Scalar primitives: all integer widths, `f64`, backend-accepted `f32`
  positions, `bool`, `char`, and `unit`.
- The compiler-internal `never` type, which has no runtime value to move.
- Raw pointers `(Ptr T)` and `(MutPtr T)` once implemented; copying a pointer
  copies only the address and carries no ownership guarantee.
- Named top-level function values and non-capturing function pointers.

Safe reference values and their copy/aliasing rules are specified by the borrow
checker slices (#1033-#1035 and #806), not by this section.

**Move-only v1 types.** A by-value use of a move-only value transfers ownership
and marks the source place moved. Move-only types are:

- `String`.
- Dynamic arrays `(Array T)`.
- Boxes `(Box T)`.
- Fixed arrays `(Array T N)`.
- Tuples `(Tuple ...)`.
- Default-layout structs and enums.
- Cleanup-owning structs from section 4.6.1.
- Capturing closure values. A closure that captures only copyable values may be
  implemented as copyable later, but the first v1 checker should treat
  capturing closures conservatively as move-only unless it can prove all
  captures are copyable.

A region wrapper `(in r T)` preserves the copy/move class of `T`; the region tag
only constrains where the value may escape. Type aliases, once added, also
preserve the aliased type's class.

**Move sites.** The checker must treat these by-value positions as moves for
move-only values and as copies for copyable values:

- `let` initialization. `(let [b a] body)` moves `a` into `b` when `a` is
  move-only; `a` is unusable afterward.
- A variable or place used as a by-value expression result, including a block's
  final expression.
- Function-call arguments whose parameter type is not a reference type. Arguments
  are evaluated left-to-right; earlier moves are visible while checking later
  arguments and the remaining expression.
- Function returns. Returning a move-only local or parameter moves it to the
  caller. Returning from a `with` owner scope is still rejected when it would
  bypass required cleanup.
- `set!` right-hand sides. Assigning a move-only value into a definitely moved
  or definitely uninitialized local moves the value into that slot. Assigning
  over an initialized move-only slot is rejected in v1 because there is no
  implicit drop, destructor, or replacement cleanup yet. Move-only globals are
  rejected.
- Tuple, fixed-array, struct, and enum constructors. Constructor arguments are
  consumed by value unless their expression is copyable or explicitly borrowed
  by a reference form once the relevant borrow-checker slice is implemented.
- `array-set!` value arguments. A move-only element value would be consumed by
  the store, but v1 rejects arrays of move-only elements and stores of move-only
  elements until unique mutable access and element replacement cleanup are
  specified (#806/#1049).
- `match` scrutinees. Matching a move-only enum consumes the whole enum value.
  Payload bindings then own the active payload values for that arm.
- Closure capture. Capturing a move-only local by value moves it into the
  closure environment at closure creation time; the local cannot be used after
  the lambda literal. Capturing by reference is deferred to the borrow checker.

**Non-consuming use sites.** A non-consuming use may inspect a move-only value
without moving it. In v1 these are limited to:

- Immutable borrow expressions `(& place)` / `(& lifetime place)` and reference
  parameters once the selfhost syntax/provenance/escape slices land
  (#1033-#1035).
- Compatibility inspection builtins whose current signatures are not yet
  reference-typed: `length`/`string-length`, `string-ref`/`char-at`,
  `string-eq`/`string=?`, `string->int`, `print-string`/`print-str`,
  `print-error`, dynamic-array `length`/`array-length`, `array-ref` when the
  element type is copyable, `struct-get` when the selected field type is
  copyable, and stdlib predicates that only inspect their aggregate argument.
- `array-set!` on the array receiver itself while the mutable-reference model is
  pending. This compatibility rule mutates the array storage but does not move
  the array handle.

Ordinary user-defined function parameters are by-value unless their type is a
future reference type. Passing a `String`, array, tuple, struct, enum, or
capturing closure to such a parameter consumes the argument.

**Whole-place and path moves.** The v1 checker accepts only whole-place moves:
locals, parameters, and whole constructor temporaries. Moving out of a
field, tuple element, fixed-array element, dynamic-array element, or nested path
is rejected until path tracking and reinitialization are implemented (#1049).
`struct-get`, `tuple-ref`, and `array-ref` may copy out only copyable fields or
elements. They may not move out a move-only field or element. A consuming
`match` is the enum exception: it moves the whole scrutinee first, then binds
payload values owned by the selected arm.

**Diagnostics.** Move checking must produce source-located diagnostics for:

- Use after move, naming the moved local or path and the move site when known.
- Moving from an uninitialized or already-moved slot.
- Assigning over an initialized move-only slot.
- Moving out of an unsupported path such as a field, tuple element, or array
  element.
- Storing, capturing, or returning a move-only value where the destination would
  outlive the owner scope.

Move-while-borrowed and assignment-while-borrowed diagnostics are reserved for
the borrow checker implementation (#806/#1034/#1035/#1049). String `str`
borrowing and owned/borrowed text distinctions are deferred to #807.

```lisp test=check name=move-copyable-scalar-reuse
(define (copyable-scalar [x : i64]) : i64
  (let [y x]
    (+ x y)))
```

```lisp test=ignore name=move-reject-aggregate-reuse reason="negative example for future move-only aggregate checks"
(define (bad-string-reuse [s : String]) : i64
  (let [taken s]
    (length s)))
```

The `let` binding moves `s` into `taken`; the later `length` inspection is a
use-after-move even though `length` itself is non-consuming.

```lisp test=ignore name=move-reject-consumed-function-arg reason="negative example for future move-only call argument checks"
(define (take-string [s : String]) : i64
  (length s))

(define (bad-call-reuse [s : String]) : i64
  (begin
    (take-string s)
    (length s)))
```

The call to `take-string` consumes `s` because ordinary parameters are
by-value; the later read is rejected.

```lisp test=check name=move-copyable-struct-field-projection
(defstruct Counter
  (label String)
  (count i64))

(define (counter-count [c : Counter]) : i64
  (struct-get c count))
```

Reading the `i64` field is non-consuming because the projected field is
copyable. Moving the `String` field out directly is not allowed:

```lisp test=ignore name=move-reject-struct-field-move reason="negative example for future path-move checks"
(defstruct Counter
  (label String)
  (count i64))

(define (bad-counter-label [c : Counter]) : String
  (struct-get c label))
```

```lisp test=check name=move-match-payload-consumes-scrutinee
(defenum MaybeName
  (NoName)
  (SomeName String))

(define (name-score [s : String]) : i64
  (length s))

(define (score [m : MaybeName]) : i64
  (match m
    [(SomeName s) (name-score s)]
    [NoName 0]))
```

The `match` consumes `m`; the `SomeName` arm owns `s` and can pass it to
`name-score`.

```lisp test=ignore name=move-reject-match-scrutinee-reuse reason="negative example for future match move checks"
(defenum MaybeName
  (NoName)
  (SomeName String))

(define (bad-match-reuse [m : MaybeName]) : i64
  (begin
    (match m
      [(SomeName s) (length s)]
      [NoName 0])
    (match m
      [(SomeName s) (length s)]
      [NoName 0])))
```

The first `match` moves `m`, so the second `match` is rejected as a
use-after-move.

#### 4.6.3 Recursive aggregate layout and boxed recursion (specified; finite analysis implemented)

Today, default TypeLisp structs and enums are pointer-shaped aggregate handles,
so directly recursive enum payloads are finite in the current implementation.
That is an implementation detail, not the long-term source contract. When an
aggregate opts into Rust-like inline representation, the compiler must reject
recursive-by-value storage cycles and require explicit indirection through
`(Box T)`.

The finite-layout rule is structural:

- A field or enum payload may directly contain scalar, pointer, reference,
  function, and other finite-size values according to the ordinary type rules.
- A field or enum payload may contain `(Box T)` even when `T` is the aggregate
  currently being defined, because the field stores only the owning box handle.
- A field or enum payload that reaches the same inline aggregate type again
  without crossing a box, raw pointer, or reference edge is an infinite layout
  and must be rejected.
- Mutually recursive inline aggregates are checked the same way: every cycle in
  the aggregate layout graph must cross an explicit indirection edge.

This rule does not switch default struct/enum layout by itself. It defines the
source-level indirection required before later issues can add opt-in inline
layout and migrate selfhost recursive data structures. The selfhost typechecker
has a reusable finite-layout analysis for this future inline-layout opt-in; the
default handle-layout path still accepts today's recursive aggregate programs.

```lisp test=ignore name=box-recursive-list-layout-ok reason="requires future inline aggregate layout mode"
(defenum ListI64
  (ListNil)
  (ListCons i64 (Box ListI64)))
```

```lisp test=ignore name=box-recursive-tree-layout-ok reason="requires future inline aggregate layout mode"
(defenum Tree
  (Leaf i64)
  (Node (Box Tree) (Box Tree)))
```

```lisp test=ignore name=box-reject-unboxed-recursion reason="negative example for future inline aggregate cycle checks"
(defenum BadList
  (BadNil)
  (BadCons i64 BadList))
```

`BadList` is rejected for inline representation because `BadCons` contains a
`BadList` payload by value. The accepted spelling is `(Box BadList)`.

```lisp test=ignore name=box-reject-arena-escape reason="negative example for future Box region checks"
(defenum ListI64
  (ListNil)
  (ListCons i64 (Box ListI64)))

(define (bad-box-escape) : (Box ListI64)
  (with-arena scratch
    (box (ListCons 1 (box ListNil)))))
```

`bad-box-escape` is rejected because the outer `box` is allocated inside
`scratch`, so its type is `(in scratch (Box ListI64))`; returning it would let
arena-owned storage escape the scoped region.

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
- `+`, `-`, `*`, `/` also operate on `f64` and `f32`; `%` on floating-point values is
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

See §3.8. Casts cover the full scalar numeric matrix: integer/`char`
widening, narrowing, and truncation; `f64` ↔ `f32` precision changes; and
integer/`char` ↔ float conversions (float → integer truncates toward zero).

### 5.13 `(match scrutinee [pattern expr] ...)` — pattern matching

- Enum scrutinees support variant patterns such as `Red` and `(Some value)`.
- Scalar scrutinees support literal patterns plus `_`.
- String literal patterns compare string contents, not pointer identity.
- Bindings in enum patterns introduce variables for payload fields.
- A bare identifier at the top level of an enum `match` arm is resolved as a
  nullary variant name. It is not a fresh catch-all binding; use `_` for that.
- The `_` wildcard matches any remaining value (used for exhaustiveness).
- All arms must return the same type.
- Enum values are heap-allocated on return from functions (see §3.5.1).

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

Runtime-dispatched SIMD variants:

Runtime dispatch is declared with a top-level `defdispatch` item. The logical
name is the callable API; each variant names an ordinary top-level function
compiled for one backend mode.

```lisp test=ignore name=simd-dispatch-declaration reason="runtime SIMD dispatch declarations are specified before parser/lowerer implementation"
(define (add-arrays-scalar [a : (Array i64)]
                           [b : (Array i64)]
                           [out : (Array i64)]
                           [n : i64]) : unit
  (foreach ([i : i64 0 n])
    (array-set! out i (+ (array-ref a i) (array-ref b i)))))

(define (add-arrays-avx2 [a : (Array i64)]
                         [b : (Array i64)]
                         [out : (Array i64)]
                         [n : i64]) : unit
  (foreach ([i : i64 0 n])
    (array-set! out i (+ (array-ref a i) (array-ref b i)))))

(define (add-arrays-avx512 [a : (Array i64)]
                           [b : (Array i64)]
                           [out : (Array i64)]
                           [n : i64]) : unit
  (foreach ([i : i64 0 n])
    (array-set! out i (+ (array-ref a i) (array-ref b i)))))

(defdispatch add-arrays
  (scalar add-arrays-scalar)
  (avx2 add-arrays-avx2)
  (avx512 add-arrays-avx512))

(define (main [a : (Array i64)]
              [b : (Array i64)]
              [out : (Array i64)]
              [n : i64]) : unit
  (add-arrays a b out n))
```

Rules:

- The first item in each variant pair is an ISA name: `scalar`, `avx2`, or
  `avx512`. `avx512` means AVX-512 Foundation plus the OS ZMM/opmask state
  needed to execute it.
- `scalar` is required and is the fallback on every target.
- `avx2` and `avx512` are optional. Unknown ISA names are rejected.
- Variant item order is not semantic. The resolver always prefers the best
  runnable listed variant in this order: `avx512`, then `avx2`, then `scalar`.
- All variants must be top-level functions with identical parameter and return
  types. The logical dispatch name has that same function type.
- The scalar variant is compiled in scalar mode. ISA variants are compiled with
  their declared backend mode; unsupported body shapes produce backend-mode
  diagnostics rather than silently changing semantics.
- A call to the logical name type-checks like a call to the shared signature.
  Lowering may emit a small wrapper, an indirect call through a cached function
  pointer, or equivalent target code, but the selected body must produce the
  same observable result as the scalar body for all safe programs.
- Feature detection happens on the first call to each logical dispatch function
  and the selected target is cached for the life of the process. An
  implementation may instead resolve at program startup if that has the same
  observable behavior.
- Selection may use the same CPUID/XGETBV capability checks exposed by
  `stdlib/cpu.tl` (`cpu-runs-avx2?`, `cpu-runs-avx512f?`), but ordinary user
  code does not need to import `stdlib/cpu.tl` or call those helpers to use a
  dispatched function.
- Variant selection runs no user variant body and performs no user-visible I/O.
  It may read CPU/OS capability state and update hidden dispatch-cache storage.
- A dispatch declaration creates a value-namespace binding for the logical name.
  It conflicts with an existing value declaration of that name.
- Variant functions are ordinary declarations. Exporting the dispatch exports
  only the logical name; variant functions are exported only if explicitly
  exported as values. Imported modules call the logical name through the normal
  qualified or selected import rules.
- Diagnostics must cover missing scalar fallback, duplicate variants for the
  same ISA, unsupported ISA names, unknown variant function names, mismatched
  signatures, using the logical dispatch name as one of its own variants, and
  using another dispatch declaration as a variant in v1. The last two rules
  avoid recursive dispatch declarations until resolver cycles have a specified
  model.

Unsupported in the initial SPMD surface:

- Public vector types, public mask types, `program-index`, and `program-count`.
- Gather/scatter, indirect indexing through arrays, and non-contiguous memory.
- Scans, general cross-lane operations, atomics, and overlapping writes.
- Reduction-by-mutation through `set!` to an outer accumulator.
- Varying `if`/`while`, early exits, `break`, and `continue`.
- User-defined function calls with varying arguments or varying returns.
- Struct, enum, tuple, string, function, and nested array lane values.
- Task parallelism, multicore scheduling, and public AVX-specific intrinsics.

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

### 5.16 `(with-arena ident body ...)` — scoped region

Introduces a temporary allocation region named `ident` whose lifetime is
the lexical scope of the form's body. The body is a non-empty expression
sequence; the last expression is the result. Subregions are expressed by
nesting `with-arena` forms.

```lisp test=check name=with-arena-basic
(define (main) : i64
  (with-arena r
    (let
      [s : String (int->string 42)]
      (begin
        (print-string s)
        0))))
```

**Static escape checking:** Values allocated inside a region are typed as
`(in r T)` (see §3.9). The typechecker rejects any attempt to let a
region-tagged value escape its scope:

- As the result of the `with-arena` form (`(with-arena r (make-array i64 5))`).
- Stored into an outer `let`, `set!`, or global binding.
- Captured by a lambda whose closure outlives the region.
- Returned from an enclosing function.
- Passed to a function call (v1 confinement — function parameters have no
  region tag).

**Nested regions:** Inner and outer regions are distinct. A value allocated in
an inner region may not escape to the outer region, and a value from an outer
region may be used inside an inner region (it does not gain the inner tag).

**Lowering contract:** Each `with-arena` lowers to a `tl_region_mark` at
entry, the body with all region-allocating operations implicitly targeting the
active region, and a `tl_region_reset` at exit that restores the mark. Because
the body result must be region-free, the reset is safe: no live handle refers
to storage allocated after the mark.

**Non-Linux targets:** `with-arena` remains a typechecked scope. On targets
where `tl_region_mark` / `tl_region_reset` are unavailable the runtime does
not perform a reset; the semantics match minus reclamation. The form still
prevents escapes, so programs compile and run identically, but allocations
accumulate in the process-lifetime arena instead of being reclaimed.

**First-class arena escape:** `(with-escape arena-expr body ...)` is a
separate scoped form for first-class scratch arenas. `arena-expr` must
typecheck as `i64` and evaluates to an arena handle such as one created by
`arena-make`; it is not a lexical region binder and does not conflict with
`with-arena`.

The body is a non-empty expression sequence evaluated with that arena as the
active allocation target. On exit, the result is cloned into the enclosing active
arena when needed, the scratch arena is rewound to its entry mark, and the active
arena is restored. The v1 result surface follows the current `clone` lowering:
copyable values are returned as-is, `String` values are copied, and cloneable
named aggregates use their generated clone helpers. Direct tuple, array,
dynamic-array, and box results are rejected until those shapes have deep-clone
lowering. Typechecking returns the body result type with source-region tags
stripped, matching the clone semantics of moving the result back to the
enclosing arena.

### 5.17 Comptime type reflection (specified, selfhost v1 implemented)

Type reflection is the compile-time-only surface that lets generators inspect
TypeLisp types and emit concrete declarations instead of using source-level
generics or traits. Reflection is intentionally a comptime metadata API, not a
runtime type-object API.

All reflection primitives take `type-expr` operands that must evaluate at
compile time to a type value, usually `(type T)` or a `[comptime T : type]`
parameter. Reflection primitives are valid only in compile-time-required
contexts: explicit `(comptime ...)` folds, comptime parameter evaluation, and
generated declaration evaluation. Any direct runtime use must be rejected before
lowering. A generator that wants a runtime literal derived from reflection must
emit that literal into generated source; the reflection metadata itself never
becomes a runtime value.

Reflection returns CTFE metadata values. `i64` metadata is an integer in the
comptime evaluator. `type` metadata is a type value. `String` metadata is a
compiler-owned comptime string. These strings may be compared and used to build
generated identifiers in comptime code, but they must not be lowered as heap
`String` values. V1 does not expose list metadata values; indexed primitives are
used instead.

V1 primitive names and signatures are fixed as follows:

| Primitive | Result | Notes |
| --- | --- | --- |
| `(type-kind type-expr)` | `String` | One of the fixed kind strings below. |
| `(type-key type-expr)` | `String` | Opaque deterministic key for generated declarations. |
| `(type-nominal-module type-expr)` | `String` | Canonical module identity for a struct/enum type. |
| `(type-nominal-name type-expr)` | `String` | Unqualified nominal type name for a struct/enum type. |
| `(struct-field-count type-expr)` | `i64` | Requires a struct type. |
| `(struct-field-name type-expr index-expr)` | `String` | Zero-based field name. |
| `(struct-field-type type-expr index-expr)` | `type` | Zero-based field type. |
| `(enum-variant-count type-expr)` | `i64` | Requires an enum type. |
| `(enum-variant-name type-expr index-expr)` | `String` | Zero-based variant constructor name. |
| `(enum-variant-payload-count type-expr index-expr)` | `i64` | Number of payload fields for that variant. |
| `(enum-variant-payload-type type-expr variant-index-expr payload-index-expr)` | `type` | Zero-based payload type. |
| `(array-element-type type-expr)` | `type` | Requires fixed or dynamic array. |
| `(array-length type-expr)` | `i64` | Requires fixed array. Dynamic arrays reject this. |
| `(array-dynamic? type-expr)` | `bool` | True for `(Array T)`, false for `(Array T n)`. |
| `(function-param-count type-expr)` | `i64` | Requires function type. |
| `(function-param-type type-expr index-expr)` | `type` | Zero-based parameter type. |
| `(function-return-type type-expr)` | `type` | Function return type. |

Selfhost v1 implements this surface in CTFE for explicit `(comptime ...)` folds
and comptime parameter evaluation. `String` and `type` metadata remain
compile-time-only; programs may compare or compose them in CTFE, but direct
runtime observation is rejected before lowering.

`index-expr`, `variant-index-expr`, and `payload-index-expr` must evaluate to
`i64` in the same comptime context. Out-of-range indices, wrong arity,
non-type operands, and kind mismatches are compile-time diagnostics. The
diagnostic should name the primitive and the expected kind, for example
`struct-field-type requires struct type`.

`type-kind` returns one of these lowercase stable strings:

- Builtins: `i64`, `i32`, `i16`, `i8`, `u64`, `u32`, `u16`, `u8`, `f64`,
  `f32`, `bool`, `char`, `string`, `unit`, `never`.
- Shapes: `array`, `dyn-array`, `function`, `tuple`, `struct`, `enum`.
- Reserved/partial shapes: `str`, `ptr`, `mut-ptr`, `ref`, `mut-ref`,
  `region`, `type-var`.

V1 reflection may classify reserved/partial shapes with `type-kind` and
`type-key`, but detailed pointer/reference/region reflection is deferred to the
raw-pointer and reference owning issues. Tuple element introspection is also
deferred; tuple types can be keyed and classified but are not a generator target
for v1.

Nominal identity is two-part:

- `type-nominal-module` returns the canonical module identity defined by the
  module-identity work (#951/#952), not a source import spelling.
- `type-nominal-name` returns the declared or generated type name in that
  module's type namespace.

Both primitives reject non-nominal types. Generated nominal declarations from
#893 use their generated declaration identity as the nominal name component, so
reflection and generated declaration reuse share the same identity source.

`type-key` is a compiler-owned ASCII string. It is stable across compiler runs
for the same canonical type graph and is suitable as an input to generated
declaration keys; it is not a display format and programs must not parse it.
The key is built from tagged, length-prefixed components so module names, type
names, and recursive subkeys cannot collide. Conceptually, the rules are:

- Builtins key by their stable lowercase kind string.
- Fixed arrays key as `(array length element-key)`.
- Dynamic arrays key as `(dyn-array element-key)`.
- Functions key as `(function param-count param-key... return-key)`.
- Nominal structs/enums key as `(nominal kind module-identity type-name)`.
- Pointer/reference/region keys, once detailed reflection lands, must include
  mutability and the referenced/pointee type key; reference keys must also
  include the canonical region identity.

The implementation must resolve aliases before keying, preserve nominal
struct/enum identity rather than structuralizing it, and use the same key rules
when composing #893 generated declaration identities. Display names derived from
keys may use a readable mangling, but the key itself remains opaque.

Intended generator uses:

- Concrete collection families key their element type with `type-key` and emit
  names such as `Vec_I64` or `Map_String_I64` from that key.
- Concrete `Option*` / `Result*` families key payload and error types with the
  same rules as section 9.
- Serializer, equality, hashing, and debug-print helpers can iterate
  `struct-field-*` and `enum-variant-*` metadata to emit direct field/variant
  code for one nominal type.
- Function adapters can inspect `function-param-*` / `function-return-type` to
  generate arity-specific wrappers without runtime type objects.

V1 exclusions:

- Layout size, alignment, and field offset queries stay in the layout-query
  surface below (#912) and are not aliases for reflection primitives.
- Raw pointer, reference, and region details beyond kind/key are deferred to
  their owning issues.
- Runtime type IDs, runtime reflection, trait/interface lookup, method tables,
  and type-erased dispatch are not part of this surface.
- Reflection metadata strings are not runtime `String` allocation hooks.

### 5.18 Layout queries (specified, selfhost pending)

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

### 5.19 `(with ([name init cleanup] ...) body ...)` - scoped resource cleanup

The `(with ...)` form is reserved for explicit scoped cleanup of non-memory
resources such as file descriptors, process handles, temporary files, locks,
and mapped files. It is separate from `(with-arena ...)`: `with` calls cleanup
functions for resource values, while `with-arena` resets arena allocation for
memory owned by a lexical region.

Each binding has the form `[name init-expr cleanup-fn]`.

- `init-expr` is evaluated and bound to `name`.
- `cleanup-fn` must name or evaluate to a function of type `(-> T unit)`, where
  `T` is the type of `name`. Initial compiler support may restrict this
  position to a direct function identifier. If it is an expression, it is
  evaluated after `init-expr` succeeds and before the next binding begins.
- `name` is in scope for later bindings and for the body, but not before its
  own initializer.
- The body is a non-empty expression sequence; the last expression is the
  result of the `with` form.

```lisp test=ignore name=with-resource-normal reason="reserved scoped resource cleanup syntax; compiler support tracked by #907"
(defstruct Handle (id i64))

(define (open-handle) : Handle
  (Handle 1))

(define (close-handle [h : Handle]) : unit
  unit)

(define (use-handle) : i64
  (with ([h (open-handle) close-handle])
    (struct-get h id)))
```

Multiple bindings are initialized left-to-right and cleaned up in reverse
order. A binding whose initializer did not complete is not cleaned up. This
makes a multi-binding form equivalent to nested `with` forms for lifetime
purposes:

```lisp test=ignore name=with-resource-lifo reason="reserved scoped resource cleanup syntax; compiler support tracked by #907"
(defstruct Handle (id i64))

(define (open-handle [id : i64]) : Handle
  (Handle id))

(define (close-handle [h : Handle]) : unit
  unit)

(define (use-two-handles) : i64
  (with ([outer (open-handle 1) close-handle]
         [inner (open-handle 2) close-handle])
    (+ (struct-get outer id)
       (struct-get inner id))))
```

In the example above `inner` is closed before `outer`.

Nested `with` forms compose in the same way: the inner scope cleans up before
execution continues in the outer scope.

```lisp test=ignore name=with-resource-nested reason="reserved scoped resource cleanup syntax; compiler support tracked by #907"
(defstruct Handle (id i64))

(define (open-handle [id : i64]) : Handle
  (Handle id))

(define (close-handle [h : Handle]) : unit
  unit)

(define (use-nested-handles) : i64
  (with ([outer (open-handle 1) close-handle])
    (+ (struct-get outer id)
       (with ([inner (open-handle 2) close-handle])
         (struct-get inner id)))))
```

Cleanup runs when the body exits normally. Once recoverable propagation syntax
lands (#903), cleanup also runs before a recoverable early return leaves the
scope. Already-initialized earlier bindings are cleaned up when a later
initializer propagates a recoverable failure. Panic/abort remains terminal and
does not guarantee cleanup unless a future unwinding model explicitly says so.

```lisp test=ignore name=with-resource-recoverable-propagation reason="reserved scoped cleanup and recoverable propagation syntax; compiler support tracked by #907/#903"
(defstruct Handle (id i64))

(defenum ResultI64
  (OkI64 i64)
  (ErrI64 String))

(define (open-handle) : Handle
  (Handle 1))

(define (close-handle [h : Handle]) : unit
  unit)

(define (read-handle [h : Handle]) : ResultI64
  (OkI64 (struct-get h id)))

(define (read-with-cleanup) : ResultI64
  (with ([h (open-handle) close-handle])
    (try (read-handle h))))
```

Cleanup functions return `unit`; any cleanup value is ignored. A cleanup
function that panics aborts the program, and the language does not guarantee
that remaining cleanup functions run after that abort.

A resource-bound value may not escape its `with` scope. It cannot be returned
as the result of the `with` form, stored into an outer binding or global, or
captured by a closure whose lifetime outlives the scope. The resource may be
used to compute a non-resource result before cleanup runs.

```lisp test=ignore name=with-resource-reject-escape reason="negative example for future scoped resource cleanup checks"
(defstruct Handle (id i64))

(define (open-handle) : Handle
  (Handle 1))

(define (close-handle [h : Handle]) : unit
  unit)

(define (leak-handle) : Handle
  (with ([h (open-handle) close-handle])
    h))
```

Ordinary `let` has no cleanup behavior. A binding is cleaned up only when it is
introduced by `with`, with an explicit cleanup function in the binding.
For cleanup-owning aggregate types (section 4.6.1), the explicit cleanup
function must be the aggregate type's declared cleanup function. The field
cleanup plan is then run by that aggregate cleanup function; `with` itself still
only owns the bound value and invokes one cleanup function per binding.

```lisp test=ignore name=ordinary-let-does-not-cleanup reason="illustrates distinction from future scoped cleanup syntax"
(defstruct Handle (id i64))

(define (open-handle) : Handle
  (Handle 1))

(define (use-handle-without-cleanup) : i64
  (let ([h (open-handle)])
    (struct-get h id)))
```

---

### 5.20 `(unsafe body ...)` and raw pointer operations (v1 design; implemented)

`unsafe` is the v1 source marker for operations whose safety cannot be proven by
the TypeLisp typechecker. The form is an expression block like `begin`: it
evaluates one or more body expressions in order and returns the last value.

```lisp test=ignore name=unsafe-pointer-read-example reason="requires an external pointer provider"
(extern first-byte : (-> (Ptr u8)))

(define (main) : i64
  (unsafe
    (cast (ptr-read (first-byte)) : i64)))
```

An unsafe context does not disable normal type checking. It only permits forms
that are rejected in safe code because they can violate memory safety, ABI
contracts, aliasing assumptions, or region lifetime rules. Unsafe functions,
unsafe declarations, and "unsafe by default" modules are deferred; v1 has only
the expression/block form.

Initial raw pointer operation set:

| Form | Safe? | Type rule | Notes |
|------|-------|-----------|-------|
| `(ptr-null : (Ptr T))` / `(ptr-null : (MutPtr T))` | Yes | returns the requested raw pointer type | Constructs a typed null pointer. |
| `(ptr-null? p)` | Yes | raw pointer -> `bool` | Does not dereference `p`. |
| `(ptr-read p)` | Unsafe | `(Ptr T)` or `(MutPtr T)` -> `T` | Reads `sizeof(T)` bytes at `p`; alignment, validity, initialization, and lifetime are caller obligations. |
| `(ptr-write! p value)` | Unsafe | `(MutPtr T)` and `T` -> `unit` | Writes `sizeof(T)` bytes; writing through `(Ptr T)` is rejected. |
| `(ptr-offset p n)` | Unsafe | raw pointer and integer -> same raw pointer type | Adds `n * sizeof(T)` bytes. Negative offsets are allowed but unsafe. |
| `(ptr-cast p : (Ptr T))` / `(ptr-cast p : (MutPtr T))` | Unsafe | raw pointer -> requested raw pointer type | Includes const/mutable pointer casts; no implicit `MutPtr` to `Ptr` coercion in v1. |
| `(ptr->int p)` | Unsafe | raw pointer -> `u64` | Exposes the target address representation. |
| `(int->ptr n : (Ptr T))` / `(int->ptr n : (MutPtr T))` | Unsafe | integer -> requested raw pointer type | Address validity is entirely outside the typechecker. |

Deferred raw pointer operations: address-of local/global/field expressions,
slice views, C string helpers, volatile/atomic access, provenance tracking,
pointer comparisons beyond `ptr-null?`, pointer-to-function casts, and any
borrow-checked reference surface. Those are follow-ups to the raw pointer/FFI
track (#809/#897/#911/#912) and the safe reference/ownership track (#182).

---

## 6. Built-in functions and runtime

### 6.1 Builtin functions (lowered to IR calls)

| Builtin | Signature | Description |
|---------|-----------|-------------|
| `print` | `i64 → unit` | Print integer to stdout + newline |
| `print-bool` | `bool → unit` | Print `true`/`false` to stdout + newline |
| `print-float` | `f64 → unit` | Print floating-point value to stdout using `%.17g` + newline |
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
| `append-file-status` | `String String → i64` | Append contents without truncating, create the file when missing, and return 0 on success or a positive host status code |
| `file-exists-status` | `String → i64` | Return 0 when a path exists, otherwise a positive host status code such as not-found |
| `file-open-status` | `String i64 → i64` | Open a runtime-managed file-handle slot; return a positive handle id on success or a negative host status code |
| `file-close-status` | `i64 → i64` | Close a runtime-managed file-handle slot; return 0 on success or a positive host status code |
| `file-read-chunk-status` | `i64 i64 → i64` | Read once from a runtime-managed handle into the per-handle last-read slot; return 0 on success or a positive host status code |
| `file-write-status` | `i64 String → i64` | Write all bytes from a `String` to a runtime-managed write handle; return 0 on success or a positive host status code |
| `file-flush-status` | `i64 → i64` | Flush a runtime-managed write handle; return 0 on success or a positive host status code |
| `file-read-chunk-bytes` | `i64 → String` | Return the bytes stored by the last successful `file-read-chunk-status` call for a handle |
| `file-read-chunk-eof?` | `i64 → bool` | Return the sticky EOF state stored by the last successful `file-read-chunk-status` call for a handle |
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
- The table above records the currently implemented compatibility signatures.
  The v1 owned `String` / borrowed `str` contract in section 3.11 changes
  non-consuming text inputs to `(& lifetime str)` while preserving owned
  `String` results for allocating operations.

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
| `.L_tl_file_open_status` | Open a runtime-managed file-handle slot |
| `.L_tl_file_close_status` | Close a runtime-managed file-handle slot |
| `.L_tl_file_write_status` | Write all bytes from a string to a runtime-managed write handle |
| `.L_tl_file_flush_status` | Flush a runtime-managed write handle |
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

### 6.4 Stdlib file I/O handles (v1)

This section specifies the v1 source-level file-handle API for `stdlib/io.tl`.
Open/close support is implemented by #1056, streaming reads are implemented by
#1057, and streaming writes/flush are implemented by #1058. The handle API reuses the
existing `IoError` model already in `stdlib/io.tl` (§9 catalogs the variants);
it does not introduce a new error vocabulary.

**Handle type.** A file handle is an opaque value `FileHandle`. Source-level
TypeLisp v1 treats it as opaque: programs obtain it from `file-open`, pass it to
read/write/close helpers, and never inspect its representation. Internally the
handle carries an id into a runtime-managed table that stores the host
descriptor, open mode, and open/closed state; these fields are not part of the
public contract and may change. A handle is an aggregate value and follows the
move-only source contract in section 4.6.2 once that checker lands. Until then,
implementations may represent it as a copyable numeric handle internally, but
source code should treat each successful `FileHandle` as a single owner that is
closed exactly once. There is no implicit close yet; scoped cleanup waits on
#805.

**Open modes.** `file-open` takes a path and an `OpenMode`:

| Mode | Meaning |
|------|---------|
| `OpenRead` | Open an existing file for reading. A missing file yields `IoNotFound`. |
| `OpenWriteTruncate` | Open for writing, creating the file when missing and truncating it to zero length otherwise. |
| `OpenWriteAppend` | Open for writing at end-of-file, creating the file when missing and never truncating existing contents. |

A combined read/write mode is explicitly deferred past v1.

**Open / close.**

| Helper | Signature | Behavior |
|--------|-----------|----------|
| `file-open` | `String OpenMode → ResultIoFile` | `OkIoFile FileHandle` on success; `ErrIoFile IoError` for empty paths (`IoInvalidPath`), missing files in read mode (`IoNotFound`), permission failures (`IoPermissionDenied`), and other host status codes mapped through `io-error-from-status`. |
| `file-close` | `FileHandle → ResultIoUnit` | `OkIoUnit` on the first close. Closing an already-closed handle returns `ErrIoUnit (IoUnsupported ...)` rather than panicking. |

`ResultIoFile` is a new monomorphic result enum mirroring the existing pattern:
`(OkIoFile FileHandle)` / `(ErrIoFile IoError)`.

**Close / lifetime semantics (v1).** v1 requires explicit `file-close`. There is
no destructor, drop glue, or implicit close — a handle that is never closed
leaks its host descriptor for the life of the process, matching TypeLisp's
current no-reclamation memory direction (§7.3). Use-after-close (any read or
write on a closed handle) and double-close return a structured `IoUnsupported`
error for stale handles that reach the runtime; they never panic and never touch
a host descriptor. Once move checking is enforced, ordinary source-level double
close through the same variable is rejected earlier as use-after-move. Automatic
close on scope exit is still deferred to scoped cleanup work.

**Streaming reads (#1057).** `file-read-chunk` reads up to a requested byte count
from a read-mode handle:

| Helper | Signature | Behavior |
|--------|-----------|----------|
| `file-read-chunk` | `FileHandle i64 → ResultIoRead` | Read up to `count` bytes; `OkIoRead FileRead` carries the bytes read plus a sticky EOF flag. |

`FileRead` mirrors the shape of the existing `StdinRead` aggregate (a `String`
payload plus a sticky `eof` flag):

```
(defstruct FileRead
  (bytes String)
  (eof bool))
```

- A read returns up to `count` bytes. A returned chunk shorter than `count` does
  not by itself indicate EOF — a short read may be a partial read. EOF is
  reported only through the `eof` flag, which becomes true once the host read
  reaches end-of-file.
- A zero-length read (`count` = 0) performs no host read, returns an empty
  `bytes` string, and reports the current EOF state deterministically.
- A read at EOF returns an empty `bytes` string with `eof` = true.
- A negative `count` returns `ErrIoRead (IoInvalidPath ...)` (an argument error)
  without performing a host read.
- Reading a write-only handle (`OpenWriteTruncate` / `OpenWriteAppend`) returns
  `ErrIoRead (IoUnsupported ...)`.
- Reading a closed or otherwise invalid handle returns
  `ErrIoRead (IoUnsupported ...)`.
- Interrupted host reads map through `io-error-from-status` to `IoInterrupted`;
  other host failures map to their `IoError` variant or `IoSystemCode`.

`ResultIoRead` is a new monomorphic result enum: `(OkIoRead FileRead)` /
`(ErrIoRead IoError)`.

**Text vs. binary (v1).** Like `StdinRead`, `FileRead` carries chunk data as a
`String`: a chunk is the raw bytes read, stored in a `String`, with no
text/binary distinction in v1. This remains source-compatible; future binary
buffer work should use a dedicated byte-slice/buffer type rather than mutable
`str`, because section 3.11 defines `str` as immutable borrowed text/bytes.
Returned chunk strings allocate in the active arena, the same as `read-file`
and `StdinRead`.

**Streaming writes / append (#1058).** Streaming writes reuse `ResultIoUnit`:

| Helper | Signature | Behavior |
|--------|-----------|----------|
| `file-write` | `FileHandle String → ResultIoUnit` | Write the complete string payload to a write-mode handle. |
| `file-flush` | `FileHandle → ResultIoUnit` | Flush pending writes for a write-mode handle. |

- `file-write` on an empty string succeeds without issuing a host write.
- The runtime retries host short writes until all bytes are accepted. A host
  error maps through `io-error-from-status`; a zero-byte host write before all
  bytes are written maps to `IoSystemCode 5` / the common I/O error status.
- Writing to an `OpenRead` handle returns `ErrIoUnit (IoUnsupported ...)`.
- Writing or flushing a closed, invalid, or unsupported handle returns
  `ErrIoUnit (IoUnsupported ...)`.
- `file-flush` on an `OpenRead` handle returns `ErrIoUnit (IoUnsupported ...)`;
  host flush failures map through `io-error-from-status`.
- `OpenWriteTruncate` starts from an empty file and writes advance the handle's
  file offset. `OpenWriteAppend` defines append semantics: create-if-missing,
  never truncate, and — where the host supports an append open mode (Linux
  `O_APPEND`) — each write lands at the current end of file. This matches the
  whole-file `try-append-file` helper, which uses the recoverable
  `append-file-status` runtime primitive instead of read-modify-write.

**Platform policy.** Linux is the reference target and must implement all three
modes plus streaming reads and writes. On Windows, the handle API either works
(through the equivalent Win32 file calls) or returns a structured `IoUnsupported`
result for any mode or operation not yet implemented there, following the same
pattern as the Windows `try-create-temp-dir` behavior. No operation panics for an
unsupported platform; callers always receive an `IoError`.

**Scope.** The #1056 open/close subset, #1057 streaming reads, and #1058
streaming writes/flush are implemented for the stdlib API and selfhost backend,
with Windows returning structured `IoUnsupported` results until native handle
support lands.

---

## 7. Memory model

TypeLisp currently has syntax/type-model support for written reference types
(`(& arena T)` and `(&mut arena T)`) and SPEC-level immutable borrow expression
rules (`(& place)` / `(& arena place)`), including the borrowed `str` source
contract in section 3.11, but the source-level borrow checker is not
implemented yet. There is no implicit destructor, `drop`, `free`, or
garbage-collector model. Section 4.6.2 specifies move-only aggregate handle
ownership for v1 source semantics, but the current compiler may still accept
aggregate copies until the selfhost move checker lands. The
implementation uses pointer-sized handles for several aggregate values, but
those handles are not checked references in the source language. Full
ownership/borrowing work is a separate design track. The reserved
`(with ...)`
form (§5.19) is explicit non-memory resource cleanup; it is not a general
object destructor or heap reclamation mechanism. Raw pointers are the explicit
low-level exception: their v1 syntax is specified, but they carry no safety
guarantees and are not implemented yet (#809/#896).

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

General per-object `free`, implicit destructors, and borrowed references are not
part of this v1 policy. Aggregate handles are represented as pointer-shaped
runtime values, and dynamic arrays are shared mutable buffers, so adding
arbitrary `free` before move checking and borrow semantics are enforced would
make double-free and use-after-free errors expressible. Ownership, borrowing,
and reference work is a separate design track (#25, #182).

A tracing garbage collector is also not the first reclamation step. It would
need object metadata, root discovery or stack maps, runtime scanning policy, and
coverage across every aggregate allocation shape. That may be revisited later,
but it is larger than the immediate need for long-running tools.

The first reclamation mechanism is explicit region reset at tool-owned phase
boundaries (#418, #419). TypeLisp provides two surfaces for this:

#### Source-level scoped region (v1) — `with-arena`

The `(with-arena ident body ...)` form (§5.16) gives programs a lexically
scoped, type-safe region. The typechecker ensures no region-tagged value
escapes the body, so the lowering can safely insert `tl_region_mark` at entry
and `tl_region_reset` at exit without risk of use-after-free. This is the
preferred v1 surface for long-running tools that want deterministic, safe
reclamation between phases.

```lisp test=check name=with-arena-example
(define (process-phase [input : String]) : i64
  (with-arena phase
    (let
      [buf : (Array i64) (make-array i64 100)]
      (begin
        (array-set! buf 0 42)
        (array-ref buf 0)))))
```

Allocation sites inside a `with-arena` scope target the active region:
- String operations that create fresh storage (`substring`, `string-append`,
  `string-concat`, `read-file`, `int->string`, `arg`), `make-array`, `box`, and
  returned aggregate storage from calls inside the region.
- The body result must be region-free (scalars, or aggregates allocated *before*
  the `with-arena`).

The arena-model terminology calls the default allocation target the
program-lifetime arena and calls each nested `with-arena` body a scoped arena.
Unless a function explicitly says otherwise, allocation always uses the active
arena: the innermost scoped arena, or the default program-lifetime arena when
no scoped arena is active. Executable stdlib policy tests use `with-arena` to
verify these active-arena semantics.

#### Standard library and builtin allocation policy

Written reference and arena lifetime syntax exists, but current stdlib
signatures still use compatibility `String`/aggregate types until the borrowed
`str` frontend and API migration land (#1453/#1454/#1082). The checker
therefore conservatively treats aggregate results from calls inside a scoped
arena as tagged with that arena. This is stricter than the future model for
functions that may return caller-owned data, but it prevents active-arena
values from escaping until explicit lifetime signatures are attached to the
stdlib surface.

| Category | Members | Arena behavior |
|----------|---------|----------------|
| Non-allocating inspection | `length`/`array-length` on arrays, `length`/`string-length`, `string-ref`/`char-at`, `string-eq`/`string=?`, `string->int`, stdlib string predicates such as `string-contains` | Reads caller-provided handles and returns scalars. |
| Returns active-arena owned data | `make-array`, `box`, `arg`, `read-file`, `file-read-chunk`, `read-stdin-line`, `read-stdin-bytes`, `string-append`/`string-concat`, `substring`/`string-slice`, `int->string`, stdlib trimming/replacement helpers when they build a new string | Fresh storage is allocated in the active arena and cannot escape a scoped arena. |
| Returns caller-provided data | `stdlib/string.tl` `string-replace` when no match is found; `stdlib/io.tl` `read-file-or` when the path is missing | The current type system cannot express this borrowed/caller-owned distinction, so calls inside a scoped arena are still treated conservatively as arena-tagged aggregate results. |
| Mutates caller-provided storage | `array-set!` | Mutates the array buffer named by the caller; it does not allocate. Region checks reject storing shorter-lived aggregate handles into longer-lived containers. |
| Host/runtime IO | `print*`, `panic`/`error`, `flush-stdout`, `write-file`, `file-exists?`, stdlib IO helpers | Performs target IO; any temporary strings used by the helper allocate in the active arena. |

The owned `String` / borrowed `str` source contract is specified in section
3.11, but no current stdlib function has migrated to a borrow-typed `str`
signature. No current stdlib function manually resets arenas; safe scoped
cleanup is owned by `with-arena`. Source code that needs manual arena control
uses the first-class arena helpers, with `arena-set!`, `arena-destroy`, and
`arena-rewind` gated by `(unsafe ...)`.

Nested `with-arena` forms create independent subregions whose values do not
mix. Inner-region values cannot escape to the outer region; outer-region values
can be used inside the inner region without restriction (they carry the outer
tag, not the inner one).

On non-Linux targets `with-arena` still type-checks and scopes but does not
reclaim, matching the semantic contract minus the reset.

#### First-class scratch arena escape - `with-escape`

Compiler internals and long-running tools may allocate a first-class scratch
arena with `arena-make`, switch to it for transient work, and then keep only a
deep-cloned result. The safe source form for this pattern is:

```lisp test=ignore name=with-escape-example reason="depends on first-class arena runtime support"
(define (build-message) : String
  (let
    [scratch : i64 (arena-make)]
    (with-escape scratch
      (string-append "answer " (int->string 42)))))
```

`with-escape` evaluates the arena expression in the current arena, records the
enclosing active arena, switches to the scratch arena, marks it, evaluates the
body, switches back to the enclosing arena, clones the body result when the type
requires it, rewinds the scratch arena to the entry mark, and restores the
enclosing active arena. This lowers to the same `arena-current` / `arena-set!` /
`arena-mark` / `clone` / `arena-rewind` sequence that hand-written escape sites
used before. The form is intended for first-class scratch arenas; lexical region
cleanup remains the job of `with-arena`.

#### Scoped non-memory resources (reserved) - `with`

The reserved `(with ([name init cleanup] ...) body ...)` form (§5.19) is the
source surface for deterministic cleanup of non-memory resources. It does not
select an allocation arena and does not reset heap storage. Cleanup is explicit
in the binding and must return `unit`; TypeLisp still has no implicit
destructors or automatic `drop`.

This keeps resource lifetime policy independent from arena lifetime policy:
files, process handles, locks, mapped files, and temporary paths use `with`;
heap allocation reclamation uses `with-arena` or explicit unsafe arena
operations below. Cleanup-owning aggregates (section 4.6.1) use the same `with`
owner scope plus a declared aggregate cleanup function for the field cleanup
plan. Compiler support is tracked by #907, with move-only enforcement tracked
separately.

#### Manual arena helpers

Programs that need manual control can use the first-class arena helpers:

```lisp test=check name=arena-manual-helpers
(define (main) : unit
  (let
    [arena : i64 (arena-current)]
    [mark : i64 (arena-mark)]
    (unsafe
      (arena-rewind mark)
      (arena-set! arena)
      (arena-destroy arena))))
```

`arena-make`, `arena-current`, and `arena-mark` are safe: they create an arena
handle, read the active arena handle, or record the active arena bump pointer.
By themselves they do not switch the active arena, free arena chains, rewind
allocation, or invalidate live safe handles.

`arena-set!`, `arena-destroy`, and `arena-rewind` require `(unsafe ...)`.
`arena-set!` switches the active arena, `arena-destroy` frees an arena chain, and
`arena-rewind` restores a mark by discarding newer arenas and moving the marked
arena's bump pointer back to the mark. A rewind invalidates every heap handle
allocated after that mark, so it is only valid when the caller can prove those
values are dead, such as after a compiler, formatter, package-tooling, or REPL
iteration has discarded all phase-local results. These helpers are not a safe
arbitrary source-level `free` replacement. Taking one of these invalidating
helpers as a first-class function value also requires an unsafe context. The safe
`with-arena` surface remains preferred.

### 7.4 Raw pointers and unsafe memory access (v1 design)

Raw pointers are address values. They do not own allocation, keep regions alive,
or prove that pointed-to storage is initialized, aligned, in-bounds, mutable, or
valid for the requested type.

- `(Ptr T)` and `(MutPtr T)` are both 8-byte pointer-sized values on supported
  targets.
- Raw pointers are nullable and copyable. `ptr-null` creates a typed null
  pointer, and `ptr-null?` checks for null without dereferencing.
- Pointer equality, ordering, provenance, and bounds are otherwise unspecified
  in v1. Only null testing is part of the safe surface.
- `ptr-read`, `ptr-write!`, `ptr-offset`, `ptr-cast`, `ptr->int`, and
  `int->ptr` require `(unsafe ...)` because the typechecker cannot prove their
  memory or ABI preconditions.
- A raw pointer into memory reclaimed by `with-arena`/`tl_region_reset` becomes
  invalid when that region is reset. The typechecker does not track this for raw
  pointers.
- Extern functions may return or accept raw pointers. The ABI contract is
  explicit in the signature but still unsafe: a `(Ptr T)` return may be null,
  dangling, misaligned, or point to fewer than `sizeof(T)` bytes unless the
  foreign API says otherwise.

Raw pointers are for FFI and carefully isolated low-level runtime code. They are
not the future safe reference/borrow model (#182), not a replacement for
`with-arena`, and not a general manual memory management feature.

### 7.5 Globals

- Stored in the `.data` or `.rodata` section.
- Mutable globals use `.data` with an initializer.
- String literal bytes are stored in `.rodata`; a `String` value points to
  inline `{ptr,len}` storage whose `ptr` field points into `.rodata`.

### 7.6 Aggregate handles, moves, and aliasing

- The IR/ABI may represent `String`, dynamic-array, tuple, struct, enum, and
  closure values as pointer-sized handles. Bit-copying such a handle aliases the
  same backing storage, but source-level v1 treats aggregate by-value use as a
  move under section 4.6.2 rather than as a user-visible copy operation.
- Non-consuming inspection builtins are borrow-like compatibility operations
  until reference-typed parameters land. They can read an aggregate handle
  without moving it, but ordinary user-defined function parameters remain
  by-value and therefore consume aggregate arguments.
- `String` values are immutable at the source level. String literals may share
  `.rodata`; `substring`, `string-slice`, `string-append`, `string-concat`,
  `read-file`, `arg`, and `int->string` return fresh heap-allocated string
  storage. There is no source operation that mutates a string's bytes.
- Dynamic arrays are mutable heap buffers. `array-set!` mutates the buffer named
  by the live owner handle under the temporary compatibility rule in section
  4.6.2. Explicit shared mutable aliases require future reference/borrow
  semantics rather than copying the array handle.
- Struct and enum values are pointer-sized aggregate handles internally.
  Structs are read-only at the source level today because `struct-set!` is not
  implemented. Enum payloads are consumed by a by-value `match`; borrowing a
  scrutinee for non-consuming pattern inspection is deferred to the borrow
  checker.
- Returning an aggregate may heap-promote storage that would otherwise be
  frame-local. This is storage placement for safety; ownership transfer is still
  governed by the source-level move rules.
- `(clone value)` is the explicit deep-copy operation for values that must not
  share aggregate backing storage with the source. Cloneable types are scalars,
  `unit`, `never`, `String`, tuples whose elements are cloneable, fixed arrays
  whose elements are cloneable, dynamic arrays whose elements are cloneable, and
  named structs/enums whose fields or payloads are cloneable. Scalars return the
  same value; aggregate clones allocate fresh storage in the current active
  arena and recursively clone nested cloneable elements. Named structs/enums use
  compiler-generated `clone$Type` helpers.
- `clone` rejects unsupported ownership/lifetime forms rather than silently
  bit-copying them. Unsupported clone operands include function values,
  references including borrowed `str`, raw pointers, boxes, compile-time-only
  values, and named aggregate shapes containing non-cloneable fields.

```lisp test=ignore name=dynamic-array-aliasing reason="current compiler aliasing behavior; future move checker rejects copied array handles"
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
  `file-exists?`, `file-open`, `file-close`, `file-read-chunk`,
  `read-stdin-line`, `read-stdin-bytes`, `stdin-eof?`, `flush-stdout`.
- First-class arena helpers: `arena-make`, `arena-current`, `arena-mark`,
  `arena-set!`, `arena-destroy`, and `arena-rewind`; invalidating helpers
  require `(unsafe ...)`.
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
| Aggregate-element reference captures in lambdas | Not implemented (by-value captures work for scalars, String, dynamic arrays, tuples/structs/enums, and fixed arrays, including nested aggregate/fixed-array contents) |
| Mutable captures (`set!` to captured names) in lambdas | Not implemented |
| Tail call optimization | Not implemented |
| `struct-set!` | Not implemented |
| Raw pointer types and `(unsafe ...)` | Implemented v1 parser/typechecker/lowering/backend surface |
| Raw pointer dereference/write/offset/cast | Implemented unsafe v1 operations; address-of, C-string helpers, volatile/atomic access, and borrow-checked references remain follow-ups |
| Garbage collection / general `free` | Not implemented; allocation is process-lifetime by default with unsafe explicit region reset for tool-owned phase boundaries |
| Move-only aggregate handle checking | Specified for v1 source semantics; selfhost checker implementation pending (#1048/#1049) |
| `(with ...)` scoped non-memory resource cleanup | Specified and reserved; parser/typechecker/lowering support pending |
| Cleanup-owning aggregate declarations | Specified for structs and reserved for enums; parser/typechecker/lowering support pending |
| SPMD / SIMD `foreach` | Scalar reference lowering implemented; AVX2 supports a first contiguous map/zip subset |
| SPMD reductions and public cross-lane ops | Source semantics specified; parser/typechecker/lowering/backend support pending |
| Runtime SIMD dispatch (`defdispatch`) | Source semantics specified; parser/typechecker/lowering/backend support pending |
| Windows region helpers | `tl_region_mark`/`tl_region_reset` are Linux-only |
| Complete source locations for all semantic errors | Partial |
| REPL evaluation | Selfhost REPL bare expressions run through scratch build/run execution; public selfhost CLI routing is implemented |
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

Recoverable failures are represented with ordinary concrete enums. TypeLisp
does not expose generic `Option<T>` / `Result<T,E>` type syntax, generic
functions, traits, trait objects, vtables, or runtime type-erased dispatch for
recoverable errors. Reuse comes from comptime-generated concrete declarations:
the generator emits nominal enum types and helper functions for the requested
payload/error type keys.

The generated-family identity is a stable key, not a runtime type object:

- Absence-only family key: `option:<payload-type-key>`.
- Recoverable-error family key:
  `result:<success-type-key>:<error-type-key>`.
- Generated declaration keys also include the generator module identity and
  generator identity from #893, so repeated requests for the same family reuse
  the same concrete declarations or report a precise duplicate according to the
  generated-declaration policy.
- Display names are deterministic ASCII identifiers derived from those keys,
  for example `Option_String`, `Result_String_IoError`, `Some_String`,
  `None_String`, `Ok_String_IoError`, and `Err_String_IoError`. Exact
  mangling is compiler-owned, but generated names must be stable, readable in
  diagnostics/docs, and collision-free within the value/type namespaces.

Until the generator lands, hand-written monomorphic enums are the source
equivalent. Use `Maybe*` or `Option*` names for absence-only APIs and `Result*`
names for APIs that distinguish success from an error value. Matches must be
exhaustive; omitted variants are rejected by the type checker.

```lisp test=compile name=monomorphic-option-result
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

Propagation uses the Lisp-shaped `(try expr)` form. It is analogous to Rust
`?` or Zig `try`, but it operates on concrete generated families rather than
generic traits or implicit conversions.

- For a recoverable-error result, `(try expr)` evaluates `expr` once. On the
  success variant it unwraps and yields the success payload. On the error
  variant it returns from the enclosing function with the compatible error
  variant carrying the same error payload.
- For an absence-only option, `(try expr)` unwraps `Some*` and returns the
  enclosing compatible `None*` on absence.
- V1 compatibility is exact-family compatibility. There is no trait-like
  `From` conversion, no cross-family conversion, and no implicit
  Option-to-Result conversion; explicit conversion helpers may be generated by
  later stdlib/comptime work.
- `(try expr)` is valid only inside an enclosing function whose return type is
  a compatible generated family or convention-compatible concrete family.
- `(try expr)` is rejected when `expr` is not a result/option family, when the
  enclosing function is not result/option-producing, when the error/absence
  family is incompatible, or when manual matches over these enums are
  non-exhaustive.

```lisp test=ignore name=result-try-success reason="selfhost-only try propagation; spec harness does not yet run this case"
(defenum ResultI64
  (OkI64 i64)
  (ErrI64 String))

(define (read-small [text : String]) : ResultI64
  (if (string-eq text "7")
    (OkI64 7)
    (ErrI64 (string-append "bad: " text))))

(define (read-plus-one [text : String]) : ResultI64
  (let ([value : i64 (try (read-small text))])
    (OkI64 (+ value 1))))
```

```lisp test=ignore name=result-try-incompatible-error reason="selfhost-only negative propagation example; should be an expect-error once the spec harness supports try diagnostics"
(defenum ResultI64
  (OkI64 i64)
  (ErrI64 String))

(defenum ResultBool
  (OkBool bool)
  (ErrBool bool))

(define (read-small [text : String]) : ResultI64
  (if (string-eq text "7")
    (OkI64 7)
    (ErrI64 (string-append "bad: " text))))

(define (bad-propagation [text : String]) : ResultBool
  (let ([value : i64 (try (read-small text))])
    (OkBool (> value 0))))
```

Panic remains separate from recoverable results. It aborts instead of producing
an error variant, and its internal bottom type can still inhabit a
result-returning branch:

```lisp test=compile name=panic-vs-result
(defenum ResultI64
  (OkI64 i64)
  (ErrI64 String))

(define (read-or-abort [ok : bool]) : ResultI64
  (if ok
    (OkI64 7)
    (panic "not recoverable")))
```

Current implementation status: selfhost has the `(try expr)` Result-like v1 for
the convention of a concrete enum with one `Ok*` payload variant and one `Err*`
payload variant. Generated concrete Option/Result families and reusable helper
bundles are tracked by #902 on top of #893/#913.

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
  build             Build nearest typelisp.pkg artifact
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
                          scalar is the default, while avx2 and avx512
                          support the first contiguous foreach map/zip subset
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
`build` does not run the executable. The package build form writes the artifact
selected by `typelisp.pkg`'s `kind` field.

Linux native build/run uses `as` and `ld`. Windows native build/run uses
`clang --target=x86_64-pc-windows-msvc` and `lld-link`, links against the CRT,
and emits a console `.exe`.

`tokenize`, `parse`, and `check` are also accepted as top-level compatibility
aliases for the corresponding `debug` commands.

The selfhost `repl` driver supports `.help`, `.type <expr>`, and `.exit`.
Top-level declarations are remembered for later commands. `.type` parses and
typechecks the expression against the current session and prints the inferred
type without compiling or running native code. Bare expressions are typechecked
against the current session, compiled into a scratch `main`, run through the
selfhost source build/run path, and discarded without becoming session
declarations.

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
| `(Ptr T)` / `(MutPtr T)` | 8 | 8 |
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

### Raw pointer FFI sketch

```lisp test=ignore name=raw-pointer-ffi-sketch reason="requires an external pointer provider"
(extern c-buffer : (-> (MutPtr u8)))

(define (main) : i64
  (let
    [p : (MutPtr u8) (c-buffer)]
    (if (ptr-null? p)
      1
      (unsafe
        (begin
          (ptr-write! p 65)
          (cast (ptr-read p) : i64))))))
```

---

## 13. Grammar (informal)

```
program       ::= top-level*

top-level     ::= define-var
                | define-func
                | dispatch-decl
                | defmacro
                | extern-decl
                | module-decl
                | import-decl
                | export-decl
                | defenum
                | defstruct
                | test-decl

define-var    ::= "(" "define" ident [":" type] expr ")"
define-func   ::= "(" "define" "(" ident param* ")" [":" type] expr ")"
dispatch-decl ::= "(" "defdispatch" ident dispatch-variant+ ")"
dispatch-variant ::= "(" dispatch-isa ident ")"
dispatch-isa  ::= "scalar" | "avx2" | "avx512"
defmacro      ::= "(" "defmacro" "(" ident macro-operand* ")" ":" type expr+ ")"
macro-operand ::= "[" ident ":" type "]"
                | "[" ident ":" type "..." "]"      ; variadic final operand only
extern-decl   ::= "(" "extern" ident extern-meta* ":" type ")"
extern-meta   ::= "(" ":abi" "c" ")"
                | "(" ":symbol" string ")"
                | "(" ":link-lib" string ")"
                | "(" ":link-search" string ")"
                | "(" ":link-arg" string ")"
module-decl   ::= "(" "module" module-ident ")"
import-decl   ::= "(" "import" string [":as" ident] ")"
export-decl   ::= "(" "export" export-item+ ")"
export-item   ::= "(" "value" ident ")"
                | "(" "type" ident ")"
                | "(" "macro" ident ")"
                | "(" "constructor" ident ")"
                | "(" "field" ident ident ")"
                | "(" "variant" ident ")"
defenum       ::= "(" "defenum" ident enum-meta* variant+ ")"
defstruct     ::= "(" "defstruct" ident struct-meta* field+ ")"
struct-meta   ::= "(" ":repr" "c" ")"
                | aggregate-cleanup-meta
enum-meta     ::= aggregate-cleanup-meta       ; reserved, rejected in v1
aggregate-cleanup-meta ::= "(" ":cleanup" ident ")"
test-decl     ::= "(" "test" ident expr+ ")"

param         ::= "[" ident ":" type "]"
field         ::= "(" ident type field-meta* ")"
field-meta    ::= "(" ":cleanup" ident ")"
                | "(" ":owned" ")"
variant       ::= "(" ident variant-payload* ")"
variant-payload ::= type field-meta*           ; payload cleanup metadata reserved, rejected in v1

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
                | "(" "with-arena" ident expr+ ")"
                | "(" "with-escape" expr expr+ ")"
                | "(" "with" "(" resource-binding* ")" expr+ ")"
                | borrow-expr                 ; specified, not implemented
                | "(" "unsafe" expr+ ")"
                | "(" "ptr-null" ":" ptr-type ")"
                | "(" "ptr-null?" expr ")"
                | "(" "ptr-read" expr ")"
                | "(" "ptr-write!" expr expr ")"
                | "(" "ptr-offset" expr expr ")"
                | "(" "ptr-cast" expr ":" ptr-type ")"
                | "(" "ptr->int" expr ")"
                | "(" "int->ptr" expr ":" ptr-type ")"
                | "(" "comptime" expr ")"
                | "(" "type" type ")"
                | "(" "size-of" expr ")"
                | "(" "align-of" expr ")"
                | "(" "offset-of" expr ident ")"
                | "(" expr expr* ")"          ; function call

borrow-expr   ::= "(" "&" borrow-place ")"
                | "(" "&" ident borrow-place ")"
borrow-place  ::= ident
                | "(" "struct-get" borrow-place ident ")"
                | "(" "tuple-ref" borrow-place integer ")"
                | "(" "array-ref" borrow-place expr ")"

binding       ::= "[" ident [":" type] expr "]"
resource-binding ::= "[" ident expr expr "]"  ; name init cleanup-fn
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
                | "str"                               ; borrowed referent only
                | "Expr" | "ExprList"               ; compile-time-only macro body values
                | "(" "Tuple" type+ ")"
                | "(" "Array" type [integer] ")"
                | ptr-type
                | ref-type
                | macro-type
                | "(" "->" type+ ")"
                | "(" "in" ident type ")"              ; region-tagged (v1)
                | ident                                ; enum or struct name

ptr-type      ::= "(" "Ptr" type ")"
                | "(" "MutPtr" type ")"

ref-type      ::= "(" "&" ident type ")"
                | "(" "&mut" ident type ")"

macro-type    ::= "(" "macro" "(" macro-type-slot* ")" type ")"
macro-type-slot ::= type
                  | type "..."                         ; variadic final slot only

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
