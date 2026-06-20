# TypeLisp Language Specification

> **Version:** 0.1.0-dev  
> **Targets:** x86_64 Linux (System V AMD64 ABI) and x86_64 Windows (Win64 ABI). macOS and ARM are not supported yet and are not near-term goals.  
> **Constraint:** self-hosted TypeLisp implementation; zero third-party dependencies.

This document specifies the TypeLisp language as implemented today. It is the ground truth for what compiles, what types mean, and what the backend promises.

---

## 1. Overview

TypeLisp is a statically typed Lisp/Scheme dialect that compiles to native x86_64 assembly. Every expression has a known type at compile time. There is no runtime type tagging, no garbage collector, and no interpreter.

### Design goals

The language is built around these pillars; later sections give the binding
contracts for each.

- **Typed.** Every expression has a known type at compile time; no runtime
  type tagging.
- **Native.** Programs compile straight to x86_64 machine code for
  `linux-x86_64` and `windows-x86_64`. No bytecode VM, no interpreter, no
  garbage collector.
- **Self-hosted, zero dependencies.** Compiler, stdlib, tooling, and tests are
  written in TypeLisp; each published stage0 builds its own successor. The only
  build inputs are the native assembler/linker toolchain, and direct object
  emission is staged to remove the assembler dependency.
- **Safe.** Safe code has no undefined behavior (see the table below).
  Ownership, moves, lexical borrows, lifetimes, and arena regions are checked
  statically, in the spirit of Rust but with arenas instead of general `free`
  or garbage collection.
- **Comptime as the abstraction mechanism.** No source-level generics, traits,
  interfaces, or `impl`; Zig-style compile-time generation and typed macros
  produce concrete declarations (section 3.7).
- **SPMD data parallelism.** ISPC-style `foreach`/`spmd-reduce` with
  uniform/varying semantics and scalar-equivalent SIMD lowering (section 5.15).
- **Module identity.** C3-style modules where module identity participates in
  name resolution and symbol naming (section 4.4).
- **Fast.** Generated code quality should approach LLVM (`clang -O2`) on the
  benchmark corpus while compilation itself stays fast. Performance is tracked
  deterministically through paired C baselines and instruction-count CI gates;
  the codegen-quality roadmap is #2559.

### Decided directions (specified intent ahead of implementation)

Design decisions are recorded on their tracking issues; roadmap issue #8 is
the live index. The decisions below are settled direction for this
specification even where the corresponding sections still describe the
transitional surface:

- **Imports and names.** Dotted module-identity imports replace path imports
  (#2452-#2454); stdlib source names drop module prefixes in favor of
  qualified short names once that migration lands (#2582/#2583). Linker
  symbols already carry module-qualified names.
- **Core macro surface.** Bare prelude macros are canonical (#2581); `cond`
  uses bracket arms `(cond [test expr] ... [else fallback])` through the
  macro-owned bracket operand surface (#2578), and the flat call shape is
  rejected (#2579, reversing the #2490 retirement).
  Macros become order-independent within a module (#2584).
- **Comptime execution.** The public macro/comptime surface is ordinary
  stdlib-owned `Expr` and reflection data pinned as compiler-verified well-known
  types (#2647/#2653). A source stdlib selected with `--stdlib-root` executes
  macro/comptime code through CTFE; the embedded stdlib executes the same source
  as compiled code from an embedded `stdlib.tlci`, and the differential gate
  requires byte-identical expansions (#2658). Comptime code is pure safe
  TypeLisp with no `unsafe`, `extern`, or host I/O (#2648), and compiled
  comptime carries deterministic fuel checks equivalent to the CTFE fuel limit
  (#2656). Each package emits a `tlci` compile-time interface containing
  signature metadata and macro code when present; `lib<name>.a` remains the
  runtime half (#2651, #2655, #2659). The umbrella map is #2645.
- **Mutation.** In-place struct field mutation is written as
  `(set! (struct-get place field) value)` or, for a local receiver, dotted
  field sugar such as `(set! place.field value)` (#1521). Boxed storage supports
  destructive take with `(box-take b)` and in-place assignment with
  `(set! (box-get b) value)` (#2553), under the move/borrow rules in sections
  3.10 and 4.6.2.
- **Text and bytes.** `String`/`str` remain immutable text/byte views. Mutable
  binary storage uses the specified `ByteBuf` owner plus borrowed `bytes` views
  from section 3.11 (#2782), not mutable `str` and not `TextBuf`.
- **Memory and threads.** Each thread gets its own default arena; a shared
  atomic arena supports concurrent allocation (#2591/#2593). Thread safety
  extends the section 1.1 no-UB contract through structural checker
  classification, not traits (#2590): a value may cross threads only when
  owned by an arena whose lifetime spans both threads. Section 6.5 specifies
  the structural transfer/share model, while sections 6.2 and 7.3 specify the
  v1 atomic arena runtime/source contract. The raw `stdlib/thread.tl` substrate
  still exposes integer-address escape hatches for unsafe code, while the
  checker-visible safe APIs use the structural transfer/share rules for the
  landed surfaces and keep aggregate transfer extensions split into follow-ups.
- **Tests.** Inline tests and doctests are typechecked on every build of the
  owning package and generate no code outside the test runner (#2587/#2594);
  the checked test surface is exactly the package's own sources.

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

Safe code is source outside an `(unsafe ...)` context and outside calls or
references to declarations marked unsafe. An unsafe context does not disable
ordinary type checking; it only moves responsibility for raw-pointer,
foreign-ABI, and manual resource-reset invariants to the programmer.
Optimizations may rely on the static type, move, borrow, and region facts below,
but must not reinterpret accepted safe code as having behavior outside this
table.

| Safety area | Safe-code outcome | Binding rule and owner |
|-------------|-------------------|------------------------|
| Integer `+`, `-`, `*`, and `neg` overflow | Defined wrap | Wrap modulo 2^N for the result type width; signed results interpret the wrapped bits as two's-complement values. See section 5.4 and #1101. |
| Integer `/` and `%` invalid operands | Deterministic runtime trap | Divisor zero and signed minimum divided/remaindered by `-1` trap through the integer division/remainder abort path. See section 5.4 and #1101. |
| Integer shift counts | Deterministic runtime trap | `shl`/`shr` trap when the count is negative or not less than the left operand's bit width. See section 5.4. |
| Scalar numeric casts | Defined result | Integer/integer, integer/`char`, `f64` ↔ `f32`, and integer/`char` ↔ float casts use defined truncation, sign/zero-extension, and round-to-nearest/truncate-toward-zero rules. See section 3.8 and #1101. |
| Non-numeric casts | Static reject | Casts touching non-numeric types are rejected before lowering. See section 3.8 and #1101. |
| Array, string, slice, and generated collection bounds | Deterministic runtime trap | Out-of-bounds indexing, invalid slice ranges, negative dynamic-array lengths, and allocation byte-count overflow trap through the bounds-check abort path. SPMD inactive tail lanes do not perform bounds checks or memory accesses. See sections 5.15 and 6.1. |
| Initialized-before-use and no use-after-move | Static reject | Safe code cannot read an uninitialized place or a place whose move-only value has been moved. Move-only aggregate semantics are specified in section 4.6.2 and #1046; enforcement is implemented by the selfhost checker (#805, #1048, #1049, #1050). |
| Borrow/reference validity and arena escape | Static reject | Safe references and region-tagged aggregate handles cannot outlive their lifetime/arena, be returned or stored into a longer-lived slot, or be captured by an escaping closure. Current region-tagged escape checks are in sections 3.9, 5.16, and 7.3; immutable borrow rules are implemented (#1033/#1034/#1035); non-lexical last-use shortening is implemented for straight-line sequences and path-sensitive `if`/`match` joins, with loop joins still conservative. |
| Mutation through shared references | Static reject | Safe code cannot write through an immutable/shared reference. Mutable-reference writes require exclusive access; that checker is implemented (#806). Current aggregate-handle mutation is governed by the move-only and aliasing rules in sections 4.6.2 and 7.6. |
| SPMD safe-code data-race freedom | Static reject | Safe `foreach`/SPMD code rejects varying calls, unsupported varying control flow, unsafe shared mutation, and reduction shapes that cannot be proven race-free by the SPMD rules. See section 5.15 and #937/#1012. |
| Task-thread data-race freedom | Static reject | Safe task-threading APIs reject captured, sent, returned, or shared values whose arena owner does not prove storage lifetime across the participating threads, or whose structural transfer/share classification does not prove race-free access. See section 6.5 and #2590/#2592. |
| Invalid enum/struct states | Static reject | Safe code constructs enums and structs only through their checked constructors and pattern forms. Arbitrary bit construction, invalid variants, invalid field layouts, packed-field access, and recursive-by-value aggregate states are rejected. See sections 3.5, 4.6, and 5.13. |
| Raw pointer dereference/write/arithmetic/casts, direct syscalls, foreign ABI assumptions, and manual arena reset | Static reject | Safe code may pass, return, compare, and null-test raw pointer values as specified, but dereference, write, offset, pointer/integer cast, direct host syscall invocation, foreign ABI invariants beyond the declared signature, and invalidating manual arena operations require `(unsafe ...)`. See sections 3.4, 5.19, 7.3, 7.4, and 5.20; design/implementation owners are #954, #809, #812, #1052, #1054, #1055, and #2155. |
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
| `Int` | `[-]?([0-9]+|0[xX][0-9a-fA-F]+|0[bB][01]+)` | Integer literal, default type `i32` |
| `Float` | `[-]?[0-9]+\.[0-9]+` | `f64` literal |
| `Bool` | `true` / `false` | |
| `Char` | `'x'` / `'\n'` / `'\''` | Single character literal |
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
comments before the main lexer discards comments:

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
source file. Multiple explicit inputs and package doctests preserve per-file
reporting. An example passes when it parses, resolves imports, and type-checks.
Adding `expect-error` after the language tag inverts the expectation so the
example must fail during loading, parsing, or type checking. `run` is mutually
exclusive with `expect-error`. A runnable fence must include
`;; doctest-exit: <integer>` in the example body and may include
`;; doctest-stdout: -` / `;; doctest-stderr: -` or `literal:<escaped text>` with
`\n`, `\t`, `\r`, and `\\` escapes. Runnable examples execute on targets that
support the self-hosted build/run path; unsupported targets report an
unsupported runnable-doctest failure. Other fence languages are ignored; unknown
TypeLisp fence options, empty TypeLisp examples, and unterminated TypeLisp
fences are malformed doctests.

The public self-hosted Markdown generator command is `typelisp doc`. Rendering
`typelisp doc input.tl -o output.md` loads the entry file with the normal import
resolver and emits one deterministic Markdown document for the entry plus each
reachable imported module once, including module navigation and source/module
sections. Package documentation uses the package source discovery path selected
by `--manifest-path <typelisp.pkg>` or the nearest manifest when no explicit
input is supplied; package doc generation requires `-o <out.md>`.

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

Integer literals default to `i32` when unconstrained. In an expected integer
position, an integer literal adopts the expected type (`i8`, `i16`, `i32`,
`i64`, `u8`, `u16`, `u32`, or `u64`) when the literal text's magnitude is
representable by that target type. Range checks are deterministic for decimal,
hex (`0x...`), and binary (`0b...`) spellings, including the full `u64` range
through `18446744073709551615` / `0xffffffffffffffff`; negative integer
literals are not representable by unsigned expected types. Out-of-range
contextual literals are compile-time errors; explicit
`(cast expr : target_type)` keeps the normal cast semantics, including
truncation/wrapping behavior for supported numeric casts.
For binary operators, an integer literal operand may adopt the other integer
operand's type; two unconstrained integer literal operands use the `i32`
default. Floating-point literals are always `f64` unless a contextual `f32`
expected type is present.

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
- `make-array` initializes every live element according to the ZII `init`
  rules in section 5.12.1. The language rule is source-level initialization,
  not "whatever bits the allocator happened to return".
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
- Runtime-created strings from `str-cat`/the low-level concat primitives,
  `substring`, `read-file`, `arg`, `int->string`, stdin/file reads, and stdlib
  helpers allocate fresh `String` storage in the active arena.
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
  are rejected; mutable bytes use `ByteBuf` and `bytes`.
- `str` is not NUL-terminated. Its length is carried with the borrowed view.

**Owned mutable byte buffer:** `ByteBuf` (specified, implemented for stdlib core)
- `ByteBuf` is an owned, move-only mutable byte buffer allocated in the active
  arena. It stores a data pointer, live length, and capacity.
- The live range `[0, len)` is initialized byte storage. The spare capacity
  range `[len, capacity)` is reserved implementation storage and cannot be read
  by safe code.
- `ByteBuf` has no text, encoding, or NUL-termination invariant.
- Growing a `ByteBuf` may allocate a new active-arena backing store and copy the
  live bytes. The old backing store is not reclaimed until its arena is reset or
  the process exits.

**Borrowed byte-slice referent:** `bytes` (specified, implemented for stdlib core)
- `bytes` is a borrowed byte-slice referent, not a by-value type in v1.
- `(& lifetime bytes)` is an immutable borrowed byte view.
- `(&mut lifetime bytes)` is an exclusive mutable byte view over a fixed-length
  range. It may update existing bytes but cannot grow the owner.
- Bare `bytes` is rejected in value positions: parameters, returns, locals,
  globals, fields, enum payloads, tuple elements, and array element types.

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
(extern (read-byte [arg0 : (Ptr u8)]) : u8)
(extern (write-byte [arg0 : (MutPtr u8)] [arg1 : u8]) : unit)
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

#### 3.4.1 Arena-owned `(Box T)` indirection

`(Box T)` is an explicit, safe, arena-owned indirection type. A box value is a
pointer-shaped owning handle to storage that contains one `T`, allocated in the
active arena. It is the source-level escape hatch for recursive aggregate
layouts under the default inline aggregate contract.

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
arena and returns `(Box T)`, where `T` is the type of `expr`. In the calling
thread's default arena the result type is `(Box T)`. Inside
`(with-arena r ...)`, allocation targets `r` and the result type is
`(in r (Box T))`; it follows the same region escape rules as other
arena-owned handles.

`(box-get b)` projects the boxed value for read and pattern use. If `b` has
type `(Box T)`, the projection has type `T`. If `b` has type `(in r (Box T))`,
the projection has type `(in r T)` when `T` is region-taggable, otherwise `T`.
The projection does not copy the box handle and does not by itself consume the
box. Subsequent use of the projected value is still governed by the move rules:
copyable `T` values may be copied out, but moving a move-only `T` out of a box
through `box-get` is an aggregate path move and is rejected. Use `(box-take b)`
to destructively move the boxed value out; this consumes the box handle, and
subsequent use of that handle is rejected by the move checker.

`(set! (box-get b) value)` mutates the value stored in a box when `b` is a
storage place such as a local, parameter, or supported aggregate path. The value
must typecheck against the boxed `T`, must satisfy the same region/reference
store checks as other storage-place mutations, and the box handle itself is not
moved. A mutable borrow of `(box-get b)` borrows the boxed storage under the
ordinary lexical exclusivity rules.

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
- Variant constructors and patterns may be written either as compatibility
  unqualified names (`Red`, `(Some x)`) or as enum-qualified names
  (`Color.Red`, `(Option.Some x)`). Duplicate variant base names are allowed
  across different enums when uses are enum-qualified; duplicate variant names
  within the same enum are rejected.
- Pattern matching via `match` (§5.13) is exhaustive and type-checked.
- Enum values are heap-allocated when returned from functions (to avoid variable-sized stack slots).
- Module-qualified imported variants use the same dotted member form, for
  example `json.Json.Null` through an alias or `pkg.json.Json.Null` through a
  visible full module path. `Color::Red` is not TypeLisp syntax.

#### 3.5.2 Structs (product types)

```lisp test=check name=struct-declaration
(defstruct Point
  (x i64)
  (y i64))
```

- Layout: fields stored sequentially with natural alignment per field. No tag word.
- Constructor syntax: `(Point 10 20)` — a call-like expression.
- Field access: `(struct-get p x)` generates a GEP+load at the field's byte
  offset. When the leading dotted segment is a local binding, `p.x` is sugar
  for `(struct-get p x)`, and chains such as `p.inner.x` nest the same access.
- Field mutation: `(set! (struct-get place x) value)` writes one field in
  place and returns `unit`. `(set! place.x value)` is the corresponding local
  dotted sugar.
- Dotted numeric segments such as `p.0` are not index sugar; use `tuple-ref` or
  `array-ref`.
- Structs are heap-allocated when returned from functions (same rule as enums).
- Not valid as global variables.

#### 3.5.3 Default inline aggregate layout and `(:repr c)` compatibility (specified, selfhost metadata implemented)

Ordinary TypeLisp structs use a stable C-compatible inline field layout by
default. Fields are stored in declaration order. Each field starts at the next
offset aligned to that field's natural alignment, and the total struct size is
rounded up to the maximum field alignment. Empty structs have size 0 and
alignment 1.

```lisp test=ignore name=default-struct-layout-syntax reason="layout query lowering is selfhost metadata"
(defstruct Stat
  (size i64)
  (mtime i64))
```

The metadata form `(:repr c)` may still appear immediately after a struct name
and before the first field:

```lisp test=ignore name=repr-c-struct-compat-syntax reason="compatibility metadata"
(defstruct CompatStat
  (:repr c)
  (size i64)
  (mtime i64))
```

For struct layout, `(:repr c)` is a compatibility/ABI-intent marker and does
not change field offsets, size, or alignment. Omitting it no longer selects a
different default layout. Metadata forms must appear before all fields; a
metadata form after a field is rejected. Duplicate `:repr` metadata is
rejected. Unknown metadata keys and unknown representation names are rejected.
Cleanup ownership metadata is specified separately in section 4.6 and is not a
layout contract. `packed`, `(:repr packed)`, and equivalent packed-layout
spellings are reserved and rejected until an unsafe packed-field slice exists.

TypeLisp enum layout is a tagged union by default. The tag is an 8-byte integer
at offset 0. Variant payload storage starts at offset 8; payloads are placed in
variant declaration order using the same natural-alignment rule as struct
fields. The enum size and alignment are the maximum aligned storage needed by
any variant. Payload offsets are available to compiler layout logic through the
inline layout query path.

Layout queries use these default inline layouts for ordinary structs and enums.
Target C ABI call/return lowering for by-value aggregate externs is separate:
the backend must still validate the target ABI classes it supports before
lowering an extern call or return. A source layout being stable does not by
itself mean every aggregate shape is accepted in every external ABI position.
The selfhost Windows x64 C ABI path accepts default-layout enum aggregates by
classifying a synthetic aggregate view consisting of the 8-byte tag followed by
the max-sized payload union. Tag-only enums are scalar register aggregates;
payload enum arguments larger than 8 bytes are passed by hidden reference and
payload enum returns larger than 8 bytes use sret. The Linux x86_64 System V
C ABI path currently accepts tag-only enum externs only.

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

#### 3.7.1 Comptime-generated declarations (v1 design, deprecated)

V1 generated declarations are concrete top-level declarations produced during
compile time. They are TypeLisp's replacement for source-level generics and
traits: a generator inspects compile-time metadata such as `(type T)` and
`(type-key (type T))`, then requests or emits ordinary monomorphic
`defstruct`, `defenum`, and `define` declarations.

`comptime-decl` and `comptime-decls` are deprecated compatibility surface.
New declaration generation should be expressed as declaration-emitting
`defmacro` declarations (section 3.7.2): use `: Module` for generated module
families bound by `import`, and `: Decls` for declarations spliced into the
current module. Existing checked-in uses may remain while the stdlib and
compiler-side generator families migrate; removal is tracked by #3077.

The deprecated source surface is the top-level `comptime-decl` declaration for
a single payload, or `comptime-decls` when a generator request emits a bundle
whose payloads share the same generator and argument keys:

```lisp test=ignore name=comptime-generated-decl-surface reason="generated declarations are specified before #893 implementation"
(comptime-decl
  (:generated stdlib/option-family Option_String (type-key (type String)))
  (defenum Option_String
    (None_String)
    (Some_String String)))

(comptime-decl
  (:generated stdlib/option-family option-string-some? (type-key (type String)))
  (define (option-string-some? [value : Option_String]) : bool
    (match value
      [(Some_String _) true]
      [(None_String) false])))

(comptime-decls
  (:generated stdlib/option-family (type-key (type String)))
  (defenum Option_String
    (None_String)
    (Some_String String))
  (define (option-string-some? [value : Option_String]) : bool
    (match value
      [(Some_String _) true]
      [(None_String) false])))
```

`comptime-decl` and `comptime-decls` are valid only at top level, after
`module`/`import` resolution and before ordinary typechecking/lowering.
`comptime-decl` carries one generated declaration template. `comptime-decls`
carries one or more generated declaration templates and expands them as if each
payload had been written as a separate `comptime-decl` with the same generator
and argument keys. V1 accepts only `defstruct`, `defenum`, and `define`
payloads. `define` covers both value and function declarations. Generated
`extern`, `defmacro`, `module`, `import`, `export`, `cfg`, `test`, and nested
`comptime-decl`/`comptime-decls` payloads are rejected in v1.

The `(:generated generator-name generated-item-name arg-key-expr*)` metadata is
required for reusable single-payload `comptime-decl` declarations. The
`comptime-decls` bundle form uses `(:generated generator-name arg-key-expr*)`;
the generated item name is derived from each payload's visible declaration name.
The parser may continue accepting legacy literal `(comptime-decl (defstruct
...))` / `(comptime-decl (defenum ...))` templates during migration, but
reusable #893 generation must use a metadata form.

Conceptually, each payload creates one generated-declaration request. The
compiler API for comptime generator code uses the same request record: generator
origin span, generated identity metadata, and the `AstDecl` payload to insert.
Generator code must not bypass that record or mutate ordinary declaration lists
directly.

Generated declaration identity is the tuple:

- Generator module identity: the canonical module identity that owns
  `generator-name`.
- Generator identity: the resolved generator declaration name inside that
  module.
- Generated item name: the declared item identity for this payload. For a
  `defstruct` or `defenum`, this is the nominal type name; for a `define`, it is
  the value/function name.
- Argument keys: the ordered compile-time `String` results of
  `arg-key-expr*`. Type arguments should use `type-key`; non-type comptime
  arguments must use stable compiler-owned keys or explicit generator-defined
  string keys.

For `stdlib/hashmap-family`, the argument key list must include the key
`type-key`, value `type-key`, and an explicit key descriptor identity. The v1
built-in descriptors are `stdlib/hashmap/string-key-v1` for owned `String`
keys, `stdlib/hashmap/i64-key-v1` for scalar `i64` keys, and
`stdlib/hashmap/aggregate-key-v1` for nominal struct/enum keys. A descriptor
fixes the hash operation, equality operation, generated family/name prefix, and
whether borrowed-key lookup wrappers are emitted. `String` uses `hash-string`,
`hash-key-string-eq?`, and borrowed lookup/contains/remove wrappers; `i64` uses
`hash-i64`, `hash-key-i64-eq?`, and no borrowed-key wrappers. Aggregate keys
derive deterministic hash/equality from declaration-order struct fields or enum
variant tag plus declaration-order payloads. Supported aggregate members are
`i64`, `bool`, `char`, `String`, and nested supported nominal aggregates.
Unsupported key types or unsupported aggregate members must produce a
compile-time `hashmap-family` diagnostic naming the descriptor or aggregate
member instead of using source-level traits, implicit `Hash`/`Eq` bounds,
runtime type IDs, or address hashing. Changing descriptor identity changes
generated declaration identity even when the key/value types and public item
names are otherwise the same.

The built-in key descriptors support nominal struct and enum value types.
Aggregate values are stored as ordinary map-owned values, may be looked up
through owned results, and may be borrowed through `*-get-value-borrowed` for
field/payload inspection while the map is not mutated.

Generated hashmap families may also expose borrowed-value lookup helpers such
as `*-get-value-borrowed`. These helpers are independent from borrowed-key
lookup: the key path controls whether lookup can inspect a borrowed key without
copying it, while borrowed-value lookup returns a lifetime-parameterized result
whose found branch borrows the map-owned value and is invalidated by map
mutation, removal, resizing, or rehashing.

The payload declaration name must match `generated-item-name`. The compiler may
derive display names from keys, but the generated identity, not the display
spelling alone, is the stable reuse key. Generated identities use canonical
module identities, never import aliases or source-relative paths.

Each `arg-key-expr` is evaluated in generated-declaration evaluation. It must
produce a compile-time `String`; direct runtime observation of that metadata is
rejected. `type-key` strings are opaque inputs to the identity tuple and must not
be parsed by user programs.

Repeated generation with the same identity is idempotent only when the new
payload is structurally the same declaration after normalizing spans,
doc-comments, and non-semantic formatting. The compiler reuses the existing
declaration and does not create a second namespace item. Repeating the same key
with a different declaration kind, signature, field/variant shape, body, export
visibility, or namespace effects is an incompatible duplicate diagnostic.
Different generated identities that bind the same visible value/type/
constructor/variant name are ordinary duplicate namespace errors, with the
generated keys included in the diagnostic.

Generated declarations enter the same namespaces as hand-written declarations:

- `defstruct` binds the nominal type, struct constructor, and exported fields
  according to the ordinary struct/export rules.
- `defenum` binds the nominal type plus variant constructors and patterns
  according to the ordinary enum/export rules.
- `define` binds the ordinary value/function namespace item.

After registry insertion, generated declarations participate in symbol
collection, typechecking, lowering, documentation extraction, tests, and
diagnostics like source declarations. Generated functions and constructors lower
to stable symbols derived from the canonical module identity plus declaration
identity. Documentation tools should show generated declarations when they are
part of the public API and include generated-origin metadata rather than
treating them as compiler internals.

Diagnostics for generated declarations report the most useful source locations:
the generator request/call site, the generated declaration template span when
available, and the generated identity key. Type errors inside generated
declarations should point at the generated declaration and include an expansion
or generation stack back to the request. Duplicate diagnostics should show both
the existing generated identity and the conflicting request.

V1 exclusions:

- No source-level generic type constructors, generic functions, traits,
  `impl` blocks, trait objects, vtables, or runtime type-erased dispatch.
- No runtime representation for `type`, `Expr`, `ExprList`, `ExprClause`,
  `ExprClauseList`, declaration metadata, generated keys, or other
  comptime-only values.
- No generated public Rust compiler product surface; this is a selfhost
  compiler feature.
- No generated declaration kinds beyond `defstruct`, `defenum`, and `define`.
- No cross-run ABI promise for display-name mangling beyond deterministic,
  collision-free names within the TypeLisp module/declaration identity model.

Implementation of this generated-declaration mechanism is tracked by #893.
Downstream Option/Result and collection families must reuse this identity and
duplicate policy rather than inventing family-specific generation paths.

#### 3.7.2 Typed expression macros (v1 design)

V1 macros are compile-time expression transformers. They are declared with
`defmacro`, checked through a function-type-like `macro` type, and expanded
before ordinary runtime typechecking and lowering. A macro is not a runtime
value and cannot be stored in variables, passed to functions, placed in fields,
or called indirectly.

Macro signatures use ordinary produced types, with `Expr` as an explicit
wildcard capture and `ExprClause` as a bracket-clause capture. An ordinary
operand slot states the type that the operand expression must produce at the
call site. For example, a macro with type `(macro (bool bool) bool)` takes two
operand expressions that must each typecheck as `bool` and produces an
expression that must typecheck as `bool`. A fixed slot declared `Expr` accepts
any ordinary operand expression without checking its produced type before
expansion; the macro receives the syntax as an `Expr`, and ordinary
typechecking validates the expanded expression afterward.

A fixed slot declared `ExprClause` accepts exactly one bracket-list operand
`[first second]`, where `first` and `second` are ordinary expressions preserved
as syntax. The bracket form is valid only in macro call operands; it is not a
general expression, and ordinary calls or non-`ExprClause` macro slots reject it
with a source-located diagnostic. Empty clauses, one-element clauses, and
clauses with more than two elements are rejected.

A final slot may be variadic, written `T ...`. For ordinary `T`, the macro body
receives the remaining operands as an `ExprList`; for `Expr ...`, they are
captured without per-operand produced-type checks. For `ExprClause ...`, every
remaining operand must be a two-expression bracket clause and the macro body
receives an `ExprClauseList`.

Macro bodies can inspect variadic expression captures with `expr-list-empty?`,
`expr-list-length`, `expr-list-head`, `expr-list-tail`, and `expr-list-nth`.
They can inspect clause captures with `expr-clause-first`,
`expr-clause-second`, `expr-clause-list-empty?`,
`expr-clause-list-length`, `expr-clause-list-head`,
`expr-clause-list-tail`, and `expr-clause-list-nth`.
`expr-clause-list->expr-list` converts a clause list back into a list of
bracket-clause operand syntax for explicit splicing into recursive macro calls.

`Expr`, `ExprList`, `ExprClause`, and `ExprClauseList` are compile-time-only
types. They are valid in macro bodies and explicit `(comptime ...)` helper
code, but they have no runtime representation. The compiler tracks the checked
produced type of each `Expr` internally; there is no source-level `Expr<T>` and
no generic macro type parameter.

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
list. Clause lists do not splice implicitly; use `expr-clause-list->expr-list`
when a macro needs to splice generated bracket operands. `unquote` and
`unquote-splicing` outside quasiquote are rejected.

The source surface is:

```lisp test=ignore name=macro-defmacro-surface reason="typed macro declarations are specified before selfhost implementation"
(defmacro (and2 [lhs : bool] [rhs : bool]) : bool
  (expr-if lhs rhs (expr-bool false)))

(defmacro (all [first : bool] [rest : bool ...]) : bool
  ;; `first` is an Expr; `rest` is an ExprList.
  (fold-bool-and first rest))

(defmacro (pick-first [arms : ExprClause ...]) : i64
  (if (expr-clause-list-empty? arms)
    (expr-int 0)
    `(if ,(expr-clause-first (expr-clause-list-head arms))
       ,(expr-clause-second (expr-clause-list-head arms))
       (pick-first ,@(expr-clause-list->expr-list
                       (expr-clause-list-tail arms))))))
```

The canonical binding types for those declarations are `(macro (bool bool)
bool)`, `(macro (bool bool ...) bool)`, and
`(macro (ExprClause ...) i64)`. The `defmacro` operand list names the macro
body's compile-time parameters and their call-site produced types. Fixed
ordinary operands bind as `Expr`, fixed `ExprClause` operands bind as
`ExprClause`, variadic ordinary operands bind as `ExprList`, and variadic
`ExprClause` operands bind as `ExprClauseList`. The macro body must typecheck
as `Expr`, and the produced fragment must post-expand typecheck as the declared
result type.

Typed expansion has three checks:

1. The macro call site is checked from the macro signature before expansion.
   Ordinary operand type errors are reported at the operand source span; `Expr`
   operands are wildcard syntax captures and skip the produced-type check;
   `ExprClause` operands must use `[expr expr]` syntax.
2. The macro body is checked as compile-time TypeLisp over the macro-only
   syntax types.
3. The expanded expression is checked again by the ordinary typechecker as a
   safety net; failures are compiler or macro diagnostics with expansion spans.

Declaration-emitting macros extend `defmacro` with two module-scope result
categories:

- `: Module` means the macro body produces exactly one `(module ...)`
  declaration. It is called only through import syntax:
  `(import (macro args))` or `(import (macro args) as alias)`. Without `as`,
  the generated module is anonymous and all exported items are imported
  unqualified into the current module. With `as`, only qualified access through
  the alias is bound. The macro operand is always the nested call form; a flat
  import such as `(import vector i64)` is not a module macro import. The
  generated module participates in ordinary
  dot-qualified lookup, export checking, typechecking, lowering, tests, docs,
  and diagnostics after expansion.
- `: Decls` means the macro body produces a declaration list. A call at module
  scope, for example `(point-vec i64)`, is replaced by those declarations at
  that exact location. One returned declaration is inserted directly; multiple
  returned declarations are treated as if wrapped in an implicit `(begin ...)`.
  No import binding is created. This form is for one-off helper declarations;
  module-shaped reusable families should prefer `: Module`.

Expression macros remain the existing expression-position form above: the
declared result is the produced expression type that the expansion must satisfy
after splicing, while the macro body itself constructs `Expr` syntax. `: Expr`
is the wildcard expression result for macros that intentionally defer all
produced-type checking to the expanded form. `: Module` and `: Decls` are not
runtime types, cannot appear in value positions, and are valid only as macro
result annotations.

Module-scope expansion runs before ordinary typechecking:

1. Parse the module, collect source imports, and resolve/load imported modules.
2. Build the macro namespace from local and imported `defmacro` declarations.
3. Expand module-scope macro imports and `: Decls` calls. If expansion emits new
   imports, resolve those imports and repeat this step to a fixed point.
4. Recurse into generated modules, then typecheck the fully expanded module.

The macro must be visible in the ordinary macro namespace: a local macro in the
same module regardless of source order, an imported macro, or a qualified macro
name such as `(stdlib.vector.vector i64)`. A macro with `: Module` used outside
`import`, a macro with `: Decls` used in expression position or import syntax,
and an expression macro used at module scope are diagnostics.

Two unqualified generated module imports that export the same name create the
same kind of namespace collision as hand-written imports. The diagnostic should
name both generated module identities and suggest qualified access using either
an explicit alias or the full generated module identity.

Generated module identity and deduplication are keyed by the canonical macro
module identity, macro name, and evaluated argument-key strings. Repeating the
same macro call with the same keys reuses the generated module when the emitted
module is structurally identical; incompatible output for the same identity is a
compiler diagnostic.

#### 3.7.2.1 Comptime purity for macros and generated declarations

`defmacro` bodies, declaration-emitting macro output, and deprecated
`comptime-decl`/`comptime-decls` generated declaration templates are safe
compile-time TypeLisp. The checked comptime path is a deterministic transformer
over compiler-owned syntax and metadata, not a way to perform host I/O or call
target FFI during compilation.

The purity rule is direct and transitive through helpers reachable from the
macro body or generated template:

- `(unsafe ...)` blocks, unsafe declarations, raw-pointer operations, low-level
  FFI bridge forms, direct syscalls, process entry state, and host CPU queries
  are rejected.
- `extern` declarations and references are rejected, including helper calls that
  reach an extern.
- The host-facing stdlib module families `io`, `fs`, `process`, and `env` are
  off-limits in comptime paths. This covers both explicit qualified module
  references and imported helper bodies that reach their extern/unsafe
  implementation. `random` helpers are not banned as a module family, but any
  system-seeded or host-facing implementation path is rejected by the same
  extern/unsafe rule.
- Allocation through the active compiler arena is allowed. Pure CTFE-supported
  helpers such as string equality/concatenation, string length, `int->string`,
  layout/reflection queries, and the `Expr`/`ExprList`/`ExprClause` constructor
  and inspector surface remain available.

Scalar CTFE supports finite `f64` literals and finite `f32` values produced by
context or explicit precision casts. The ordinary float `+`, `-`, `*`, `/`,
unary negation, and comparison operators are supported when both operands have
the same CTFE float kind; `f32` arithmetic rounds results through binary32.
Float literal text is parsed deterministically from the source grammar, folded
results are serialized through the compiler-owned shortest round-tripping
formatter, and optimizer folding uses the same parse/format helpers. CTFE
rejects division by zero and non-finite float literals/results until TypeLisp
specifies portable infinity and NaN payload behavior. Lowered IR/backend float
constants carry explicit IEEE-754 bit payloads instead of decimal text: `f64`
uses the full 64-bit binary64 payload, while `f32` stores the low 32 binary32
bits in the same payload field. Assembly/object emission writes those bits
directly (`.quad` for `f64`, `.long`/4-byte object records for `f32`) rather
than reparsing decimal strings.

The rule applies to the comptime path, not to every runtime call of the same
function. A helper that is safe along the macro/comptime call graph may remain
runtime-callable elsewhere; a helper reached from a macro or generated template
is rejected if that reachable body depends on unsafe, extern, or banned host
facilities. Diagnostics should point at the offending reference and include the
reachable reference path, for example `macro -> helper -> extern-name`.

Expansion runs after parsing/import loading and before runtime typechecking.
The expander resolves a list head in the macro namespace first; if no macro is
found, the form is left for ordinary value-call checking. A module may not
declare a local value/function and a local macro with the same unqualified name
in v1. Hygiene and binding-introducing macros are not part of v1; parser-owned
guard/conditional forms such as `when`, `unless`, and `cond` introduce no
user-visible bindings.

Local `defmacro` declarations are visible throughout their module regardless of
source order, matching functions, values, and types. A macro may therefore be
called before its declaration, and one macro may expand to a call of another
macro declared later in the same module. Compatibility declarations produced by
deprecated `comptime-decl` / `comptime-decls` are materialized before macro
expansion. Declarations produced by `: Decls` or `: Module` macros participate
in the module-wide macro table for subsequent fixed-point expansion and
ordinary typechecking, but a macro emitted by a declaration-emitting macro is
not visible while evaluating the macro that emits it.

#### 3.7.2.2 Stdlib-owned comptime syntax and reflection types

The public macro/comptime syntax and reflection surface is owned by the stdlib,
not by ad hoc compiler-only handles. The declarations live in the stdlib
comptime module and are ordinary `defenum`/`defstruct` declarations, but the
compiler treats them as **well-known types**: their module identity, type names,
variant names, field names, field order, arity, payload types, and
compile-time-only marker are pinned by this SPEC and verified when the stdlib is
loaded.

The well-known set for the first stdlib-owned surface is:

- Syntax values: `Expr`, `ExprList`, `ExprClause`, and `ExprClauseList`.
- Reflection values: `TypeInfo` plus the associated field, variant, payload,
  parameter, and sequence types needed to represent the section 5.17 reflection
  data as ordinary TypeLisp values.

`Expr` is the public source-expression AST used by macros. It mirrors source
expression forms, not checked compiler internals: literals, variable/reference
names, calls, blocks, control-flow expressions, aggregate constructors, pattern
forms where needed by macro operands, quote/quasiquote forms, and other section
5 source expressions may appear as variants. It must not expose typed AST nodes,
IR values, CFG blocks, liveness data, register allocation state, backend object
records, or any representation that optimizer/backend work needs freedom to
change.

`TypeInfo` is the public, stable reflection value form of section 5.17. It may
represent builtin types, arrays, functions, tuples, structs, enums, and the
reserved/partial shapes that `type-kind` can classify. It exposes language
metadata such as nominal identity, fields, variants, payloads, parameters, and
opaque `type-key` identity. It must not expose runtime type objects, method
tables, optimizer facts, layout internals beyond the explicit layout-query
surface, or compiler symbol-table handles.

The stdlib declarations choose the end-state collection shape rather than
freezing the compiler's historical cons-list helpers. `ExprList`,
`ExprClauseList`, and reflection sequences are dense, length-indexed sequence
wrappers over arrays (or an equivalent compiler-verified dense representation).
Their public API is length/index/iteration-oriented. Recursive cons cells are
not part of the public contract, even if temporary compatibility helpers keep
names such as `expr-list-head` during migration.

The public enum variant policy follows the dotted qualified variant direction:
stdlib declarations should use short variant names such as `Var`, `Call`,
`Struct`, or `Enum`, and source code should refer to them through enum-qualified
names such as `Expr.Var` and `TypeInfo.Struct`. Implementation code may keep
prefixed variant names or compatibility constructors during migration, but those
prefixed spellings are not the final public API.

Spans, lexical context, expansion scopes, and provenance are compiler metadata
attached to syntax values, not ordinary public fields on every `Expr` variant.
Conceptually this is a side table keyed by compiler-owned node identity. The
compiler must preserve that metadata through stdlib-typed manipulation:

- `quote` and `quasiquote` allocate fresh syntax values whose provenance points
  at the template source span and macro definition context.
- `unquote` and `unquote-splicing` insert existing syntax values with their
  existing provenance and lexical context.
- Public constructors allocate fresh syntax values and attach the constructor
  call span as fallback provenance unless a dedicated provenance-preserving
  helper is used.
- Transformations that rebuild syntax from an existing node should preserve the
  original node's user-facing provenance when that is the least surprising
  diagnostic source.

Debug or diagnostics helpers may expose rendered spans or printable expression
forms, but source code cannot forge lexical contexts, expansion scopes, or raw
node identities. Any operation that feeds an `Expr` back into the expander must
carry valid compiler provenance. This rule composes with the hygiene rules in
section 3.7.3: quote/quasiquote template identifiers carry the macro definition
context, and unquoted caller syntax keeps its use-site context.

The verification rule is fail-closed. A `--stdlib-root` tree or embedded stdlib
whose well-known declarations do not match the pinned contract is rejected before
macro expansion or generated declaration evaluation. The diagnostic should name
the module/type and the first mismatch, for example:

```text
typecheck: stdlib well-known type mismatch for stdlib.comptime.Expr: expected variant Call at index 4
```

Targeted diagnostics should cover at least these corpus cases once the
implementation lands:

- Missing or renamed `Expr` / `TypeInfo` variants.
- Variant payload arity or type mismatch.
- `ExprList` or reflection sequence declarations that expose a cons-list shape
  instead of the dense sequence contract.
- Runtime-usable declarations for comptime-only types.
- A stale stdlib root whose well-known type version does not match the compiler.

The compiler may use the verified stdlib declarations as its real macro-time
representation. CTFE interpretation and compiled comptime execution must observe
the same source-level types and produce byte-identical expanded declarations for
the same inputs. A mismatch is a compiler bug or stdlib-version diagnostic, not
a silent fallback to a separate internal `Expr` ABI.

#### 3.7.3 Hygienic expression macros (v2 design)

V2 macros use full hygienic expansion, not gensym-only renaming. Gensym is
enough to keep a macro's temporary binder from capturing a caller identifier,
but it does not make free identifiers in a macro template resolve in the macro's
definition environment. TypeLisp needs both properties before macros may safely
introduce bindings.

The compiler represents macro-time syntax internally as scoped syntax objects:
an AST node plus source span and lexical context. The source-level type remains
the single `Expr` / `ExprList` surface from v1; scope sets, definition contexts,
and expansion marks are compiler metadata, not source-level type parameters.

Rules:

- Each identifier has a printed name and a scope set. Name resolution uses the
  scoped identifier, not only the printed name.
- A macro declaration stores the lexical definition context in its macro
  metadata. For exported macros, the serialized/imported macro metadata must
  carry enough definition-context information for template free identifiers to
  keep resolving as they did at the macro definition site.
- Identifiers that come from a quoted or quasiquoted macro template carry the
  macro definition context.
- Each macro expansion adds a fresh expansion scope to identifiers introduced by
  the template. Binding forms introduced by the template apply that fresh scope
  to their own introduced references, so generated locals can refer to each
  other without colliding with same-name caller locals.
- Syntax supplied by the caller through `unquote` or `unquote-splicing`
  preserves its use-site context. A caller expression inserted under a
  macro-introduced binder therefore still resolves to the caller binding it
  originally named, unless the caller explicitly supplied syntax that refers to
  the macro-introduced identifier through a future intentional escape API.
- Nested and recursive macro expansion compose by retaining all existing scopes
  and adding a new expansion scope for each expansion step.

`quote` and `quasiquote` both produce scoped template syntax. `unquote`
evaluates to an `Expr` and inserts that expression with its existing scope set.
`unquote-splicing` evaluates to an `ExprList` and inserts every element with its
existing scope set. `unquote` and `unquote-splicing` outside quasiquote remain
syntax errors. Converting an `Expr` to printable/debug text may drop scope
details, but any operation that feeds syntax back into the expander must keep or
explicitly reconstruct lexical context.

Worked example: a macro-introduced temporary binding must not capture a
same-name user variable inside an unquoted body.

```lisp test=ignore name=macro-hygiene-temp-binder reason="hygienic macro expansion is tracked by #1144"
(defmacro (with-temp-plus [value : i64] [body : i64]) : i64
  `(let ([tmp : i64 ,value])
     (+ tmp ,body)))

(define (main) : i64
  (let ([tmp : i64 40])
    (with-temp-plus 1 (+ tmp 1))))
```

The result is `42`: the `tmp` in the macro template's `(+ tmp ...)` resolves to
the macro-introduced binder, while the `tmp` inside the unquoted caller body
keeps the caller scope and resolves to the outer `let`.

Worked example: a free identifier in a macro template resolves in the macro
definition environment even when the use site shadows the same printed name.

```lisp test=ignore name=macro-hygiene-definition-context reason="hygienic macro expansion is tracked by #1144"
(define (macro-helper [x : bool]) : bool
  (not x))

(defmacro (unless2 [condition : bool] [body : unit]) : unit
  `(if (macro-helper ,condition)
     ,body
     unit))

(define (main) : unit
  (let ([macro-helper : bool true])
    (unless2 false (print-string "ok"))))
```

The `macro-helper` referenced by the template is the top-level function visible
where `unless2` was defined. The caller's local boolean named `macro-helper`
does not capture that reference.

Diagnostics should report source spans from the most useful user-facing syntax:
call-site spans for invalid operands and unquoted caller syntax, template spans
for invalid macro-produced forms, and an expansion stack when an error crosses a
macro boundary. Diagnostics should not expose generated internal names except in
deliberate debug output. Hygiene implementation work is tracked by #1144.

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
- Integer/`char` → float: produces the nearest representable float. Integer
  sources are interpreted using their source signedness; `char` zero-extends.
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
for allocations inside the body, shadows the calling thread's default arena, and
lowers to `tl_region_mark` / `tl_region_reset` around the body.

**Region-taggable types** are the heap-allocated aggregate kinds whose storage
can be created inside a region scope:
- `String`
- `ByteBuf` - owned mutable byte buffers
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

### 3.10 Reference types and borrow expressions (v1 design)

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
- Mutable references are exclusive, non-copying handles to the same referent.
  The checker enforces many immutable borrows or one mutable borrow for
  tracked local/place paths. Tracked aggregate-place paths conflict only when
  they are the same path or one is an ancestor of the other, so mutable borrows
  of disjoint sibling fields may coexist while overlapping whole-field,
  same-field, and field-element borrows are rejected. Non-lexical last-use
  shortening is implemented for local expression sequences and path-sensitive
  `if`/`match` joins; loop-carried shortening, reference-capturing closure
  relaxation, and general dereference/update operations remain follow-up
  borrow-checker work.
- Lowering supports reference values for scalar referents, borrowed `str`, and
  array referents used by `array-ref`, `array-set!`, and `array-push!`.
  Borrowed `str` source semantics are specified in section 3.11.

Borrow expressions are specified as:

```lisp test=ignore name=borrow-expression-syntax reason=syntax-only
(& place)
(& arena place)
(&mut place)
(&mut arena place)
```

- `(& place)` creates an immutable reference and lets the checker infer the
  lifetime/arena name.
- `(& arena place)` creates the same reference but requires the inferred
  lifetime/arena name to be `arena`; otherwise the checker reports a type error.
- `(&mut place)` and `(&mut arena place)` create mutable references with the
  same lifetime inference and explicit-lifetime check.
- Mutable borrows of scalar/register-resident by-value locals are supported only
  as immediate call arguments. The compiler materializes a temporary and writes
  it back after the call. Binding or storing such a mutable reference is rejected
  until lexical-scope writeback support exists.
- Borrow expressions are the explicit spelling. At call sites, a parameter of
  type `(& lifetime T)` may also auto-borrow an argument place under the same
  immutable borrow rules below. There is no general implicit conversion from
  `T` to `(& lifetime T)` outside typed calls, and mutable references still
  require explicit `(&mut ...)`.
- The referent type is the place's value type, except that borrowing a `String`
  place produces `(& lifetime str)`. When the place type is an arena-tagged
  wrapper `(in arena T)`, the reference type is `(& arena T)`, not
  `(& arena (in arena T))`; for `(in arena String)`, the reference type is
  `(& arena str)`.

**Borrowable places in lexical v1.** The checker accepts immutable borrows of
places whose owner/provenance is statically known:

- Local bindings and function parameters.
- Aggregate field and element projections rooted in a borrowable place. In a
  borrow expression, forms such as `(struct-get p field)`, local dotted field
  sugar `p.field`, `(tuple-ref t 0)`, and `(array-ref items i)` are treated as
  projections, not by-value reads.
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

**Immutable call-site auto-borrowing.** When a typed TypeLisp call, function
value/lambda call, or constructor call has a formal parameter of type
`(& lifetime T)`, the checker may treat the corresponding source argument as
`(& argument)` if the argument is a borrowable place and the inferred referent
type is compatible with `T`. The inferred lifetime participates in ordinary
call lifetime substitution: repeated formal lifetime names must infer the same
caller lifetime, and fixed lifetime names must match exactly. The synthesized
  borrow lives until the last use of any reference value that carries the
  borrow lifetime across straight-line sequences and path-sensitive `if`/`match`
  joins, or to the end of the innermost conservative control-flow scope when a
  later loop or unsupported join cannot yet be shortened. Explicit borrow
  expressions use the same lifetime rule. Macros are checked after expansion.
Extern C ABI calls remain out of scope while safe reference types are not legal
C ABI parameter values. Arbitrary rvalues and temporaries are still rejected
because they have no stable lexical owner:

```lisp test=ignore name=auto-borrow-reject-temporary reason="negative example for immutable call-site auto-borrowing"
(define (takes-ref [n : (& value i64)]) : i64
  (read-ref n))

(define (bad-auto-borrow-temporary [n : i64]) : i64
  (takes-ref (+ n 1)))
```

The first #804 stored-reference slice accepts reference lifetimes written
directly in structural container types: fixed arrays such as
`(Array (& n i64) 1)`, tuple elements, and nested structural types. Those
lifetimes are preserved through array-ref and tuple-ref. Structural return
types that expose the reference lifetime directly, such as `(& n T)`,
`(Tuple (& n T))`, and `(Array (& n T) k)`, may return when the lifetime is
tied to an input.

#### 3.10.1 Lifetime-parameterized named aggregates (v1 design)

Named structs and enums may declare lifetime parameters with lifetime metadata
after the nominal name and before all fields or variants, alongside any other
declaration metadata:

```lisp test=ignore name=lifetime-parameterized-aggregate-declaration reason="specified before selfhost parser/typechecker support"
(defstruct RefPair
  (:lifetimes a b)
  (left (& a i64))
  (right (& b str)))

(defenum MaybeRef
  (:lifetimes a)
  (NoRef)
  (SomeRef (& a i64)))
```

`(:lifetimes a b)` binds declaration-local lifetime parameters. They are not
fields, runtime values, type values, or source-level generic type parameters.
They may appear only as reference lifetime names or as lifetime arguments to
other nominal aggregate types inside the aggregate declaration. The reserved
lifetime name `program` may also appear in fields or payloads and is not listed
in `(:lifetimes ...)`.

Lifetime metadata has these declaration-site rules:

- The metadata form is plural and requires at least one lifetime name:
  `(:lifetimes a)`, `(:lifetimes a b)`, and so on.
- Lifetime names are ordinary identifiers. Duplicate names in one declaration
  are rejected.
- At most one `(:lifetimes ...)` metadata form may appear on a declaration.
- A field or enum payload reference lifetime must be one of the declaration's
  lifetime parameters or the reserved `program` lifetime. Other names are
  rejected as unknown lifetime parameters.
- `(:lifetimes ...)` is compatible with ordinary default-layout structs and
  enums. It is rejected with `(:repr c)` in v1 because safe references are not
  C ABI fields.
- Lifetime metadata is independent from cleanup ownership metadata. A future
  cleanup-owning struct may also have lifetime parameters, but cleanup-owning
  enum metadata remains reserved as described in section 4.6.1.

Type-use sites supply lifetime arguments with a lifetime-only nominal type form:

```lisp test=ignore name=lifetime-parameterized-aggregate-type-use reason="specified before selfhost parser/typechecker support"
(define (first-ref [pair : (RefPair a b)]) : (& a i64)
  (struct-get pair left))

(define (select-ref [value : (MaybeRef a)]) : i64
  (match value
    [(SomeRef r) 1]
    [NoRef 0]))
```

`(Name a b)` is a nominal type use for the already-declared struct or enum
`Name` with lifetime arguments `a` and `b`. The arguments are lifetime names,
not type expressions. `(Array T)`, `(Tuple ...)`, `(Box T)`, `(Ptr T)`,
`(& a T)`, and the other built-in type constructors remain the only built-in
type constructors. TypeLisp still rejects source-level generic type
constructors, generic functions, traits, and type parameters; `(Name T)` is not
a type-parameter application unless `T` is a lifetime name in scope.

Lifetime argument type-use rules:

- A nominal type declared without `(:lifetimes ...)` is used as bare `Name`.
  Supplying arguments to a zero-lifetime nominal type is rejected.
- A nominal type declared with lifetimes must be used as `(Name args...)` with
  exactly the declared arity. Bare `Name`, too few arguments, and too many
  arguments are rejected.
- Each lifetime argument must be a lifetime name in the current lifetime scope:
  a function signature lifetime, a declaration lifetime parameter, a current
  lexical owner name, a current `with-arena` name for local annotations, or the
  reserved `program` lifetime. Unknown names are rejected.
- There is no lifetime subtyping or implicit lifetime coercion in v1. Two
  nominal lifetime types are equal only when they have the same nominal identity
  and the same lifetime argument list after substitution.
- Nested uses are allowed wherever ordinary types are allowed, including
  function parameters and returns, `let` annotations, struct fields, enum
  payloads, tuple elements, fixed arrays, dynamic arrays, boxes, pointers, and
  references.

Declaration lifetime parameters are substituted by position. If
`RefPair` declares `(:lifetimes a b)`, then the field type `(& a i64)` becomes
`(& x i64)` in `(RefPair x y)`, and `(& b str)` becomes `(& y str)`.
Substitution applies recursively through nested nominal types, arrays, tuples,
boxes, pointers, and references.

Struct constructor checking uses the substituted field types. A constructor
call for a lifetime-parameterized struct produces the corresponding nominal
lifetime type when every argument's stored lifetime matches the substituted
field type:

```lisp test=ignore name=lifetime-parameterized-struct-constructor reason="specified before selfhost parser/typechecker support"
(defstruct RefBox
  (:lifetimes a)
  (value (& a i64)))

(define (box-ref [value : (& a i64)]) : (RefBox a)
  (RefBox value))
```

`struct-get` preserves the same substitution. If `box` has type `(RefBox a)`,
then `(struct-get box value)` has type `(& a i64)`.

Enum variant constructors and `match` arms use the same substitution. A variant
constructor for a lifetime-parameterized enum produces the enum type with the
lifetime arguments determined from the payloads or from the expected type. A
`match` over `(MaybeRef a)` binds the `SomeRef` payload as `(& a i64)`.

```lisp test=ignore name=lifetime-parameterized-enum-constructor-match reason="specified before selfhost parser/typechecker support"
(defenum MaybeRef
  (:lifetimes a)
  (NoRef)
  (SomeRef (& a i64)))

(define (wrap-ref [value : (& a i64)]) : (MaybeRef a)
  (SomeRef value))

(define (unwrap-score [value : (MaybeRef a)]) : i64
  (match value
    [(SomeRef r) 1]
    [NoRef 0]))
```

Function signatures bind lifetime names from reference types and nominal
lifetime type arguments in parameter positions. A return type may mention a
lifetime only when that lifetime is tied to at least one input parameter or is
the reserved `program` lifetime. Returning a named aggregate containing
references is valid only when every stored reference lifetime in the returned
type is tied to such an input lifetime or to `program`.

```lisp test=ignore name=lifetime-parameterized-return-ok reason="specified before selfhost parser/typechecker support"
(define (keep-ref [value : (& a i64)]) : (RefBox a)
  (RefBox value))
```

The checker rejects returned, stored, or assigned nominal aggregate values when
any stored reference lifetime is local, scoped, unknown, untied to an input, or
otherwise shorter than the destination lifetime:

```lisp test=ignore name=lifetime-parameterized-return-reject-local reason="negative example for future nominal lifetime checker"
(define (bad-local-box) : (RefBox local)
  (let [local-value : i64 1]
    (RefBox (& local-value))))
```

Diagnostics must be source-located and name the relevant aggregate/type where
possible:

- Missing lifetime arguments for a lifetime-parameterized nominal type.
- Wrong lifetime argument arity.
- Duplicate lifetime parameter names in `(:lifetimes ...)`.
- Unknown lifetime names in declarations, type uses, fields, payloads, and
  returns.
- Incompatible stored lifetimes when constructing, assigning, storing, passing,
  matching, or returning a nominal aggregate.
- Attempts to use type parameters, type expressions, or generic type
  constructors where only lifetime names are allowed.

V1 exclusions: loop-carried non-lexical lifetimes, runtime generics/type
parameters, trait-like bounds, lifetime elision syntax, lifetime
subtyping/coercion, and Rust compiler product-surface changes are out of scope.
The selfhost parser, AST, typechecker, and lowerer support for this specified
syntax is implemented (#1722/#804), as are mutable-reference creation and
exclusivity (#806), straight-line and path-sensitive branch last-use shortening
for borrows (#810 first slices), and non-escaping reference-capturing closures
(#808/#2280).

**Non-lexical v1 lifetime rule.** A borrow created in v1 lives until the last
use of a reference value that carries the borrow lifetime. This shortening
applies across expression sequences such as `begin`, `unsafe`, and
`let`/resource bodies after their bindings have been established, and across
path-sensitive `if`/`match` joins. Branch-local borrows that do not escape the
taken branch end at their last in-branch reference use; borrows that escape
through the branch result, an outer assignment, or a lifetime-parameterized
aggregate result remain live after the join until the escaping value's last
use. A plain auto-borrowed call argument whose callee does not return or store a
reference tied to the argument lifetime ends after the call expression. If the
reference result is bound, stored in a lifetime-parameterized aggregate,
returned, or otherwise remains available as a reference value, the owner remains
borrowed until that value's last proven use.

Lexical scopes are still the conservative boundary for flows this slice does
not prove: function/lambda bodies, `let` bodies, `with-arena` bodies, resource
`with` bodies, loops, `foreach`, and SPMD control flow. When a borrow crosses
one of those boundaries and a later reference use remains possible, it is kept
live for the conservative scope instead of being shortened through the join.

While an immutable borrow is live, later move-only by-value moves, `set!`
assignment to the borrowed place, and mutable borrows/mutations of the same
place are rejected by the relevant move/borrow slices (#806/#1050). Multiple
immutable borrows of the same place are allowed.

While a mutable borrow is live, later immutable or mutable borrows and writes of
the same tracked path, any ancestor path, or any descendant path are rejected.
Ordinary direct reads/accesses of those paths are rejected too; reads through the
mutable reference value itself remain accepted. Sibling aggregate projections
remain independent when the checker can name both paths, for example
simultaneous mutable borrows of two different struct fields rooted in the same
local. Lexical mutable reborrowing is supported: a nested scope may borrow a
descendant through an existing mutable reference, and the outer mutable
reference becomes usable again after that nested scope ends. Using or mutating
through the outer reference while the inner reborrow is still live remains
rejected. Straight-line `begin` sequences and path-sensitive `if`/`match` joins
can shorten immutable and storage-backed mutable borrow conflicts after the last
use, but loop joins remain conservative.

**Invalid escapes in v1.** The checker rejects references that would outlive
their owner or arena:

- Returning a reference to a local, parameter stack slot, temporary, or scoped
  arena unless a later #804 lifetime-parameter rule explicitly proves the return
  is tied to an input or arena that outlives the call.
- Assigning or storing a shorter-lived reference into a longer-lived local,
  global, aggregate field, enum payload, tuple element, or array element.
- Capturing a reference in a closure value whose use is not proven
  non-escaping by section 3.10.2.
- Letting a reference to `(in inner T)` data escape the `with-arena inner`
  body. Outer-arena references may be used inside inner arenas without gaining
  the inner lifetime.

Mutable reference creation and exclusivity are implemented (#806). Nominal
returned/stored lifetime parameter syntax is specified in section 3.10.1 and
implemented by #1722/#804. Non-escaping reference-capturing closures are
implemented (#808/#2280); mutation of captured names remains rejected (#2552).
Straight-line non-lexical lifetime shortening and path-sensitive branch joins
are implemented as the first #810 slices; loop-carried liveness and broader
control-flow shortening remain later #810 slices.

```lisp test=ignore name=borrow-local-param-ok reason="illustrative borrow-expression example; not a standalone program"
(define (takes-i64 [x : (& n i64)]) : i64
  0)

(define (borrow-param [n : i64]) : i64
  (let [r (& n)]
    (takes-i64 r)))
```

```lisp test=ignore name=borrow-field-element-ok reason="illustrative borrow-expression example; not a standalone program"
(defstruct Pair (left i64) (right i64))

(define (takes-two [x : (& p i64)] [y : (& items i64)]) : i64
  0)

(define (borrow-places [p : Pair] [items : (Array i64)]) : i64
  (let [left (& (struct-get p left))]
    (let [first (& (array-ref items 0))]
      (takes-two left first))))
```

```lisp test=ignore name=borrow-arena-owned-ok reason="illustrative borrow-expression example; not a standalone program"
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

#### 3.10.2 Closure reference captures (v1 design)

This section specifies the first safe rule for closures that capture immutable
references. The non-escaping classification is implemented (#808/#2280): a
lambda may capture a binding whose type contains an immutable reference when
the checker proves the closure value does not escape the reference's lifetime.
Closures that would escape still reject reference captures.

A closure is **reference-capturing** when any captured binding has a type that
contains `(& lifetime T)`. Capturing `(&mut lifetime T)` is rejected in v1; the
creation, exclusivity, and mutation rules for mutable references remain owned by
#806. Capturing region-tagged owner values such as `(in r String)` remains
governed by section 3.9.

The source function type `(-> args ... ret)` does not encode captured
lifetimes. V1 therefore uses checker-only escape classification rather than a
source-visible type-level capture marker. The checker may attach internal
capture-lifetime facts to lambda expressions and local closure bindings while
checking a lexical scope. If a flow would erase those facts, the flow is treated
as escaping and is rejected. The runtime closure descriptor ABI is unchanged.

An immutable reference capture is allowed only when every use of the produced
closure value is proven non-escaping relative to every captured reference
lifetime:

- Immediate invocation of the lambda literal before the captured reference's
  lexical scope ends.
- Binding the closure to a local whose lexical scope is contained within every
  captured reference lifetime, then calling that local only within the same
  proof scope.
- Nesting reference-capturing closures, provided every enclosing closure in the
  chain is also proven non-escaping.

A closure value flow is escaping unless the checker can prove one of the
non-escaping cases above. The v1 checker must reject these flows for a
reference-capturing closure:

- Returning it from a function or lambda, because `(-> args ... ret)` carries no
  captured-lifetime marker.
- Producing it as the result of `with-arena`, resource `with`, `let`, `match`,
  or another lexical scope when that exits the lifetime of any captured
  reference.
- Assigning it into a binding whose scope is not contained within every
  captured reference lifetime, including assignment into an outer local.
- Storing it in a global/top-level slot.
- Storing it in an aggregate, tuple, fixed array, dynamic array, enum payload,
  struct field, or `Box`.
- Passing it to an ordinary named function, function pointer, extern, or other
  callee whose body/contract is not checker-known to invoke the closure without
  retaining or returning it.
- Capturing it inside another closure that is not itself proven non-escaping.

Future non-escaping higher-order APIs may add explicit checker-visible
contracts, but no such public annotation exists in v1. Unknown callees are
therefore escaping by default.

Nested arenas follow the same lifetime containment rule. A closure created in
an inner arena may capture an outer reference when the closure cannot outlive
the outer owner; leaving the inner arena is allowed only if the closure does not
also capture inner references or inner region-tagged owner values and the
remaining outer-scope uses are still proven non-escaping. A closure that captures
`(& inner T)` cannot escape the `with-arena inner` body.

```lisp test=ignore name=closure-reference-local-ok reason="specified before reference-capturing closure checker support"
(define (read-ref [x : (& n i64)]) : i64
  0)

(define (closure-local-reference-ok [n : i64]) : i64
  (let [r : (& n i64) (& n)]
    (let [f : (-> i64) (lambda () (read-ref r))]
      (f))))
```

```lisp test=ignore name=closure-reference-return-reject reason="negative example for future reference-capturing closure checker"
(define (read-ref [x : (& n i64)]) : i64
  0)

(define (bad-return-reference-closure [n : i64]) : (-> i64)
  (let [r : (& n i64) (& n)]
    (lambda () (read-ref r))))
```

```lisp test=ignore name=closure-reference-store-reject reason="negative example for future reference-capturing closure checker"
(defstruct SavedCallback
  (run (-> i64)))

(define (read-ref [x : (& n i64)]) : i64
  0)

(define (bad-store-reference-closure [n : i64]) : SavedCallback
  (let [r : (& n i64) (& n)]
    (SavedCallback (lambda () (read-ref r)))))
```

```lisp test=ignore name=closure-reference-pass-unknown-reject reason="negative example for future reference-capturing closure checker"
(define (call-now [f : (-> i64)]) : i64
  (f))

(define (read-ref [x : (& n i64)]) : i64
  0)

(define (bad-pass-reference-closure [n : i64]) : i64
  (let [r : (& n i64) (& n)]
    (call-now (lambda () (read-ref r)))))
```

```lisp test=ignore name=closure-reference-nested-arena-ok reason="specified before reference-capturing closure checker support"
(define (closure-nested-arena-outer-ref-ok) : i64
  (with-arena outer
    (let [text : String (int->string 42)]
      (let [view : (& outer str) (& outer text)]
        (with-arena inner
          (let [f : (-> i64) (lambda () (string-length view))]
            (f)))))))
```

```lisp test=ignore name=closure-reference-inner-arena-reject reason="negative example for future reference-capturing closure checker"
(define (bad-inner-arena-reference-closure) : (-> i64)
  (with-arena inner
    (let [text : String (int->string 42)]
      (let [view : (& inner str) (& inner text)]
        (lambda () (string-length view))))))
```

### 3.11 Owned `String`, borrowed `str`, and byte buffers (v1 design)

This section defines the source contract for the owned `String` / borrowed
`str` split. The `str` frontend and stdlib API migration are implemented
(#1453, #1454): borrowing a `String` place produces a `(& lifetime str)` view,
and stdlib string helpers expose borrowed-`str` signatures (for example
`string-eq-borrowed` and `substring-borrowed` in `stdlib/string.tl`). Several
compiler builtins keep the compatibility `String` forms listed in section 6.1.
It also reserves the v1 mutable byte-buffer family from #2782 so binary IO,
FFI, and builder code do not invent incompatible names while implementation
lands.

#### Source model

- `String` is the owned text value type. It is immutable, move-only, and may
  own active-arena storage or refer to static read-only literal bytes.
- `str` is a borrowed referent type, not a by-value type. A source program may
  write `str` only as the referent of an immutable reference:
  `(& lifetime str)`.
- Bare `str` in a parameter, return, local binding, global, field, enum
  payload, tuple element, or array element position is rejected.
- `(&mut lifetime str)` is rejected because strings are immutable. Mutable byte
  buffers use the `ByteBuf` / `bytes` family below rather than mutable `str`.
- String literals keep type `String`. There is no static-borrowed string
  literal type and no implicit static lifetime in v1.

Borrowing a `String` place produces a borrowed `str` reference:

```lisp test=ignore name=string-borrow-produces-str reason="illustrative borrowed str example; not a standalone program"
(define (text-len [text : (& input str)]) : i64
  (string-length text))

(define (borrow-owned-string [input : String]) : i64
  (let [view : (& input str) (& input)]
    (text-len view)))
```

The call-site auto-borrowing rule from section 3.10 applies to `String` places
through the same referent mapping, so a `String` argument place may satisfy a
parameter of type `(& lifetime str)`:

```lisp test=ignore name=string-auto-borrow-arg reason="illustrative borrowed str example; not a standalone program"
(define (text-len [text : (& input str)]) : i64
  (string-length text))

(define (auto-borrow-owned-string [input : String]) : i64
  (text-len input))
```

Bare `str` is rejected even when it appears to be used read-only:

```lisp test=ignore name=string-borrow-reject-bare-str reason="negative example for the borrowed str checker"
(define (bad-by-value-str [text : str]) : i64
  0)
```

Returned and stored borrowed string lifetimes use the lifetime-parameter rules
specified in section 3.10.1 (implemented by #1722/#804). Without a declared
lifetime relationship, returning or storing a borrowed `str` is rejected unless
the checker can prove the reference is purely local to the current lexical
scope:

```lisp test=ignore name=string-borrow-reject-stored-returned reason="negative example: storing/returning a borrow without a proven lifetime relationship"
(defstruct SavedText
  (text (& input str)))

(define (bad-return-borrow [input : String]) : (& input str)
  (& input))
```

Arena escape checks apply to borrowed string views exactly like other
references. A borrowed view of a scoped-arena `String` cannot escape the scoped
arena:

```lisp test=ignore name=string-borrow-reject-arena-escape reason="negative example for the borrowed str checker"
(define (bad-scoped-text) : (& phase str)
  (with-arena phase
    (let [text : String (int->string 42)]
      (& phase text))))
```

Borrowing a `String` is non-consuming. Moving the owner while a borrowed view is
live is rejected by the move/borrow checker:

```lisp test=ignore name=string-borrow-reject-move-while-borrowed reason="negative example for the move and borrowed str checker"
(define (bad-move-while-borrowed [input : String]) : i64
  (let [view : (& input str) (& input)]
    (let [moved : String input]
      (string-length view))))
```

#### Mutable byte buffers and byte slices

The final names are reserved now, before stdlib and FFI code depend on ad hoc
binary storage names:

| Concept | Source spelling | Contract |
|---------|-----------------|----------|
| Owned mutable byte buffer | `ByteBuf` | Move-only aggregate handle owning active-arena byte storage with `len <= capacity`. |
| Immutable byte slice | `(& r bytes)` | Copyable immutable borrowed view over initialized bytes owned by `r`. |
| Mutable byte slice | `(&mut r bytes)` | Exclusive borrowed view over a fixed initialized byte range owned by `r`. |

`ByteBuf` is binary storage, not text. It has no encoding invariant and carries
no NUL terminator guarantee. It owns the initialized live range `[0, len)` and
may reserve additional capacity. Safe code cannot read spare capacity; helpers
that expose spare capacity for host reads or in-place initialization must either
initialize the newly exposed range before increasing `len`, or remain `unsafe`.

Construction, copy-in, growth, reserve, and conversion-to-owned-result helpers
allocate in the active arena. A `ByteBuf` created inside `(with-arena r ...)`
has type `(in r ByteBuf)` and cannot escape the scoped arena. Growing a buffer
may allocate a larger backing store in the same active arena and copy live bytes;
the old store stays allocated until its arena is reset or the process exits.
`ByteBuf` follows the move-only aggregate rules in section 4.6.2.

`bytes` is a borrowed referent like `str`, not a first-class value type. It
appears only behind `&` or `&mut`. An immutable `bytes` view permits reads only.
A mutable `bytes` view is exclusive and fixed-length: it may write existing
indices but cannot append, reserve, or change the owner's length. Direct
indexing, slicing, and mutation helpers for `ByteBuf`/`bytes` use the same
runtime bounds discipline as arrays and strings: negative or out-of-range
indices and invalid `[start, start + len)` slices trap through the ordinary
out-of-bounds path unless an API is explicitly named as checked/try-style.

The stdlib implementation uses `stdlib/byte_buf.tl`, with
`byte-buf-*` helper names for owned-buffer operations and `bytes-*` helper names
for borrowed-slice operations. The required semantic operations are:

- create an empty buffer or a buffer with capacity;
- inspect length/capacity and read initialized bytes;
- push, set, clear, and reserve through an owned `ByteBuf` place or a mutable
  reference to that owner;
- borrow the live range as `(& r bytes)` or `(&mut r bytes)`;
- copy from a `String`, `(& r str)`, `(Array u8)`, or `(& r bytes)` into a fresh
  `ByteBuf`;
- copy a `ByteBuf` or `(& r bytes)` into a fresh active-arena `String` or
  `(Array u8)`.

Conversions are explicit:

- `String` and `(& r str)` may be viewed as immutable `(& r bytes)` without
  copying because TypeLisp strings are byte strings. They never produce
  `(&mut r bytes)`.
- `String` / `str` to `ByteBuf` copies into new mutable active-arena storage.
- `ByteBuf` to `String` copies the live bytes into a new immutable active-arena
  `String`. There is no borrowed `str` view of mutable buffer storage in v1.
- `ByteBuf` to `(& r bytes)` or `(&mut r bytes)` is a borrow of the live range
  with no copy. While an immutable view is live, mutation/growth through the
  owner is rejected. While a mutable view is live, any aliasing read, write,
  move, or growth of the owner is rejected by the borrow checker.
- `(Array u8)` remains a compatibility storage shape. New public binary APIs
  should use `ByteBuf`/`bytes`; array conversion is an explicit
  copy or explicit borrowed view over a declared live prefix.

```lisp test=ignore name=bytebuf-borrow-surface reason="illustrative surface; import omitted"
(define (first-byte [view : (& input bytes)]) : u8
  (bytes-ref view 0))

(define (overwrite-first [view : (&mut input bytes)] [value : u8]) : unit
  (bytes-set! view 0 value))

(define (render-owned [buf : ByteBuf]) : String
  (byte-buf-to-string buf))
```

FFI and IO boundaries are explicit. Borrowed byte views are pointer/length
values in safe code, not raw pointers. Helpers that expose `(Ptr u8)` or
`(MutPtr u8)` from `bytes`/`ByteBuf` are raw-pointer escape hatches and must be
usable only in `unsafe` contexts or through APIs whose safety preconditions are
spelled out. The pointer is valid only for the lifetime of the borrow and only
while the owner is not grown, moved into an invalidating context, or invalidated
by arena reset/destroy.

C APIs that require NUL-terminated strings still require an explicit
NUL-terminated copy such as the `ffi-c-string-*`/`ffi-cstr` family; neither
`ByteBuf` nor `bytes` implies trailing NUL, forbids interior NUL, or coerces to a
C string pointer. Future binary IO helpers should accept `(& r bytes)` for
non-consuming writes, return owned `ByteBuf` for allocated reads, and fill
caller-provided `ByteBuf`/`(&mut r bytes)` storage only under the exclusive
mutable-borrow rules. Existing `String`-returning IO remains compatibility
surface until those helpers land.

`TextBuf` is intentionally separate. It is an append-oriented text builder over
owned or borrowed string chunks whose render operation materializes an immutable
`String`; it is not a random-access mutable byte buffer and must not become the
binary slice contract by accident. Generated slices such as `I64Slice` in
`stdlib/vector_slice.tl` remain typed collection views. `bytes` is the
language-wide raw byte-slice referent for binary data and FFI/IO boundaries.

#### API classification

The #1453/#1454 migration gave the stdlib surface borrowed-`str` signatures for
non-consuming text inputs; several compiler builtins still expose compatibility
`String` parameters. New APIs should use borrowed `str` for non-consuming text
inputs while preserving owned `String` results for allocation sites.

| Category | Members | v1 ownership contract |
|----------|---------|-----------------------|
| Non-consuming text inspection | `string-length`/`length`, `string-ref`/`char-at`, `string-eq`/`string=?`, `string->int`, stdlib predicates such as `string-contains`, `string-contains-char`, and `is-string-prefix-at` | Accept borrowed `(& r str)` inputs and return scalars. They do not move or allocate text. |
| Text output and diagnostics | `print-string`/`print-str`, `print-error`, `panic`/`error`, `stdout-write`, `stderr-write`, `write-file`, append/write status helpers, process stdin strings | Accept borrowed `(& r str)` text/path/message inputs. Host I/O may copy bytes outside the language heap but does not take TypeLisp ownership. |
| Active-arena owned string results | `arg`, `read-file`, `file-read-chunk-bytes`, `read-stdin-line`, `read-stdin-bytes`, `int->string`, `str-cat`/low-level concat primitives, `substring`/`string-slice`, stdlib trim/replacement helpers when they build text, env/path split/join helpers | Return owned `String` storage allocated in the active arena. Results created inside a scoped arena cannot escape that arena. |
| Borrowed string views | `substring-view`/`string-slice-view`, stdlib trim `*-view` helpers | Return `(& r str)` views tied to the input lifetime. Bounds traps match the owned-copy APIs. They do not copy bytes; a runtime helper may allocate fixed metadata for the view record, but it does not take ownership of or extend the backing bytes. |
| Caller-provided fallback/result values | `stdlib/string.tl` `string-replace` when no match is found, `stdlib/io.tl` `read-file-or` fallback paths; check-only companion modules `stdlib/string_caller_result.tl` and `stdlib/io_caller_result.tl` | Preserve the caller-owned value instead of allocating. The companion modules expose source/typecheck-only lifetime-preserving aggregate shapes: branch-composed `StringReplaceResult` for replacement helpers and `ReadFileOrResult` for fallback reads. Ordinary runnable wrappers remain conservatively owned-compatible until reference-typed aggregate lowering and fuller branch lifetime unification land (#1722/#804). |
| Mutable or binary byte storage | `ByteBuf`, `(& r bytes)`, `(&mut r bytes)`; dynamic `(Array u8)` compatibility code today | Not modeled as `str`. New binary APIs should use the explicit byte-buffer family; mutable byte views are exclusive borrowed `bytes`, not mutable strings. |

#### ABI and lowering representation

`String` keeps the current aggregate-handle representation: a pointer-sized
source value points at a 16-byte string record containing `(data_ptr, length)`.
The record may describe static literal bytes or active-arena storage.

`(& lifetime str)` is a pointer-sized reference/provenance value whose referent
is an immutable 16-byte `(data_ptr, length)` string view. Borrowing a `String`
place may point the reference at the owned `String` record itself; borrowing a
substring/slice view may point at a runtime-created view record whose metadata
is stable independently of the active arena. The reference does not own, free,
or extend the lifetime of the bytes. Its lifetime is enforced only by the source
checker, and the runtime representation carries no NUL terminator guarantee.

Lowering may pass `(& lifetime str)` to runtime helpers using the same
pointer-sized reference slot shape as other immutable references. Runtime
helpers that read text must consume the view's pointer and length and must not
retain the view beyond the call unless a later API explicitly models that
stored lifetime.

`ByteBuf` uses an aggregate-handle representation analogous to other owned
runtime aggregates. Its inline storage is a pointer/length/capacity record. The
capacity is a source-level invariant, not permission for safe code to read
uninitialized bytes. `(& lifetime bytes)` and `(&mut lifetime bytes)` lower as
pointer-sized reference/provenance values to immutable or mutable slice records
containing `(data_ptr, length)`. Mutable byte views carry exclusivity in the
source checker; the runtime representation does not retain aliasing state.

---

## 4. Top-level forms

### 4.1 `(define name [: type] init)` — global variable

Declares a global variable with a typed or inferred initializer. Scalar constant
initializers can be emitted directly as static data. `String` and aggregate
initializers, including struct, enum, tuple, fixed-array, and dynamic-array
values, are lowered through generated runtime initializer functions when static
data emission is not sufficient. Those initializer functions run before the
selected `main`.

Global initializers are typechecked like ordinary expressions but must be
closed over top-level declarations that are safe to evaluate during global
initialization. Unsupported initializer forms are diagnosed rather than treated
as implicit runtime work.

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

### 4.3 `extern` - external symbol

Declares an external symbol to link against. The function-head form writes fixed
parameters directly on the extern head and uses the return type after `:`; it is
a direct external function declaration. The bare-name form declares an external
data symbol whose value is loaded when the name is used. If that bare-name type
is a function type, the loaded value is a raw C function pointer and calling the
name or a local copy of that value emits an indirect C ABI call through the
loaded pointer. Raw C function-pointer values are ABI-distinct from ordinary
TypeLisp function and closure descriptor values.

The name is a TypeLisp identifier used for source lookup; it defaults to the
target C ABI and uses the local name as the external linker symbol unless
metadata overrides it.

```lisp test=ignore name=extern-function-head-varargs reason="requires current selfhost parser"
(extern (printf [fmt : (Ptr u8)] ...) : i32 (:symbol "printf"))
(extern (sumf [count : i64] [value : ...f64]) : i32 (:symbol "sumf"))
```

In a function-head extern, bare `...` marks an open C varargs tail. A bracketed
parameter whose type is `...T` marks a typed C varargs tail; every variadic call
argument must typecheck as `T`. The marker must be final, and the fixed argument
count is derived from its position. The marker is not included in the declared
fixed function type.

Metadata appears outside the function head after the return type:

- `(:abi c)` selects the C ABI. Unknown ABI names are rejected.
- The legacy `(:abi c-varargs fixed-count)` metadata form is retired. Use a
  function-head `...` or `...T` varargs marker instead; the fixed argument count
  is derived from the marker position.
- `(:symbol "exact_name")` supplies the external linker symbol independently of
  the local TypeLisp name.
- `(:link-lib "name")` adds a native library input for source `build`/`run`.
- `(:link-search "dir")` adds a native library search directory for source
  `build`/`run`.
- `(:link-arg "arg")` adds a raw linker argument for source `build`/`run`.

For bare-name external data declarations, metadata appears before the `:`:

```lisp test=ignore name=extern-value-and-function-pointer reason="requires native symbols"
(extern foreign-counter (:symbol "foreign_counter") : i64)
(extern foreign-add-ptr (:symbol "foreign_add_ptr") : (-> i64 i64))
(define (main) : i64 (+ foreign-counter (foreign-add-ptr 35)))
```

Function-head varargs are valid only for direct function extern declarations,
not for bare external data values or raw function-pointer data symbols.

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

For function-head varargs declarations, the backend emits the extra platform
call setup needed by the C ABI: SysV x86_64 sets `%al` to the vector-register
argument count, and Windows x64 duplicates variadic floating-point register
arguments into the corresponding integer argument registers.

Example:
```lisp test=check name=extern-declaration
(extern (foreign-add [a : i64] [b : i64]) : i64)
```

```lisp test=ignore name=extern-metadata-declaration reason="requires the selfhost parser metadata form"
(extern (local-add [a : i64] [b : i64]) : i64 (:symbol "foreign_add_exact"))
```

```lisp test=ignore name=extern-link-metadata-declaration reason="requires native library fixture"
(extern (native-add [a : i64] [b : i64]) : i64 (:link-search "native/lib") (:link-lib "native_math"))
```

### 4.3.1 `(unsafe declaration)` - unsafe functions and externs

An unsafe declaration is written by wrapping exactly one function `define` or
`extern` declaration:

```lisp test=ignore name=unsafe-declaration-surface reason="demonstrates call-site gating"
(unsafe (define (raw-read [p : (Ptr i64)]) : i64
  (unsafe (ptr-read p))))

(unsafe (extern (foreign-write [arg0 : (MutPtr i64)] [arg1 : i64]) : unit))
```

The wrapper is declaration metadata, not a runtime expression. It is preserved
through module loading, package transformation, imports, aliases, macro
expansion, and lowering. Safe code may mention the declared type only by entering
an explicit `(unsafe ...)` expression; a safe direct call or safe function-value
reference is rejected and the diagnostic names the callee. An unsafe function
body is still checked as ordinary safe code unless the body itself uses
`(unsafe ...)`. A local or later declaration that shadows the same name does not
inherit the unsafe marker.

```lisp test=ignore name=extern-raw-pointer-signature reason="requires the selfhost raw-pointer checker path"
(extern (strlen [arg0 : (Ptr u8)]) : u64)
(extern (fill-bytes [arg0 : (MutPtr u8)] [arg1 : u64] [arg2 : u8]) : unit)
```

### 4.4 `(import "path.tl")` — module import

Imports another TypeLisp file. The current loader still preserves the legacy
whole-program concatenation model: all top-level definitions from the imported
file become available in one flat namespace. The selfhost module model
specified below replaces that with canonical module identities, explicit
exports, and qualified lookup.

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

The canonical identity is a dotted identifier path such as
`stdlib.string`, `compiler.lower`, or `math.vector`. It must be stable across
platform path separators and package-root spellings. A `pkg:<alias>/...` import
contributes the package alias to the loader identity, but an explicit `(module
...)` declaration inside the file remains the public source-level identity.

Importing a module loads it and binds a module alias; it does not merge exported
declarations into the local unqualified namespace by default. The default alias
is the final segment of the imported module identity. If that alias would
collide with an existing module alias, the import is rejected unless the source
uses an explicit alias:

```lisp test=ignore name=module-import-alias-syntax reason="selfhost module aliases are tracked by #952"
(import "math/vector.tl" module math.vector :as vec)
(import "io/vector.tl" module io.vector :as io-vec)
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
an opaque type export: external modules can mention `geometry.Point` but cannot
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

Qualified source names use `.`: `alias.name` for one alias segment and
`module.path.name` for a full canonical module path. Full canonical paths are
accepted only when that module identity has been imported in the current module
or when the use appears inside the same module. Unqualified lookup searches only
local declarations and local bindings. It does not search imported modules.
Slash-qualified source names such as `alias/name` are rejected; `/` remains the
ordinary division operator.

In expression and place contexts, a dotted name whose leading segment is a local
binding is local struct-field sugar before qualified module lookup. For example,
`data.value` resolves as `(struct-get data value)` when `data` is a local
binding, even if `data` is also an imported module alias. If the leading segment
is not local, the existing qualified lookup rules below apply.

Qualified lookup applies to:

- Values: `(vec.dot a b)`, `config.default-timeout`.
- Types: `[p : geometry.Point]`.
- Enum variants and patterns: `(json.Some value)` and `[(json.Err e) ...]`.
- Struct constructors: `(geometry.Point 3 4)`.
- Struct fields: `(struct-get p x)` resolves `x` through the receiver's struct
  type; exporting the field controls whether external modules may use it.
- Macros: `(bool.and2 a b)` resolves `and2` in the imported module's macro
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
(define (main) : i64 (+ (left.get) (right.get)))
```

#### 4.4.4 Macro export/import and expansion ordering

Macro-bearing modules use the same loader identity and path-resolution rules as
ordinary imports. Relative paths, canonical module identities, stdlib-root
fallback, and `pkg:<alias>/...` package dependency resolution are shared with
sections 4.4 and 4.4.1; there is no separate macro search path.

The compile driver prepends `stdlib/core_macros.tl` as an implicit macro
prelude. Bare `when`, `unless`, `and`, `or`, and bracket-arm `cond` resolve to
exported macros from `stdlib.core_macros` unless a local or imported macro with
the same name takes precedence. The core `cond` surface is
`(cond [test expr] ... [else fallback])`; flat
`(cond test expr ... fallback)` calls are rejected. The module can also be
loaded with an
ordinary explicit import, for example
`(import "stdlib/core_macros.tl" module stdlib.core_macros as core)`, and its
exports can be called through the import alias such as `core.when`,
`core.unless`, `core.and`, `core.or`, and `core.cond`.

Before expanding a module's non-import forms, the loader parses the module,
collects its import declarations, recursively loads imported modules, and builds
the imported macro namespace from each dependency's exported macro items.
Imported macros are then available to the importer for the entire expansion of
that module through qualified names such as `bool.and2`. The imported macro's
typed signature is used for call-site checking in the importing module; operand
expressions are not evaluated before expansion.

Local macros are module-scope declarations. A local `defmacro` is available to
all non-import forms in its module after imports and generated declarations have
been processed, regardless of whether the call appears before or after the
declaration. Local macros may call imported macros and any local macro in the
same module; recursive expansion is bounded by the macro expansion depth limit
and rejected with a source-located diagnostic.

Macro export tables are complete after the exporting module's own imports and
local macro declarations have been collected. V1 rejects cycles that require a
macro export from a module whose macro table is still being built. Non-macro
import cycles keep the ordinary loader behavior described in section 4.4 until
the general module-cycle policy is tightened.

Diagnostics required by v1:

- Missing macro export: a qualified macro head names an imported module but no
  exported macro of that name.
- Private macro: the exporting module has a local macro of that name but does
  not export it with `(export (macro name))`.
- Duplicate macro export: two distinct macro declarations would be exported
  under the same `(module, macro-name)` identity.
- Unknown export item: `(export (macro name))` names no local macro.
- Recursive macro expansion: expanding a macro reaches the implementation's
  deterministic depth limit, typically because macros expand to each other in a
  cycle.

Cross-module macro use:

```lisp test=ignore name=module-exported-macro-use reason="macro export/import expansion is tracked by #1140"
;; bool_macros.tl
(module bool-macros)
(defmacro (and2 [lhs : bool] [rhs : bool]) : bool
  (expr-if lhs rhs (expr-bool false)))
(export (macro and2))

;; main.tl
(import "bool_macros.tl" module bool-macros :as bool)
(define (main) : i64
  (if (bool.and2 true true) 0 1))
```

Private or missing macro diagnostic:

```lisp test=ignore name=module-private-macro-diagnostic reason="negative macro visibility example for #1140"
;; hidden.tl
(module hidden)
(defmacro (private-and [lhs : bool] [rhs : bool]) : bool
  (expr-if lhs rhs (expr-bool false)))

;; main.tl
(import "hidden.tl" module hidden :as hidden)
(define (main) : i64
  (if (hidden.private-and true true) 0 1)) ; error: private macro hidden.private-and
```

Forward local macro use:

```lisp test=ignore name=module-forward-local-macro-use reason="macro ordering example for #2584"
(define eager : bool (late true)) ; accepted: local macros are module-scope

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

- Text-only: the file is read as UTF-8 source payload. Use `include-bin` for
  arbitrary binary payloads.
- `path` is resolved exactly like an `import` path (§4.4): relative paths resolve
  from the including file's directory, and `stdlib/...` paths use the same
  stdlib-root / embedded-provider precedence and the same parent-escape (`..`)
  rejection. The included file is read as raw text — it is not parsed as a
  module, runs no imports or tests, and does not participate in import
  deduplication.
- An include failure reports both the including file and the requested path.

#### 4.4.7 `(include-bin name "path")` - embed a binary file

Embeds the exact byte contents of `path` as a global `name : (Array u8)`. This
is the binary sibling of `include-str`: the module loader resolves and reads the
file during compilation, then expands the directive into a generated global
definition before typechecking, lowering, and codegen.

- Bytes are embedded exactly as read, including NUL bytes, bytes above 127, and
  trailing newlines. There is no UTF-8 decoding, escaping, or source parsing.
- `path` resolution and failure diagnostics are the same as `include-str`.
- The current representation is a process-global static dynamic-array header
  pointing at writable static data. No startup copy is required. Because the
  surface type is mutable `(Array u8)`, writes intentionally mutate the global
  static payload for the process; use included payloads as read-only unless that
  shared mutation is intended.

#### 4.4.8 `(cfg predicate declaration)` - conditional compilation

`cfg` conditionally includes source forms before normal declaration parsing and
import resolution. The selfhost compiler supports top-level declarations of the
shape `(cfg predicate declaration)`. If `predicate` is true, `declaration` is
parsed in place; if it is false, the declaration is skipped.

Predicates are inspired by Rust `cfg`:

- `name` is true when the compiler command enabled `--cfg name`.
- `(all predicate...)` is true when every operand is true; with no operands it
  is true.
- `(any predicate...)` is true when any operand is true; with no operands it is
  false.
- `(not predicate)` negates exactly one predicate.

In addition to explicit `--cfg` names, the compiler enables target OS predicates
from the selected backend target. `linux-x86_64` enables `linux`, `unix`,
`target-linux`, and `os-linux`. `windows-x86_64` enables `windows`,
`target-windows`, and `os-windows`. These names are available to both top-level
and expression-level `cfg` forms, including imports.

Inactive branches must still be lexically valid S-expressions, but they are not
parsed as TypeLisp declarations or expressions. This is intended for stage and
platform conditionals where a newer compiler can see instrumentation or helper
calls that an older stage0 must skip.

Expression lists may also contain `(cfg predicate expr)` forms. A false
expression-list cfg is omitted. In required expression position, `(cfg predicate
then-expr)` evaluates to `unit` when the predicate is false; `(cfg predicate
then-expr else-expr)` parses only the selected expression.

### 4.5 `(test name body...)` - inline test item

Declares a source-owned inline test. The name is an identifier. The body must
contain one or more expressions; multiple expressions are sequenced like
`begin`.

Normal production commands (`check`, `compile`, `build`, and `run`) ignore
`test` items. `typelisp test <file.tl>` loads the import graph, lowers inline
tests owned by the requested source into private unit-returning functions, skips
any production `main`, generates a test-owned `main`, and runs the resulting
executable. Imported files provide runtime declarations but do not contribute
their own inline tests to that source's harness. The test loader enables the
`test` cfg predicate, allowing source-local fixture declarations to be written as
`(cfg test ...)` so normal production commands skip them. `typelisp test --check
<file.tl>` type-checks the generated harness without assembling or linking. The
current runner is intended for unit-returning test bodies; assertion helpers in
`stdlib/test.tl` panic on failure.

Example:
```lisp test=check name=inline-test-declaration
(import "stdlib/io.tl")

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
    (math "../math")
    (lint (github "JoNil-Botta/typelisp-lint" (rev "abc123")))))
```

- `name` and `version` are required string fields.
- `kind` is optional. When present, it accepts `bin` and `staticlib` as symbols
  or strings; `lib` remains accepted as a compatibility alias for `staticlib`.
  `bin` produces a native executable; `staticlib` produces a static archive.
- `entry` is optional. It defaults to `src/main.tl` for `bin` packages and
  `src/lib.tl` for `staticlib` packages. An explicit `entry` string overrides
  the convention default.
- When both `kind` and `entry` are omitted from a disk-backed manifest, package
  loading inspects the manifest directory: if only `src/main.tl` exists, the
  package is a `bin`; if only `src/lib.tl` exists, the package is a
  `staticlib`. If both conventional entry files exist, the package loader emits
  a diagnostic requiring an explicit `kind` or `entry`. If neither exists, it
  emits a diagnostic requiring an explicit `kind`/`entry` pair or a conventional
  entry file. Source-string manifest parsing that has no filesystem context
  keeps the compatibility default of `bin`.
- `dependencies` is optional. Each entry has an alias symbol and either a
  string root path, `(alias "relative/or/absolute/path")`, or a GitHub
  shorthand source, `(alias (github "owner/repo" (rev "commit")))`.
- GitHub shorthand also accepts `github.com/owner/repo` addresses. It requires
  exactly one non-empty `rev`, `tag`, or `branch` string pin and normalizes to a
  git remote URL with a pin fragment such as
  `https://github.com/owner/repo.git#rev=commit`.
- Dependency aliases use the same character rules as package names: ASCII
  letters, digits, `-`, and `_`; duplicate aliases are rejected.
- `entry` is resolved relative to the manifest directory.
- Relative dependency paths are resolved relative to the manifest directory;
  absolute dependency paths are used as written. GitHub remote entries use
  `typelisp.lock` and the package cache before falling back to `git`; resolved
  commits are written as deterministic lock entries. Remote dependencies are
  consumed through either the package cache or the legacy
  `target/typelisp/git-deps/<alias>` checkout root. A pre-existing legacy
  fetched root with `typelisp.pkg` is used as-is unless it has a `.git`
  directory, in which case the checkout is refreshed. `--locked` requires
  matching lock entries and never rewrites `typelisp.lock`; missing, stale, or
  extra lock entries fail. `--update-lock` intentionally refreshes remote pins
  and rewrites `typelisp.lock`.
- `typelisp.lock` is a deterministic v1 S-expression lockfile for resolved
  remote package pins:

  ```lisp test=ignore name=package-lock reason="lockfile data, not TypeLisp source"
  (typelisp-lock
    (version "v1")
    (dependencies
      (dependency
        (alias "lint")
        (url "https://github.com/JoNil-Botta/typelisp-lint.git")
        (pin (tag "v1.0.0"))
        (commit "0123456789abcdef0123456789abcdef01234567"))))
  ```

  Each dependency records the manifest alias, normalized URL, original pin
  kind/value (`rev`, `tag`, or `branch`), and exact resolved commit. Duplicate
  aliases, duplicate fields, missing required fields, malformed entries,
  non-string values, and unknown versions are rejected. Emitters write stable,
  human-readable entries sorted by alias. Package builds load `typelisp.lock`
  from the declaring package root. A lock entry is replayed only when its alias,
  URL, pin kind, and pin value match the manifest dependency; replay converts
  the dependency to the recorded exact `rev` commit before fetching. Missing or
  stale entries are resolved from the manifest pin and included in the next
  emitted lockfile by default. The build writes a deterministic lockfile
  whenever the package has remote dependencies or a prior lockfile exists.
  `--locked` turns missing or stale entries into errors, while `--update-lock`
  refreshes remote pins intentionally.
- Remote package cache helpers use a deterministic v1 root below the package
  root at `target/typelisp/cache/packages/v1`. Entry paths are derived from the
  normalized remote URL and an exact `rev` commit pin; `tag` and `branch` pins
  must be resolved before key construction. A cache entry is reusable only when
  its metadata file matches the URL/commit key and its completion marker is
  present and valid and the cached root contains `typelisp.pkg`. Complete cache
  entries are reused without invoking `git`, including during locked replay.
  Missing markers, missing metadata, metadata mismatches, and missing package
  manifests are partial/corrupt hits, not reusable hits; package builds refetch
  them through a staging directory and preserve conflicting corrupt entries with
  a `.corrupt.N` suffix before replacement. The helper layer owns cache
  key/path/state/marker/finalize primitives; `build_cli_core.tl` owns pin
  resolution, fetching, lockfile updates, and package build integration.
- Local dependency manifests are loaded into a normalized DAG keyed by manifest
  path before build execution. Transitive dependency packages build once per
  root build invocation, diamond graphs de-duplicate the common archive,
  independent ready nodes are scheduled concurrently when async process handles
  are available, and dependency cycles fail before code generation with a
  diagnostic that includes the manifest path chain. Hosts without async child
  handles use a serial fallback with the same graph ordering and diagnostics.
- Dependency packages must be `staticlib`/`lib` packages; a `bin` dependency is
  rejected as a package graph diagnostic.
- `typelisp build --manifest-path path/to/typelisp.pkg` builds the entry file
  through the same module loader and compiler pipeline as `compile`.
- `typelisp build` without `--manifest-path` searches for `typelisp.pkg` from
  the current directory upward.
- Package `typelisp check` typechecks the manifest entry's transitive import
  closure once, matching the program closure that package `build` validates.
  Package `check` and package `build` typecheck doc-comment examples only in
  that reachable closure. Source files outside the closure are intentionally not
  package-check/build inputs; validate them through explicit file checks,
  `typelisp doc --test <file>`, or package test coverage.
- Package builds accept `--profile dev|release` and `--release`. The default
  profile is `release`; `--release` is an alias for `--profile release`.
  `--opt-level 0|1|2` overrides the profile's optimizer level. Without an
  explicit level, `release` uses level 2 and `dev` uses level 0.
- Package builds accept `--locked` to require a matching `typelisp.lock`
  without rewriting it, and `--update-lock` to refresh remote pins and rewrite
  the lockfile. These flags are rejected for source-file builds and non-package
  commands.
- Build outputs are written under
  `target/<profile>/` in the package root. `bin` packages produce
  `<package-name>` on Linux and `<package-name>.exe` on Windows. `staticlib`
  packages produce `lib<package-name>.a` on Linux and `<package-name>.lib` on
  Windows. Assembly and object side artifacts use the same profile directory.
  Package builds also produce a metadata-only comptime image named
  `<package-name>.tlci` in the same profile directory. Dependency package DAG
  builds produce the dependency package's tlci file next to its static archive
  without changing runtime link behavior.
- The optional top-level `(link ...)` section declares native link inputs for
  `bin` package builds, so a package that links system or vendored libraries
  does not need `(:link-lib ...)`/`(:link-search ...)`/`(:link-arg ...)`
  metadata on every `extern`:

  ```lisp test=ignore name=package-link reason="manifest file, not TypeLisp source"
  (package
    (name "tl-platformer")
    (version "0.1.0")
    (link
      (libraries "raylib")
      (search-paths "vendor/raylib/lib")
      (linux-libraries "GL" "m" "pthread" "dl" "rt" "X11")
      (windows-libraries "opengl32" "gdi32" "winmm" "shell32" "user32")))
  ```

  - `libraries`, `search-paths`, and `args` apply to every target. `libraries`
    are native library names (`-l<name>` on Linux, `<name>.lib` on Windows),
    `search-paths` are library search directories (`-L<dir>` / `/LIBPATH:<dir>`),
    and `args` are raw linker arguments passed through verbatim.
  - `linux-libraries`, `linux-search-paths`, `linux-args` and
    `windows-libraries`, `windows-search-paths`, `windows-args` add inputs only
    when building for that target.
  - Each field is a list of one or more non-empty strings. Unknown field names,
    a repeated `link` section, a repeated field, empty strings, and non-string
    values are rejected with manifest diagnostics.
  - Relative `search-paths` (all-target and per-target) are resolved against the
    manifest directory before the linker runs, so builds are independent of the
    caller's working directory. Absolute search paths, library names, and raw
    arguments are used as written.
  - Effective link inputs for a `bin` build are assembled in first-seen order
    with exact duplicates removed within each class (libraries, search paths,
    raw args): all-target manifest inputs, then the selected target's inputs,
    then source `extern` link metadata from the package entry/import graph, then
    the static archives of package dependencies (kept positional after the
    requested libraries and arguments). On Linux, any non-empty link input
    switches the package link from the freestanding `ld` path to the `cc` path
    so the program links against the C runtime and the requested libraries.
  - The `link` section affects only `bin` artifacts. `staticlib` packages still
    emit an archive, and a dependency package's `link` section is not yet
    propagated to a dependent `bin`, so declare shared native inputs in the
    binary package's own manifest. Dynamic/shared library output remains out of
    scope for this package layer.
- Package-root-qualified imports use the reserved string prefix
  `pkg:<alias>/...`, for example `(import "pkg:math/src/lib.tl")`.
- Package-manager roadmap boundary for the next package phase:
  - Registry support is deferred. The implemented model is explicit local paths
    plus git/GitHub sources fetched by the host `git` CLI and pinned by
    `typelisp.lock`. A future registry must be optional for building checked-in
    packages, TypeLisp-owned, and compatible with the zero third-party
    dependency policy.
  - Semantic-version solving is a non-goal for the next package-manager phase.
    Manifests name exact `rev`, `tag`, or `branch` pins, and lock replay records
    exact commits. The build does not solve version ranges, choose among
    competing package versions, or fetch multiple candidates.
  - Workspaces are deferred. Current package roots have independent manifests,
    locks, target directories, and local dependency DAGs. A future workspace
    model may group local packages and share orchestration/lock policy, but
    every package must continue to build without a workspace file.
  - Implicit preludes and dynamic/shared library output remain non-goals for
    this package layer. Namespace isolation and qualified symbol access are
    specified by the selfhost module model in section 4.4, not by package
    resolution itself.

### 4.6 `(defenum ...)` and `(defstruct ...)`

See §3.5.

#### 4.6.1 Cleanup-owning aggregate declarations (implemented for structs; enum lowering pending)

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

```lisp test=ignore name=cleanup-owning-buffered-file-struct reason="sketch omits concrete external cleanup hooks"
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

```lisp test=ignore name=cleanup-owning-nested-struct reason="sketch omits concrete external cleanup hooks"
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

```lisp test=ignore name=cleanup-owning-reject-ordinary-storage reason="negative cleanup-required aggregate check"
(defstruct FileHandle
  (:cleanup close-file-handle)
  (fd i64 (:cleanup close-fd)))

(defstruct BadWrapper
  (handle FileHandle))
```

`BadWrapper` is rejected because it stores a cleanup-owning value without
declaring its own cleanup ownership and without marking the field `(:owned)`.

```lisp test=ignore name=cleanup-owning-reject-copy reason="negative move-only cleanup-owning aggregate check"
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

```lisp test=ignore name=cleanup-owning-reject-escape reason="negative cleanup-owning aggregate escape check"
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

Cleanup-owning `defenum` declarations reserve the shape
`(defenum Name (:cleanup cleanup-fn) variant+)`. The parser and typechecker
accept the metadata, validate payload cleanup functions, and reject ordinary
enum payloads that store cleanup-required or cleanup-owning values without an
owning cleanup contract. Lowering of generated enum cleanup functions remains
pending: until it lands, cleanup-owning enums are a checked metadata surface,
not a runtime cleanup surface. A cleanup-owning enum must eventually clean only
the active variant payload, in reverse payload declaration order, using
field-style `(:cleanup ...)` and `(:owned)` payload metadata.

#### 4.6.2 Move-only aggregate handle semantics (specified, pending implementation)

The v1 source semantics make aggregate handles move-only. Some compatibility
paths may still accept copies until the selfhost move checker lands, but new
source and selfhost implementation work must follow this contract.

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
- `ByteBuf`.
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
- `match` scrutinees. Matching a move-only enum by value consumes the whole enum
  value. Payload bindings then own the active payload values for that arm.
  Matching `(& place)` when the borrowed referent is an enum is the non-consuming
  borrowed form described below.
- Closure capture. Capturing a move-only local by value moves it into the
  closure environment at closure creation time; the local cannot be used after
  the lambda literal. Immutable reference captures are governed by section
  3.10.2 and are implemented for non-escaping closures (#808/#2280); mutable
  reference captures remain rejected in v1.

Repeated loop bodies are conservative move contexts. Moving a move-only owner
binding that is visible before a `while` or `foreach` body is rejected because a
later iteration could reuse the moved owner. Moving an owner created inside the
loop body is allowed for that iteration. Body move state is not propagated after
the loop because the loop may execute zero times.

**Non-consuming use sites.** A non-consuming use may inspect a move-only value
without moving it. In v1 these are limited to:

- Immutable and mutable borrow expressions `(& place)` / `(&mut place)` and
  their explicit-lifetime forms.
- Borrowed enum matches over `(& place)` / `(& lifetime place)`. The match
  inspects the active enum variant without moving the enum owner.
- Compatibility inspection calls whose current signatures are not yet
  reference-typed: `length`/`string-length`, `string-ref`/`char-at`,
  `string-eq`/`string=?`, `string->int`, `print-string`/`print-str`,
  `print-error`, dynamic-array `length`/`array-length`, `array-ref` when the
  element type is copyable, `struct-get` when the selected field type is
  copyable, and stdlib predicates that only inspect their aggregate argument.
- `array-set!` and `array-push!` on an owned array receiver or mutable
  reference receiver. These operations mutate the array storage and do not move
  the array handle; immutable-reference receivers are rejected.
- Struct field-place assignment `(set! (struct-get place field) value)` on an
  owned struct receiver or mutable-reference receiver. Local dotted sugar such
  as `(set! place.field value)` is the same place operation. This mutates only
  the selected field; immutable-reference receivers are rejected.
- Box-place assignment `(set! (box-get place) value)` and mutable borrows of
  `(box-get place)` through a live box storage place. These operations mutate or
  borrow the boxed storage and do not move the box handle.

Ordinary user-defined function parameters are by-value unless their type is a
future reference type. Passing a `String`, array, tuple, struct, enum, or
capturing closure to such a parameter consumes the argument.

**Whole-place and path moves.** The v1 checker accepts whole-place moves for
locals, parameters, and whole constructor temporaries. It also tracks
owner-consuming direct and nested paths through struct fields, tuple elements,
and fixed-array literal indexes, so moving one tracked path does not move its
siblings. Moving a tracked path marks the root partially moved; later whole-root
owner moves are rejected until every moved path for that root is reinitialized.
`array-set!` to a supported fixed-array path with an integer literal index
reinitializes only that exact path after the receiver, index, and value have
been checked. Reinitializing one element does not clear sibling moved paths; if
it clears the final moved path for the root, the partial-root marker is removed.
Dynamic-array elements, non-literal indexes, implicit moves through `box-get`,
and unsupported path forms do not clear moved state. Struct field-place
assignment reinitializes the selected tracked path when the receiver path is
supported; local dotted field sugar follows the same rule. Box-place assignment
updates boxed storage but does not reinitialize a moved box handle; explicit
`box-take` moves the whole box handle instead. `struct-get`, `tuple-ref`, and
`array-ref` may copy out only copyable fields or elements, and may move out
move-only fields/elements only where this tracked-path policy accepts the path.
A consuming `match` is the enum exception: it moves the whole scrutinee first,
then binds payload values owned by the selected arm.

**Diagnostics.** Move checking must produce source-located diagnostics for:

- Use after move, naming the moved local or path and the move site when known.
- Moving from an uninitialized or already-moved slot.
- Assigning over an initialized move-only slot.
- Moving out of an unsupported path such as a dynamic-array element,
  non-literal fixed-array index, box projection, or unsupported aggregate path.
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

```lisp test=check name=borrowed-enum-match-non-consuming
(defenum MaybeName
  (NoName)
  (SomeName String))

(define (borrowed-name-score [s : (& m str)]) : i64
  (length s))

(define (borrowed-score [m : MaybeName]) : i64
  (match (& m)
    [(SomeName s) (borrowed-name-score s)]
    [NoName 0]))
```

The borrowed `match` inspects `m` without moving it. Payload bindings are
references tied to the borrowed scrutinee lifetime; the `String` payload above
binds `s` as `(& m str)`.

#### 4.6.3 Recursive aggregate layout and boxed recursion (specified; finite analysis implemented)

Ordinary TypeLisp structs and enums have a default inline layout contract.
Recursive-by-value aggregate cycles are therefore infinite source layouts and
must use explicit indirection through `(Box T)`, a raw pointer, or a reference
edge. The current lowering implementation may still carry some aggregate values
through heap handles, but that is not the source layout contract.

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

The selfhost typechecker has reusable finite-layout analysis, and full
enforcement for every default aggregate declaration is staged separately so
existing selfhost recursive data structures can migrate to explicit boxes in
focused slices.

```lisp test=ignore name=box-recursive-list-layout-ok reason="positive recursive aggregate layout example"
(defenum ListI64
  (ListNil)
  (ListCons i64 (Box ListI64)))
```

```lisp test=ignore name=box-recursive-tree-layout-ok reason="positive recursive aggregate layout example"
(defenum Tree
  (Leaf i64)
  (Node (Box Tree) (Box Tree)))
```

```lisp test=ignore name=box-reject-unboxed-recursion reason="negative example for inline aggregate cycle checks"
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
| Character | `'A'`, `'\n'`, `'\t'`, `'\0'`, `'\''`, `'\\'` | `char` |
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
| `bit-and` | integer integer → integer | Bitwise AND |
| `bit-or` | integer integer → integer | Bitwise OR |
| `bit-xor` | integer integer → integer | Bitwise XOR |
| `shl` | integer integer → integer | Left shift |
| `shr` | integer integer → integer | Right shift (arithmetic for signed, logical for unsigned) |

- Integer arithmetic operators require matching operand types and return that type.
- Integer `+`, `-`, `*`, and `neg` wrap modulo 2^N, where N is the result type
  width. Signed integer results use two's-complement interpretation of those
  wrapped bits.
- Boolean `and` and `or` are core macros, not parser-owned binary operators.
  All arities expand through `stdlib/core_macros.tl` and short-circuit.
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

`(cond [test expr] ... [else fallback])` is the conditional macro surface
provided by the implicit core macro prelude. It expands to nested `if`
expressions, so each test must type-check as `bool` and all branch result types
must merge using the normal `if` rules. At least one `[test expr]` arm and a
final `[else fallback]` arm are required. `else` must appear only in the final
arm. Qualified calls such as `core.cond` use the same bracket-arm shape. The old
flat `(cond test expr ... fallback)` shape is rejected.

```lisp test=ignore name=cond-expression reason=fragment
(cond
  [(= x 0) 10]
  [(= x 1) 20]
  [else 30])
```

`(when cond body)` and `(unless cond body)` are unit-valued guard macros.
`when` evaluates its body only when `cond` is true; `unless` evaluates its body
only when `cond` is false. The body must be a single unit-valued expression; use
an explicit `begin` for multiple side effects. The whole form has type `unit`,
which makes these forms suitable for side effects and early-return guards.

```lisp test=ignore name=when-unless-guards reason=fragment
(when (< x 0) (return 0))
(unless (< x 100) (print-string "large\n"))
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
- Aggregate mutation through specific place forms follows the receiver's
  ownership mode. `array-set!` and struct field assignment require an owned
  place or mutable reference receiver; immutable references are rejected.
- Future `ByteBuf`/`bytes` mutation follows the same rule: byte writes require
  an owned `ByteBuf` place, a mutable reference to a `ByteBuf`, or an exclusive
  `(&mut r bytes)` view. Immutable `(& r bytes)`, `(& r str)`, and `String`
  views are read-only.

### 5.11 `(ann expr : type)` — type annotation

- Forces `expr` to have the given type.
- Useful for disambiguating literal types.

### 5.12 `(cast expr : type)` — type conversion

See §3.8. Casts cover the full scalar numeric matrix: integer/`char`
widening, narrowing, and truncation; `f64` ↔ `f32` precision changes; and
integer/`char` ↔ float conversions (float → integer truncates toward zero).

### 5.12.1 `(init : T)` and contextual `(init)` - zero/identity initialization

TypeLisp follows Zero Is Initialization (ZII): `init` constructs a valid
initialized source value for its type. It does not expose arbitrary zero-bit
states. For example, `String` initializes to a valid empty string handle, an
enum initializes through a real variant constructor, and a default-layout struct
initializes by recursively initializing its fields.

There are two source forms:

- `(init : T)` is the explicit form. It carries the target type in the source.
- `(init)` is contextual. It is accepted only where an expected type is known,
  such as an annotated `define`, annotated `let`, declared function return,
  function argument, struct/enum constructor field, array literal element,
  `array-set!`, or `array-push!` position. Ambiguous `(init)` is rejected with
  a diagnostic asking for `(init : T)` or an annotation.

`init` remains compatible with ordinary functions named `init`: `(init)` and
`(init : T)` are parser-owned special forms, while `(init arg...)` is parsed as
an ordinary call unless the first argument is `:`.

ZII eligibility:

| Type shape | `init` value |
|------------|--------------|
| Signed/unsigned integers | numeric zero of that width |
| `f64`, `f32` | `0.0` |
| `bool` | `false` |
| `char` | NUL byte (`'\0'`) |
| `unit` | `unit` |
| `(Ptr T)`, `(MutPtr T)` | typed null raw pointer |
| `String` | valid empty string |
| `(Array T)` | valid empty dynamic array; `make-array` uses the same element rules for live elements |
| `(Tuple T0 T1 ...)` | tuple of recursively initialized elements |
| `(Array T N)` | fixed array of `N` recursively initialized elements; `N` must be non-negative |
| Default-layout `defstruct` without cleanup | constructor with every field recursively initialized |
| `defenum` without cleanup | first declared variant, with payload fields recursively initialized |
| `(Box T)` | `box` containing recursively initialized `T` |

Unsupported or ambiguous cases are rejected rather than producing invalid
values. Current rejected cases include function/closure values, references,
`never`, `Expr`/`ExprList`, `(:repr c)` structs, cleanup-owning structs/enums,
empty enums, negative fixed-array lengths, unsupported dynamic-array element
types, and recursive aggregate layouts that fail finite-layout analysis.

Cleanup-owning aggregates are intentionally not initialized by `init` yet:
constructing one would also commit to cleanup execution and failure behavior.
They require explicit constructors until a cleanup-aware default policy is
specified.

```lisp test=ignore name=init-expression-examples reason="illustrates source surface"
(defstruct Point (x i64) (y i64))
(defenum MaybeI64 (None) (Some i64))

(define zero : i64 (init))

(define (main) : i64
  (let
    [p : Point (init)]                 ; (Point 0 0)
    [m : MaybeI64 (init : MaybeI64)]   ; first variant, None
    [xs : (Array i64) (make-array i64 4)]
    (+ zero (+ (struct-get p x) (array-ref xs 0)))))
```

### 5.13 `(match scrutinee [pattern expr] ...)` — pattern matching

- Enum scrutinees support variant patterns such as `Red`, `Color.Red`,
  `(Some value)`, and `(Option.Some value)`.
- Borrowed enum scrutinees written as `(& place)` or `(& lifetime place)` use
  the same variant, wildcard, literal payload, and nested variant pattern forms,
  but inspect the enum without moving the owner. Payload bindings are immutable
  references tied to the borrowed scrutinee lifetime; `String` payloads bind as
  borrowed `str` references.
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
- Lambda literals can return the same value categories as named function
  returns, including `String`, enums, structs, dynamic arrays, tuples, and
  fixed arrays.
- `set!` to captured names is rejected by design (#2552). A lambda may assign
  its own parameters and locals, including a local that shadows an outer name,
  but it may not assign a lexical binding captured from an enclosing scope.
  Captures are by-value snapshots, so implicit rebinding would either mutate a
  hidden environment copy or require capture-by-reference semantics that the
  function type does not expose.
- Captured-name assignment is distinct from mutation through explicit storage
  reached by a captured value. For example, `array-set!` on a captured dynamic
  array handle is legal when the receiver is otherwise mutable; future `Box` or
  mutable-reference APIs define their own explicit storage mutation rules.
- A fixed array of aggregate elements, and a fixed array reached through an
  aggregate field, are rejected: array elements live inline (not as
  pointer-sized handles), so their per-element deep-copy is not yet wired
  (tracked under #571/#435).
- Immutable reference captures are specified in section 3.10.2 and implemented
  for non-escaping closures (#808/#2280); escaping closures still reject
  reference-typed captures.

```lisp test=ignore name=lambda-lift-immediate reason="integration tests cover executable lambda lifting"
((lambda ([x : i64]) : i64 (+ x 1)) 41)
```

### 5.15 SPMD `foreach`

This section defines the SPMD source surface. The current compiler parses and
type-checks `foreach`, lowers it to scalar reference loops, and has AVX2 and
AVX-512 backend paths for a first contiguous map/zip subset. `spmd-reduce` is
also implemented: scalar lowering covers the supported operator/type surface
below, and SIMD backend modes vectorize eligible contiguous array folds.
`spmd-scan` is implemented as scalar reference lowering for range-wide
inclusive scans. Public lane identity forms are implemented for `foreach`
bodies and `spmd-reduce` value expressions. Masked varying `if` is implemented
for scalar reference lowering and the current AVX-512 subset described below;
AVX2 emits an explicit staged diagnostic instead of silently scalarizing masked
branches.

SPMD is data parallelism inside one task. It does not create independently
scheduled OS threads, does not transfer ownership between thread-local arenas,
and is separate from the safe task-threading APIs specified in section 6.5.

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
- Programs that do not evaluate public lane identity forms must produce the
  same observable result as an ordinary scalar loop over the same range. SIMD
  lowering may group iterations into lanes, but those programs must not depend
  on lane width or on an ordering between distinct logical iterations.
- Programs that evaluate `(program-index)` or `(program-count)` explicitly
  observe the selected backend gang shape. Those results are allowed to differ
  by backend mode as described under lane identity below.
- Existing dynamic-array bounds checks still apply. If a `foreach` indexes past
  an array's length, the program traps the same way `array-ref`/`array-set!`
  traps today.

Initial dynamic-array use cases:

- Contiguous map and zip-style kernels over dynamic arrays.
- Reads through `array-ref` and writes through `array-set!`.
- Reads through `array-ref` may use any SPMD-safe varying `i64` index
  expression, including gather-only reads through an index array such as
  `xs[ix[i]]`. The scalar/reference lowering executes those reads with the
  ordinary dynamic-array bounds checks for the logical iteration that performs
  the read. Explicit SIMD backend modes may reject non-contiguous gather shapes
  with a targeted diagnostic until vector gather lowering is implemented.
- Non-atomic `array-set!` destination indexes must be the loop index or a
  simple uniform offset from it, such as `i` or `(+ base i)`. Scatter writes
  through arbitrary varying indexes are deferred; the only overlap-tolerant
  scatter write surface is the explicit atomic integer helper API described
  below.
- Supported lane element types for the first contiguous map/zip slice are
  `i8`, `u8`, `i16`, `u16`, `i32`, `u32`, `i64`, `u64`, `f32`, and `f64`,
  plus an
  AVX-512-only bool dynamic-array subset for contiguous bool copies and
  bool-valued map results. Bool array storage remains byte-compatible (`0` or
  `1` per element); the SIMD lowering converts at the private boundary between
  byte arrays and internal masks. AVX2 explicitly rejects bool dynamic-array
  lanes rather than silently scalarizing them. `i8`/`u8` support vectorized `+`
  with the same modulo wrapping semantics as scalar integer addition; `*` over
  `i8`/`u8` is rejected in explicit SIMD backend modes until a
  widening/narrowing byte multiply policy is specified and implemented.
  `i16`/`u16`, `i32`/`u32`, and `i64`/`u64` support vectorized `+` and `*`
  with the same modulo wrapping semantics as scalar integer arithmetic.
  `String`, structs, enums, tuples, and arrays as lane elements are deferred.

Uniform and varying rules:

- Values are uniform by default.
- The `foreach` index binding is varying: each logical program instance has its
  own `i`.
- `(program-index)` is varying and `(program-count)` is uniform in SPMD scope.
- Arithmetic and comparisons involving a varying value produce varying values.
- `array-ref` with a varying index produces a varying element value.
- `array-set!` with a varying index or value performs one write per active
  logical program instance.
- There is no public `(varying T)` or mask type in the first source surface.
  Public vector, mask, and `(varying T)` type spellings are reserved and
  rejected; varying information is inferred inside `foreach`, and vector/mask
  values are internal to lowering.
- `let` bindings inside the `foreach` body may be uniform or varying by
  inference. `set!` to a binding declared outside the `foreach` is rejected;
  reductions must use `spmd-reduce`, and other cross-lane updates are deferred.
- Calls with varying arguments are rejected until an SPMD function ABI is
  designed, except for the explicit `stdlib/atomic.tl` integer element helpers.
  The implemented non-atomic slice permits built-in arithmetic/comparison
  operators and array operations over supported lane types.
- `while` conditions must be uniform. Varying `if` is admitted with the
  restrictions below.

Lane identity forms:

- The public source names are the no-argument forms `(program-index)` and
  `(program-count)`. They are deliberately not general variables or first-class
  functions.
- Both forms are valid only in SPMD scope: inside a `foreach` body or inside the
  `value` expression of `spmd-reduce`. They are invalid in ordinary expression
  contexts outside SPMD, in `foreach` start/end expressions, in `spmd-reduce`
  start/end/init expressions, and in type positions.
- Nested public SPMD constructs are still unsupported. If nested SPMD is
  specified later, lane identity forms refer to the innermost SPMD region.
- `(program-index)` has type `i64` and SPMD class varying. It is the zero-based
  lane slot within the current gang, not the logical loop index. Use the
  `foreach`/`spmd-reduce` index binding for the logical iteration value.
- `(program-count)` has type `i64` and SPMD class uniform. It is the current
  backend gang width for the SPMD region.
- Scalar fallback and scalar backend modes always execute one active program
  instance at a time: `(program-index)` is `0` and `(program-count)` is `1`.
- SIMD backend modes group consecutive logical iterations into gangs of
  `(program-count)` lanes. For a gang with logical base index `g`, active lane
  slot `k` executes logical index `(+ g k)` when `(< (+ g k) end)`. Active lanes
  observe `(program-index) = k` and the shared `(program-count)`.
- Inactive tail lanes execute no source expressions and perform no source
  effects. Their lane identity values are not observable.
- `(program-count)` may differ by backend mode, target, and lane element type.
  Programs that evaluate lane identity forms are intentionally
  backend-mode-observable; the compiler is not required to preserve scalar
  equivalent exit status, output, or memory contents for those programs. Safe
  SPMD programs that do not evaluate these forms retain scalar equivalence.
- In `spmd-reduce`, lane identity forms are allowed only in the `value`
  expression. A reduction value that uses them is pure but
  backend-mode-observable, so the reduced result may differ between scalar and
  SIMD backend modes.

```lisp test=check name=spmd-program-index-foreach
(define (write-lane-ids [idxs : (Array i64)]
                        [counts : (Array i64)]
                        [n : i64]) : unit
  (foreach ([i : i64 0 n])
    (begin
      (array-set! idxs i (program-index))
      (array-set! counts i (program-count)))))
```

In scalar backend modes, `write-lane-ids` stores `0` in every `idxs` element and
`1` in every `counts` element. In a SIMD backend mode with gang width `W`, each
full gang stores indexes `0` through `W - 1` and count `W`; a non-divisible tail
stores only the active prefix of those lane indexes.

```lisp test=check name=spmd-program-index-empty-range
(define (empty-lane-ids [out : (Array i64)]) : unit
  (foreach ([i : i64 0 0])
    (array-set! out i (+ (program-index) (program-count)))))
```

```lisp test=check name=spmd-program-index-tail
(define (write-tail-lane-ids [out : (Array i64)]) : unit
  (foreach ([i : i64 0 13])
    (array-set! out i (+ (* (program-count) 100) (program-index)))))
```

```lisp test=check name=spmd-program-index-reduce
(define (sum-lane-slots [n : i64]) : i64
  (spmd-reduce sum ([i : i64 0 n]) 0 (program-index)))
```

Tail behavior:

- The language-level range has exactly `max(end - start, 0)` logical
  iterations.
- Scalar fallback lowering executes those iterations one at a time.
- SIMD lowering must use an internal active-lane mask for tails so lengths `0`,
  less than the lane width, exactly one lane width, and not divisible by the
  lane width all produce the same observable result.
- Inactive tail lanes must not perform bounds checks, loads, stores, calls, or
  other side effects.

Masked varying `if` (v2):

- V2 includes varying `if` before gather/scatter, public lane-index builtins,
  public vector types, or public mask types. Lane identity is not required to
  write masked branches, and masks remain an internal lowering concept.
- An `if` condition inside `foreach` may be varying when it has type `bool`.
  If the condition is varying, the `if` creates two masked regions: the then
  region is active only for lanes where the parent active mask and the
  condition are both true, and the else region is active only for lanes where
  the parent active mask is true and the condition is false.
- Nested varying `if` composes masks by intersection with the enclosing active
  mask. Exiting a branch restores the parent mask.
- Tail masks are part of the parent active mask. Inactive tail lanes must not
  evaluate branch contents, perform bounds checks, load, store, call, trap, or
  otherwise affect program state.
- Scalar fallback is the reference semantics: execute the `foreach` range in
  increasing `i`, evaluate the condition for that logical iteration, and
  evaluate exactly the selected branch. SIMD lowering must produce the same
  observable result as this scalar fallback for every safe program.
- Both branches must have the same type. A varying `if` expression may produce
  `unit` or a supported lane value (`i8`, `u8`, `i16`, `u16`, `i32`, `u32`,
  `i64`, `u64`, `f32`, `f64`, or `bool`).
  Aggregate, string, function, array, and public vector/mask results remain
  deferred.
- Branch bodies may use local `let`, `begin`, nested varying `if`, supported
  arithmetic/comparison/boolean operators, and contiguous `array-ref` /
  `array-set!` over supported lane element types. Array indexes must still be
  the `foreach` index or a simple uniform offset from it.
- `array-set!` in a masked branch writes only active lanes. `array-ref` in a
  masked branch reads and checks bounds only for active lanes.
- Side effects other than supported contiguous `array-set!` and explicit
  `stdlib/atomic.tl` integer element operations are rejected in masked branches.
  This includes `set!` to bindings declared outside the `foreach`, `print*`,
  file/process I/O, `panic`/`error`, allocation whose result escapes the branch,
  nested `foreach`, nested `spmd-reduce`, and user-defined calls with varying
  arguments or varying returns.
- Varying `match` is not part of this slice. `match` on a varying scrutinee is
  rejected; a `match` whose scrutinee is uniform follows ordinary scalar
  control-flow rules.
- Varying `while`, early exits, `return` from inside `foreach`, `break`,
  `continue`, public mask values, gather reads and scatter writes through index
  arrays inside masked branches, overlapping ordinary writes, general atomics,
  and user-defined SPMD calls remain deferred.
- Diagnostics must reject unsupported constructs in masked branches at
  type-check/lowering time and name the SPMD masked-control-flow restriction.
  Scalar backend modes must not silently accept a broader source surface than
  SIMD backend modes, and SIMD backend modes must not silently scalarize an
  unsupported masked branch.
- Current implementation status: scalar lowering accepts the checked masked-if
  surface as the reference path. AVX-512 supports unit-result masked branches,
  nested branch-mask composition, contiguous predicated array reads/writes over
  the covered lane types, and the i64 value-producing select fixture. AVX2
  emits the staged masked-if diagnostic. Broader value-producing masked-if
  selects for the remaining lane result types are tracked by #3356.

Explicit SPMD atomic scatter:

- `(import "stdlib/atomic.tl")` provides sequentially consistent atomic helpers
  for dynamic-array elements of type `i32` and `i64`:
  `atomic-i32-load`, `atomic-i32-store!`, `atomic-i32-add!`,
  `atomic-i32-fetch-add!`, and the corresponding `i64` helpers.
- The array argument is a normal dynamic array, the index is an `i64`, and add
  or store values use the element type. There is no public memory-order
  parameter; all helpers are sequentially consistent.
- Inside `foreach`, the helper index and value arguments may be varying. This is
  the only safe overlap-tolerant scatter update in the current source surface.
  Ordinary `array-set!` with a varying non-contiguous index remains rejected.
- Atomic helpers synchronize only the exact element location they operate on.
  They do not make surrounding non-atomic data race-free and do not permit
  unsynchronized mutation of other fields or array elements.
- Scalar fallback is the reference order: logical iterations execute
  left-to-right. SIMD backend modes may scalarize atomic scatter bodies. Masked
  branches and inactive tail lanes execute an atomic operation only for active
  logical instances and must not perform bounds checks or memory accesses for
  inactive lanes.
- `spmd-reduce` value expressions remain pure: atomic helper calls are rejected
  there along with other function calls and side effects.

```lisp test=check name=spmd-masked-if-scalar-fallback
(define (clamp-positive [xs : (Array i64)] [out : (Array i64)] [n : i64]) : unit
  (foreach ([i : i64 0 n])
    (if (< (array-ref xs i) 0)
        (array-set! out i 0)
        (array-set! out i (array-ref xs i)))))
```

```lisp test=check name=spmd-masked-if-tail
(define (copy-even-tail [xs : (Array i64)] [out : (Array i64)] [n : i64]) : unit
  (foreach ([i : i64 0 n])
    (if (= (% i 2) 0)
        (array-set! out i (array-ref xs i))
        (array-set! out i 0))))
```

```lisp test=check name=spmd-masked-if-nested
(define (classify [xs : (Array i64)] [out : (Array i64)] [n : i64]) : unit
  (foreach ([i : i64 0 n])
    (let
      [x : i64 (array-ref xs i)]
      (if (< x 0)
          (array-set! out i -1)
          (if (= x 0)
              (array-set! out i 0)
              (array-set! out i 1))))))
```

SPMD reductions and scans:

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

```lisp test=check name=spmd-scan-sum-i64
(define (scan-prefix-sum [xs : (Array i64)] [out : (Array i64)] [n : i64]) : unit
  (spmd-scan
    sum
    ([i : i64 0 n] [prefix : i64 0])
    (array-ref xs i)
    (array-set! out i prefix)))
```

Syntax:

- `(spmd-reduce op ([i : i64 start end]) init value)` evaluates to one scalar
  result.
- `(spmd-scan op ([i : i64 start end] [prefix : T init]) value body)` evaluates
  a range-wide inclusive scan and has type `unit`. `prefix` is visible only in
  `body`.
- `(spmd-broadcast value lane)` evaluates `value` for the selected source lane
  in the current SPMD gang and makes that scalar value available to every
  active lane in the gang.
- `op` is a fixed operator symbol, not an expression. The first supported
  operators are `sum`, `min`, `max`, `all`, and `any`.
- The range clause has the same half-open `[start, end)` meaning as `foreach`.

Evaluation and empty ranges:

- `start`, `end`, and `init` are uniform expressions evaluated once before any
  logical iteration. `init` is the accumulator seed and the empty-range result.
- `value` is evaluated once for each logical `i` in increasing index order in
  the scalar semantics. If `end <= start`, `value` is not evaluated.
- For `spmd-reduce`, the semantic result is the same as a scalar left fold:
  - `sum`: `acc = (+ acc value)`.
  - `min`: `acc = (if (< value acc) value acc)`.
  - `max`: `acc = (if (> value acc) value acc)`.
  - `all`: `acc = (and acc value)`.
  - `any`: `acc = (or acc value)`.
- For `spmd-scan`, the same accumulator update happens before `body` on each
  iteration. The `prefix` binding visible in `body` is the inclusive value
  after combining the current iteration's `value`; `value` and `body` are
  skipped for empty ranges.
- Integer `sum` uses the existing modulo-wrapping integer `+` semantics.
- `f64 sum` uses the same ordered scalar `+` semantics as an explicit loop in
  scalar backend modes. SIMD backend modes may use deterministic horizontal
  lane grouping for eligible contiguous array folds; strict bit-for-bit scalar
  floating-point accumulation order is reserved for future FP policy controls.

Type rules for the first slice:

- `sum` supports `i32`, `i64`, and `f64`.
- `min` and `max` support `i32` and `i64`.
- `all` and `any` support `bool`.
- `init` and `value` must have the same supported type for the chosen `op`, and
  the `spmd-reduce` result type is that same type.
- `spmd-scan` uses the same operators, but the first scan slice supports only
  `i32`/`i64` for `sum`/`min`/`max` and `bool` for `all`/`any`. `f32`/`f64`
  scans are rejected with a diagnostic that notes floating-point scan ordering
  is deferred. The `prefix` binding has the same type as `init` and `value`.
- `f32`, narrow integer widths, unsigned integer widths, `char`, `String`,
  structs, enums, tuples, arrays, function values, public vector types, and
  public mask types are rejected in the first reduction slice.

Backend coverage for reductions:

- Scalar backend modes lower every supported operator/type combination listed
  above. `spmd-scan` currently uses scalar reference lowering in every backend
  mode.
- SIMD backend modes vectorize eligible contiguous array folds. AVX2 supports
  `sum` over `i32`, `i64`, and `f64`, plus `min`/`max` over `i32`; AVX-512
  supports those shapes and also `min`/`max` over `i64`.
- Supported reduction forms outside the current vectorized subset keep scalar
  semantics in the selected backend mode rather than changing source behavior.

Purity and varying rules for the first slice:

- The `value` expression may use the varying index, `(program-index)`,
  `(program-count)`, dynamic-array reads, arithmetic/comparison/boolean
  operators over supported types, `spmd-broadcast`, and local `let` bindings
  whose values satisfy the same rules.
- `value` must not perform writes or other side effects. In particular, `set!`,
  `array-set!`, `print*`, file I/O, `panic`/`error`, nested `foreach`, nested
  `spmd-reduce`, nested `spmd-scan`, and user-defined calls with varying
  arguments are rejected in the first slice.
- `spmd-scan` applies the same purity and index restrictions to `value`.
  `body` must have type `unit` and uses the same first-slice side-effect rules
  as `foreach`; nested public SPMD constructs are rejected.
- Reductions by mutating an outer variable inside `foreach` remain rejected.
  Use `spmd-reduce` so scalar fallback and SIMD lowering have one explicit
  accumulator contract.

Cross-lane operations:

- `spmd-reduce`, `spmd-scan`, and `spmd-broadcast` are the public cross-lane source
  operations in this slice.
- `spmd-broadcast` is valid only inside a `foreach` body or inside the `value`
  expression of `spmd-reduce`, or inside a `spmd-scan` body. It is invalid in
  ordinary expressions, type positions, `foreach` bounds, `spmd-reduce`
  start/end/init expressions, and `spmd-scan` start/end/init/value expressions.
- The first broadcast slice supports `i32`, `u32`, `i64`, `u64`, `f32`, and
  `f64` values. `lane` must be a uniform `i64` source-lane slot. The result
  type is the value type. If `value` is varying, the result is varying; if
  `value` is uniform, the result remains uniform.
- In scalar backend modes the current gang has one active lane: source lane `0`
  returns `value`, and any other source lane traps through the standard
  out-of-bounds abort path.
- In SIMD backend modes the source lane must be active in the current gang.
  Full gangs accept `0 <= lane < gang-width`; tail gangs accept only source
  lanes that are active in that tail. Inactive source lanes trap through the
  standard out-of-bounds abort path. Inactive tail lanes do not evaluate the
  source value or perform memory effects.
- The current SIMD lowering vectorizes direct contiguous array-value
  broadcasts in simple `foreach` map bodies, including AVX2 scalar tail gangs
  and AVX-512 predicated tail gangs. Other supported broadcast expressions use
  scalar reference lowering in scalar backend modes and may be rejected by
  explicit SIMD backend modes until a vector pattern accepts them. Bool
  `spmd-broadcast` remains deferred even though bool dynamic-array lanes are
  supported in the AVX-512 `foreach` subset.
- General shuffles, lane extraction/insertion, gathers/scatters, atomics, task
  parallelism, vectorized scans, floating-point scans, and public vector/mask
  values remain deferred.
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
  `avx512`. The current `avx512` runtime dispatch path requires AVX-512
  Foundation, AVX-512BW, and the OS ZMM/opmask state needed to execute it,
  because the implemented backend mode may emit byte-lane BW instructions.
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
  same observable result as the scalar body for all safe programs that do not
  evaluate lane identity forms. A variant that evaluates `(program-index)` or
  `(program-count)` may expose the selected backend mode by construction;
  libraries should only put such functions behind a dispatch API when that
  observation is intended.
- Feature detection happens on the first call to each logical dispatch function
  and the selected target is cached for the life of the process. An
  implementation may instead resolve at program startup if that has the same
  observable behavior.
- Selection may use the same CPUID/XGETBV capability checks exposed by
  `stdlib/cpu.tl` (`cpu-runs-avx2?`, `cpu-runs-avx512bw?`), but ordinary user
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

Unsupported in the current SPMD implementation:

- Public vector types and public mask types.
- Non-atomic scatter writes, vector lowering for general gather reads, and
  general non-contiguous memory operations beyond scalar gather-only reads.
- Scans, general shuffles, general atomics beyond the explicit integer element
  helpers, and overlapping writes.
- Reduction-by-mutation through `set!` to an outer accumulator.
- Varying `if` until the v2 masked-control-flow implementation lands; varying
  `while`, varying `match`, early exits, `break`, and `continue`.
- Non-inlineable user-defined function calls with varying arguments or varying
  returns. Direct source-known, non-dispatch helper calls may be inlined when
  their varying scalar arguments and result are `i8`, `u8`, `i32`, `i64`,
  `f32`, `f64`, or `bool`, and the helper body uses only the same SPMD-safe
  expression surface as the containing `foreach`/masked branch.
- Struct, enum, tuple, string, function, and nested array lane values.
- Task parallelism, multicore scheduling, and public AVX-specific intrinsics.

Negative examples for later parser/typechecker tests:

```lisp test=ignore name=spmd-reject-varying-while reason="varying while remains deferred after masked varying if"
(define (clear-prefix [xs : (Array i64)] [out : (Array i64)] [n : i64]) : unit
  (foreach ([i : i64 0 n])
    (while (< (array-ref xs i) 0)
      (array-set! out i 0))))
```

```lisp test=ignore name=spmd-reject-non-atomic-scatter reason="scatter writes remain deferred after masked varying if"
(define (permute [xs : (Array i64)]
                 [index : (Array i64)]
                 [out : (Array i64)]
                 [n : i64]) : unit
  (foreach ([i : i64 0 n])
    (let
      [j : i64 (array-ref index i)]
      (array-set! out j (array-ref xs j)))))
```

```lisp test=ignore name=spmd-reject-mutation-reduction reason="covered by tests/safety/spmd_outer_mutation_reject.tl"
(define (sum-array [xs : (Array i64)] [n : i64]) : i64
  (let
    [sum : i64 0]
    (begin
      (foreach ([i : i64 0 n])
        (set! sum (+ sum (array-ref xs i))))
      sum)))
```

```lisp test=ignore name=spmd-reject-f64-min reason="covered by tests/safety/spmd_reduce_f64_min_reject.tl"
(define (min-f64 [xs : (Array f64)] [n : i64] [seed : f64]) : f64
  (spmd-reduce min ([i : i64 0 n]) seed (array-ref xs i)))
```

```lisp test=ignore name=spmd-reject-shuffle reason="rejected by the parser; the spec example harness only asserts positive check/compile/run"
(define (bad-cross-lane [xs : (Array i64)] [n : i64]) : i64
  (spmd-reduce shuffle ([i : i64 0 n]) 0 (array-ref xs i)))
```

```lisp test=ignore name=spmd-reject-indirect-varying-call reason="covered by tests/safety/spmd_varying_call_reject.tl"
(define (inc [x : i64]) : i64 (+ x 1))

(define (map-inc [xs : (Array i64)] [out : (Array i64)] [n : i64]) : unit
  (let
    [f : (-> i64 i64) inc]
    (foreach ([i : i64 0 n])
      (array-set! out i (f (array-ref xs i))))))
```

```lisp test=ignore name=spmd-reject-program-index-outside-scope reason="covered by tests/safety/spmd_program_index_outside_reject.tl"
(define (bad-lane-id) : i64
  (program-index))
```

---

### 5.16 `(with-arena ident body ...)` — scoped region

Introduces a temporary allocation region named `ident` whose lifetime is
the lexical scope of the form's body. The body is a non-empty expression
sequence; the last expression is the result. Subregions are expressed by
nesting `with-arena` forms.

```lisp test=check name=with-arena-basic
(import "stdlib/string.tl")

(define (main) : i64
  (with-arena r
    (let
      [s : String (int->string 42)]
      (string-length s))))
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

**Target support:** Linux and Windows runtime helpers implement
`tl_region_mark` / `tl_region_reset`, so `with-arena` reclaims scoped
allocations on both native targets covered by integration tests. Future native
targets must either provide equivalent helpers before enabling `with-arena`
execution or document a target-specific limitation.

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
tuples, fixed arrays, dynamic arrays, boxes, and named aggregates are cloned
recursively when their elements or fields are clone-supported. Unsupported
result shapes such as function values are rejected. Typechecking returns the
body result type with source-region tags stripped, matching the clone semantics
of moving the result back to the enclosing arena.

**One-shot scratch escape:** `(with-scratch body ...)` is the explicit one-shot
variant of `with-escape`. It creates a fresh first-class scratch arena,
evaluates the non-empty body sequence with that arena active, switches back to
the enclosing active arena, clones the body result when the type requires it,
destroys the scratch arena head, restores the enclosing active arena, and
returns the cloned result. The result surface and source-region stripping match
`with-escape`: copyable values are returned as-is, `String` values are copied,
cloneable tuple, array, box, and named aggregate results are deep-cloned when
their elements or fields are clone-supported, and unsupported result shapes such
as function values are rejected.
`with-arena` continues to reject region-tagged escapes; clone-out is explicit
through `with-escape` for reusable first-class scratch arenas and
`with-scratch` for one-shot scratch work.

**First-class arena target:** `(in-arena arena-expr body ...)` is the safe
dynamic allocation-target form for first-class arena handles. `arena-expr` must
typecheck as `i64`. The body is a non-empty expression sequence evaluated with
that arena as the active allocation target; the previous active arena is restored
on normal exit and function-local early exit. The form does not mark, rewind,
destroy, or clone. Its result type is the body result type unchanged, so owned
values allocated in the target arena remain owned by that arena.

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

The stdlib-owned `TypeInfo` surface in section 3.7.2.2 is the value-level form
of this same reflection contract. Until that surface lands, the indexed
primitives below remain the implemented selfhost v1 API. After it lands,
primitive results and `TypeInfo` values must agree on kind strings, nominal
identity, key generation, and diagnostics.

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

#### 5.17.1 TypeLisp comptime image (`.tlci`) v1

A TypeLisp comptime image (`tlci`) is the package compile-time interface. Every
package eventually emits one: metadata-only images carry signature/layout
metadata, and packages with macros additionally carry compiled comptime code.
The runtime archive (`lib<name>.a` / `<name>.lib`) remains separate. This
section specifies the v1 container and metadata schema implemented by
`src/tlci_core.tl`. Package builds emit metadata-only images; code-bearing image
emission and loading are staged separately.

The container is a custom little-endian binary format shared by Linux and
Windows. It is not ELF or COFF. The first 160 bytes are a fixed header:

| Offset | Size | Field |
| ---: | ---: | --- |
| 0 | 8 | Magic bytes `54 4c 43 49 0d 0a 1a 0a` (`TLCI\r\n\x1a\n`) |
| 8 | 8 | Format version, currently `1` |
| 16 | 8 | Host architecture enum, `1 = x86_64` |
| 24 | 8 | Callback ABI version, currently `1` |
| 32 | 8 | Compiler build hash byte offset |
| 40 | 8 | Compiler build hash byte length |
| 48 | 8 | Content hash |
| 56 | 8 | Metadata section byte offset |
| 64 | 8 | Metadata section byte length |
| 72 | 8 | Rodata section byte offset, or `0` when empty |
| 80 | 8 | Rodata section byte length |
| 88 | 8 | Code section byte offset, or `0` when empty |
| 96 | 8 | Code section byte length |
| 104 | 8 | Load-base fixup table byte offset, or `0` when empty |
| 112 | 8 | Load-base fixup record count |
| 120 | 8 | Entry table byte offset, or `0` when empty |
| 128 | 8 | Entry table record count |
| 136 | 8 | Symbol-name table byte offset, or `0` when empty |
| 144 | 8 | Symbol-name table record count |
| 152 | 8 | Total file size in bytes |

All integer fields are unsigned logical values encoded in little-endian 64-bit
slots; v1 helpers reject values that do not fit the implemented `i64` range.
The metadata section starts on an 8-byte boundary. Rodata and code sections are
page-aligned at 4096-byte offsets so a future loader can map them directly.
Fixup, entry, and symbol tables are 8-byte aligned. Empty sections must use
offset `0` and count/length `0`.

The content hash is a deterministic integrity check over the full file with the
8-byte hash field treated as zero. V1 uses the std-only rolling hash implemented
in `tlci_core.tl` (`hash = (hash * 131 + byte) mod 2147483647`, seed `1`).
This is an integrity/versioning guard, not a cryptographic authenticity
mechanism. A loader must reject hash mismatches before trusting offsets or
metadata.

The load-base fixup table contains `count` records of one little-endian u64
offset each. The table is valid but empty when generated comptime code is fully
RIP-relative. The entry table contains 24-byte records:

| Offset | Size | Field |
| ---: | ---: | --- |
| 0 | 8 | Name byte offset in the symbol-name table payload |
| 8 | 8 | Name byte length |
| 16 | 8 | Code section byte offset for the entry point |

The symbol-name table contains 40-byte records used only for diagnostics and
symbolization, never for linking:

| Offset | Size | Field |
| ---: | ---: | --- |
| 0 | 8 | Name byte offset in the symbol-name table payload |
| 8 | 8 | Name byte length |
| 16 | 8 | Section kind (`1 = rodata`, `2 = code`) |
| 24 | 8 | Section byte offset |
| 32 | 8 | Byte length |

The v1 helper module treats table bytes as opaque after count/size validation;
the loader slice that consumes entries will validate referenced name ranges and
code offsets.

##### 5.17.1.1 Host ABI handshake

The tlci header field at byte offset 24 is the host callback ABI version. In v1
it is exactly the host ABI version used by the dormant native image handshake
below; both values are `1`. A loader must reject a code-bearing image whose tlci
header callback ABI version does not match the host callback table version it
will pass to the image.

A code-bearing image exports one native entry point named `tlci_image_entry`.
The host calls it with the target platform's ordinary integer calling
convention:

| Position | Type | Meaning |
| ---: | --- | --- |
| 0 | pointer-sized integer | Address of the read-only host callback table |
| 1 | pointer-sized integer | Address of a writable image registration record |
| return | `i64` status | `0` on successful registration; nonzero values are reserved diagnostics |

No callback slots are assigned in v1. The callback table begins with a fixed
48-byte header, and any bytes after `byte-size` are outside the record:

| Offset | Size | Field |
| ---: | ---: | --- |
| 0 | 8 | Magic little-endian u64 for ASCII `TLCIHOST` |
| 8 | 8 | Host callback ABI version, currently `1` |
| 16 | 8 | Callback table byte size; must be at least `48` |
| 24 | 8 | Opaque host context pointer, or `0` |
| 32 | 8 | Reserved, must be `0` in v1 |
| 40 | 8 | Reserved, must be `0` in v1 |

The image fills the writable registration record before returning success. The
v1 registration record is also 48 bytes:

| Offset | Size | Field |
| ---: | ---: | --- |
| 0 | 8 | Magic little-endian u64 for ASCII `TLCIIMAG` |
| 8 | 8 | Host callback ABI version used by the image, currently `1` |
| 16 | 8 | Registration record byte size; must be at least `48` |
| 24 | 8 | Opaque image context pointer for later dispatch, or `0` |
| 32 | 8 | Reserved, must be `0` in v1 |
| 40 | 8 | Reserved, must be `0` in v1 |

Compatibility is append-only. Future ABI versions may require larger byte-size
values and assign callback or registration fields after the v1 header, but they
must not reinterpret the v1 offsets above. A v1 loader accepts larger records
when the magic, ABI version, minimum byte size, and reserved-zero fields are
valid, and ignores the tail. The v1 skeleton does not execute callbacks, load
dependent images, enforce macro fuel, or dispatch compiled macros; those are
later loader and stdlib macro-surface slices.

The metadata section is UTF-8/ASCII S-expression text with stable field order:

```lisp test=ignore name=tlci-metadata-schema reason="tlci metadata S-expression, not TypeLisp source"
(typelisp-tlci-metadata
  (version "v1")
  (package (name "pkg-name") (version "0.1.0"))
  (exports
    (value (name "answer") (signature "(-> i64)"))
    (type (name "Point") (layout "size=16 align=8"))
    (macro (name "with-temp") (signature "(Expr)->Expr"))))
```

`version` gates the schema. `package` gives the package identity as it appears
in `typelisp.pkg`. `exports` is sorted deterministically by kind
(`value`, `type`, `macro`) and then by name. Value and macro exports require a
`signature` string; type exports require a `layout` string. The strings are
compiler-owned schema payloads: consumers compare them for equality and use
future schema versions to understand richer structure, but v1 helpers do not
interpret the signature/layout languages. Duplicate `(kind, name)` exports,
unknown fields, unsupported versions, malformed S-expressions, empty required
sections, bad magic/version/arch/ABI/hash, and truncated section ranges are
diagnostics.

Metadata-only tlci files are valid: rodata, code, fixups, entries, and symbols
are all empty. Code-bearing tlci files are valid with synthetic payload bytes
before real PIC code generation lands; the emitted layout and content hash must
round-trip byte-identically.

`typelisp inspect <file.tlci>` parses a tlci image with the same validation
path as loaders and prints a stable human-readable header, section table,
package metadata, and export list. Malformed images surface the tlci parse
diagnostic.

### 5.18 Layout queries (specified, selfhost metadata implemented)

The selfhost FFI layout surface reserves three comptime-only query forms:

```lisp test=ignore name=default-layout-query-syntax reason="layout query lowering is selfhost metadata"
(defstruct Stat
  (size i64)
  (mtime i64))

(define stat-size : i64 (comptime (size-of (type Stat))))
(define stat-align : i64 (comptime (align-of (type Stat))))
(define stat-mtime-offset : i64 (comptime (offset-of (type Stat) mtime)))
```

- `(size-of type-expr)` returns the byte size as `i64`.
- `(align-of type-expr)` returns the ABI alignment as `i64`.
- `(offset-of type-expr field-name)` returns the byte offset of `field-name`
  inside a struct as `i64`; `field-name` is a bare field identifier, not a
  string and not an evaluated expression.

`type-expr` must evaluate at compile time to a type value, usually from
`(type T)` or a comptime type parameter. `offset-of` requires a struct type and
a field that exists on that struct. `size-of` and `align-of` also work for enum
types using the TypeLisp tagged-union layout from section 3.5.3. All three
forms are valid only in compile-time-required contexts such as comptime
parameters, generated declaration evaluation, and explicit `(comptime expr)`
folds. To use a query result at runtime, the program must fold it through normal
comptime evaluation and store the resulting `i64`; the compiler must not expose
type or layout metadata as a runtime value.

Queries reject wrong arity, missing or runtime-only type operands, non-type
operands, non-struct `offset-of` operands, invalid field names, and use outside
a compile-time-required context.

---

### 5.19 `(with ([name init cleanup] ...) body ...)` - scoped resource cleanup

The `(with ...)` form (implemented; #907) provides explicit scoped cleanup of
non-memory resources such as file descriptors, process handles, temporary
files, locks, and mapped files. It is separate from `(with-arena ...)`: `with` calls cleanup
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

```lisp test=ignore name=with-resource-normal reason="illustrative resource-cleanup example; not a standalone program"
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

```lisp test=ignore name=with-resource-lifo reason="illustrative resource-cleanup example; not a standalone program"
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

```lisp test=ignore name=with-resource-nested reason="illustrative resource-cleanup example; not a standalone program"
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

```lisp test=ignore name=with-resource-recoverable-propagation reason="illustrative scoped cleanup with recoverable propagation; not a standalone program"
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

```lisp test=ignore name=with-resource-reject-escape reason="negative example for scoped resource cleanup checks"
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
(extern (first-byte) : (Ptr u8))

(define (main) : i64
  (unsafe
    (cast (ptr-read (first-byte)) : i64)))
```

An unsafe context does not disable normal type checking. It only permits forms
that are rejected in safe code because they can violate memory safety, ABI
contracts, aliasing assumptions, or region lifetime rules. Top-level unsafe
function and extern declarations are supported through the `(unsafe
declaration)` wrapper described in section 4.3.1. "Unsafe by default" modules
are deferred.

Initial unsafe operation set:

| Form | Safe? | Type rule | Notes |
|------|-------|-----------|-------|
| `(ptr-null : (Ptr T))` / `(ptr-null : (MutPtr T))` | Yes | returns the requested raw pointer type | Constructs a typed null pointer. |
| `(ptr-null? p)` | Yes | raw pointer -> `bool` | Does not dereference `p`. |
| `(ptr-read p)` | Unsafe | `(Ptr T)` or `(MutPtr T)` -> `T` | Reads `sizeof(T)` bytes at `p`; alignment, validity, initialization, and lifetime are caller obligations. |
| `(ptr-write! p value)` | Unsafe | `(MutPtr T)` and `T` -> `unit` | Writes `sizeof(T)` bytes; writing through `(Ptr T)` is rejected. |
| `(ptr-offset p n)` | Unsafe | raw pointer and integer -> same raw pointer type | Adds `n * sizeof(T)` bytes. Negative offsets are allowed but unsafe. |
| `(ptr-cast p : (Ptr T))` / `(ptr-cast p : (MutPtr T))` | Unsafe | raw pointer -> requested raw pointer type | Includes const/mutable pointer casts; no implicit `MutPtr` to `Ptr` coercion in v1. |
| `(ptr-addr-of name)` | Unsafe | local/parameter `name : T` -> `(MutPtr T)` | V1 supports local or parameter scalar cells only. The pointer is valid only while that stack slot is live; escaping or storing it is the caller's responsibility. |
| `(ptr->int p)` | Unsafe | raw pointer -> `u64` | Exposes the target address representation. |
| `(int->ptr n : (Ptr T))` / `(int->ptr n : (MutPtr T))` | Unsafe | integer -> requested raw pointer type | Address validity is entirely outside the typechecker. |
| `(atomic-load p)`, `(atomic-store! p v)`, `(atomic-add! p d)`, `(atomic-fetch-add! p d)`, `(atomic-cas! p expected new)` | Unsafe | raw pointer atomics for `T` in `i32`, `i64`, `u32`, or `u64`; update forms require `(MutPtr T)` and matching values | Sequentially consistent x86-64 memory operations. Load returns `T`; store/add return `unit`; fetch-add and CAS return the previous value observed at `p`. |
| `(syscall number arg0 ... arg5)` | Unsafe | integer operands -> `i64` | Issues a raw Linux x86_64 host syscall. The number plus up to six arguments are passed directly to the kernel ABI; argument validity, pointer lifetimes, platform availability, and side effects are caller obligations. |

`stdlib/ffi.tl` provides caller-owned C string marshalling helpers on top of
this raw-pointer surface. `ffi-c-bytes-required-bytes` computes
`bytes-length + 1`, `ffi-c-bytes-interior-nul?` rejects byte slices that cannot
be passed to ordinary NUL-terminated C APIs, and `ffi-c-bytes-copy!` copies into
a caller-provided `(MutPtr u8)` with an explicit capacity before writing the
trailing NUL byte. The helper returns a structured result for success,
interior-NUL input, or too-small buffers; it does not allocate, does not create
implicit `String -> Ptr` or `bytes -> Ptr` coercions, and does not extend the
input slice's lifetime. The `ffi-c-string-*` compatibility wrappers borrow their
`String` input as `(& r bytes)` and delegate to the byte-slice implementation.

Deferred raw pointer operations: address-of globals, fields, array elements, or
temporaries; slice views; volatile/atomic access; provenance tracking; pointer
comparisons beyond `ptr-null?`; pointer-to-function casts; and any
borrow-checked reference surface. Those are follow-ups to the raw pointer/FFI track
(#809/#897/#911/#912) and the safe reference/ownership track (#182).

---

## 6. Built-in functions and runtime

### 6.1 Transitional compiler compatibility builtins

Public I/O, argv, environment, filesystem, panic/error, and CPU capability
helpers are standard-library definitions, not implicit compiler builtins. Import
`stdlib/io.tl`, `stdlib/env.tl`, `stdlib/fs.tl`, or `stdlib/cpu.tl` to use those
surfaces. The backend may still emit private runtime symbols used by those
stdlib extern wrappers. In particular, `print`, `print-bool`, `print-newline`,
`print-string`, `print-error`, `panic`, and `error` are ordinary definitions in
`stdlib/io.tl`; unimported uses of those names are unbound source names.

Low-level CPU instruction forms such as `cpuid-eax`, `cpuid-ebx`, `cpuid-ecx`,
`cpuid-edx`, and `xgetbv` remain compiler intrinsics. Public CPU capability
checks should use `stdlib/cpu.tl`.

The table below records the remaining transitional string/array compatibility
surface that is still recognized by the compiler while the stdlib migration in
#3079 continues.

| Compatibility builtin | Signature | Description |
|-----------------------|-----------|-------------|
| `length` | `(Array t) → i64` | Get dynamic array length |
| `length` | `String → i64` | Get string byte length |
| `array-length` | `(Array t) → i64` | Get dynamic array length |
| `make-array` | `type i64 → (Array type)` | Allocate a dynamic array and initialize every live element under ZII; invalid lengths trap |
| `array-ref` | `(Array t) i64 → t` | Read dynamic or fixed array element, including through an immutable or mutable reference receiver (bounds checked) |
| `array-set!` | `(Array t) i64 t → unit` | Write dynamic or fixed array element through an owned array or mutable reference receiver (bounds checked) |
| `array-push!` | `(Array t) t → unit` | Append to a dynamic array through an owned array or mutable reference receiver |
| `string-ref` | `String i64 → char` | Read byte from string (bounds checked) |
| `string-length` | `String → i64` | Get string byte length |
| `string-eq` | `String String → bool` | Byte-wise string comparison |
| `string=?` | `String String → bool` | Alias for `string-eq` |
| `substring` | `String i64 i64 → String` | Fresh string of `len` bytes starting at byte offset `start` (a `[start, start+len)` slice). Bounds checked. |
| `string-slice` | `String i64 i64 → String` | Alias for `substring` |
| `substring-view` | `(& r str) i64 i64 → (& r str)` | Borrowed string view of `len` bytes starting at byte offset `start`. Bounds checked; does not copy bytes. |
| `string-slice-view` | `(& r str) i64 i64 → (& r str)` | Alias for `substring-view` |
| `string->int` | `String → i64` | Parse decimal integer from string |
| `int->string` | `i64 → String` | Format integer as decimal string |

User-facing fixed-arity string concatenation is the stdlib macro
`stdlib/str_cat.tl`'s `(str-cat ...)`; incremental builders should use
`stdlib/text_buf.tl`. `str-cat` uses direct one-allocation helpers for two to
five operands and expands longer calls to an internal `string-concat-all` call
over a packed `(Array String)`, so long calls no longer allocate chunk
intermediates. `string-append`, `string-concat`, and the fixed-arity
`string-concat3`/`string-concat4`/`string-concat5` helpers remain accepted as
deprecated low-level compatibility plumbing for legacy code, but they are not
the documented public concatenation surface. The staged lint rule is enabled
explicitly with `typelisp lint --deprecated-string-concat` until the remaining
in-tree migrations are complete.

- `make-array` checks the runtime length before allocation. Negative lengths and
  `length * sizeof(type)` overflow call the same `tl_oob_abort` runtime trap
  used by bounds checks.
- For positive lengths, `make-array` initializes each element according to the
  `init` eligibility rules in section 5.12.1. Scalar zero-like elements may use
  a bulk zero helper, and share-safe 8-byte defaults may use a fill helper, but
  those helpers are implementation details; safe code observes initialized
  source values.
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
- `ByteBuf` and `bytes` are specified in section 3.11 as stdlib/language
  surface, not as implicit compiler builtins. There is no implicit conversion
  from text, arrays, or raw pointers to byte buffers; binary APIs must use
  explicit borrow/copy helpers.

### 6.2 Runtime functions (emitted by the backend)

The compiler emits helper routines into the generated assembly when needed.
They are not implemented by a separate C runtime.

Stdlib APIs that are thin wrappers over platform facilities are not backend
runtime helpers. `stdlib/io.tl`, `stdlib/env.tl`, `stdlib/fs.tl`, and
`stdlib/cpu.tl` bind platform symbols directly with `extern` and choose
target-specific implementations with `cfg`. Low-level language forms expose
entry `argc`/`argv`/`envp`, raw string/array storage, and CPU instructions when
stdlib code needs capabilities that are not expressible as ordinary FFI calls.
`stdlib/msvc.tl` owns Windows MSVC/link.exe and SDK discovery through stdlib
environment, filesystem, and process helpers rather than backend runtime
symbols. The backend-owned core runtime subset is limited to the allocator and
arena control symbols: `tl_alloc`, `tl_region_mark`, `tl_region_reset`,
`tl_arena_make`, `tl_arena_make_atomic`, `tl_arena_current`, `tl_arena_set`,
`tl_arena_destroy`, and `tl_arena_poison_enable`.

| Symbol | Purpose |
|--------|---------|
| `tl_alloc` | Allocate bump-allocator memory |
| `tl_arena_current` | Return the current arena header |
| `tl_arena_set` | Install a current arena header |
| `tl_arena_make` | Allocate an independent arena chain |
| `tl_arena_make_atomic` | Allocate an independent atomic arena chain |
| `tl_arena_destroy` | Release an independent arena chain |
| `tl_region_mark` | Return the current allocator region mark, or `0` before allocation |
| `tl_region_reset` | Restore a region mark; mark `0` clears all current arenas |
| `tl_string_concat` | String concatenation |
| `tl_substring` | String slicing |
| `tl_str_view` | Borrowed string slice view metadata construction |
| `tl_int_to_string` | Format integer |
| `tl_oob_abort` | Bounds-check trap |
| `tl_div_abort` | Integer division/remainder trap |
| `tl_shift_abort` | Shift-count trap |

Allocator/arena page acquisition and release are explicitly backend-owned core
runtime (#2314): Linux emits `mmap`/`munmap` in `tl_alloc`, `tl_arena_make`,
`tl_arena_make_atomic`, `tl_arena_destroy`, and `tl_region_reset(0)` (plus the
current `tl_arena_make` fatal-exit syscall), while Windows emits kernel32
`VirtualAlloc`/`VirtualFree` for the corresponding page paths. Nonzero
`tl_region_reset(mark)` restores the bump cursor and retires overflow chunks on
the arena root so stale scratch pointers cannot observe later unrelated
allocations at reused virtual addresses; the retained chunks are released by
full reset or arena destroy. `tl_region_mark`, `tl_arena_current`,
`tl_arena_set`, and `tl_arena_poison_enable` only read or update backend runtime
state. The current-arena state is thread-local: Linux
uses local-exec TLS and the freestanding entry installs an FS base before global
initializers run; Windows x64 stores the current arena in the TEB
arbitrary-user slot (`GS:0x28`). Raw thread spawn initializes a fresh zero
current-arena slot before calling user code, so the worker's first allocation
creates an independent default arena chain. The string and trap symbols in the
table are stdlib/runtime-prelude exports or migration targets, not backend-owned
core helpers.

`tl_arena_make` creates an ordinary first-class arena whose bump cursor is
single-threaded. `tl_arena_make_atomic` creates an arena handle with the same
source-level handle ABI as ordinary arenas, but marks the arena header as an
atomic owner so `tl_alloc` can use the concurrent allocation path when that
arena is current. Neither helper installs the new arena; callers select an
allocation target through `tl_arena_set` or the source wrappers described in
section 7.3.

For an atomic current arena, the allocation fast path reserves space from the
current chunk with one atomic bump operation. If the reservation does not fit in
the current chunk, chunk exhaustion is serialized: one thread links or acquires
the next chunk, publishes it as the arena's current chunk, and contending
threads retry against the published state. Ordinary arenas keep the existing
non-atomic bump fast path. The retained-chunk/reset correctness fix in #2441 is
a prerequisite for trusting the atomic slow path, because a reset must not make
overflow chunks reusable while stale arena-owned values can still exist.

Atomic allocation serializes allocation only. It does not make array writes,
struct/enum mutation, raw pointer access, or user data protected from data races;
those remain governed by the borrow, mutation, unsafe, and thread-safety rules.

### 6.3 Builtin operator aliases

| Alias | Expands to |
|-------|------------|
| `string=?` | `string-eq` |
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
handle carries an id into a stdlib-managed table that stores the host
descriptor, open mode, and open/closed state; these fields are not part of the
public contract and may change. A handle is an aggregate value and follows the
move-only source contract in section 4.6.2 (the move checker is implemented;
#805). Source code should treat each successful `FileHandle` as a single owner
that is closed exactly once. There is no implicit close; scoped `(with ...)`
cleanup (section 5.19) is the supported pattern.

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
error for stale handles that reach the stdlib implementation; they never panic and never touch
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
text/binary distinction in the implemented compatibility surface. This remains
source-compatible. New binary IO helpers should use the `ByteBuf` / `bytes`
family specified in section 3.11 rather than mutable `str`: non-consuming writes
take `(& r bytes)`, allocated reads return active-arena `ByteBuf`, and
caller-provided reads fill `ByteBuf` or `(&mut r bytes)` under the exclusive
borrow rules. Returned compatibility chunk strings allocate in the active arena,
the same as `read-file` and `StdinRead`.

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

### 6.5 Task threading and structural thread safety (v1 design)

This section specifies the safe task-threading model for the future stdlib
surface tracked by #2592. The current `stdlib/thread.tl` remains a raw substrate:
`thread-spawn` takes a `(-> i64 i64)` entry and one `i64` context, `thread-join`
returns an `i64`, and callers that smuggle addresses through those integers are
responsible for their own synchronization in unsafe code. The safe surface is
closure-based and checker-visible; it does not add `Send`/`Sync` traits or any
source-level trait system.

The core rule is structural: a value may cross a task-thread boundary only when
its type shape is accepted by the transfer/share classifier and every reachable
owned allocation is owned by an arena whose lifetime spans all participating
threads. Arena lifetime only proves that storage remains live. It does not
prove mutation race freedom, uniqueness, initialization, pointer provenance, or
foreign ABI invariants.

Task threading is distinct from SPMD `foreach` (section 5.15). `foreach` is a
single-task data-parallel lowering whose race freedom is checked by the SPMD
uniform/varying and reduction rules. The APIs below create independently
scheduled tasks/threads with their own default arenas and with explicit
ownership crossing points.

#### Arena-owner crossing rules

The structural classifier consults both the source type and the owner of every
reachable heap allocation:

| Owner class | Safe cross-thread role |
|-------------|------------------------|
| Static data and program-lifetime owner | May be transferred or shared when the type classifier accepts the value. This includes read-only string literal storage and values explicitly allocated in a program-lifetime allocation home. |
| Per-thread default arena | Does not cross thread boundaries. A worker may freely use values allocated in its own default arena, but it may not return, send, or share those values with another thread unless an accepted API first clones or moves them into a spanning owner. |
| Lexical `with-arena` scoped region | Does not cross task-thread boundaries in v1. Its reset is tied to the creating lexical scope, and the existing region checker only proves same-thread escape safety. A later scoped-task API may add a join-before-reset proof, but ordinary safe spawn/channel/mutex APIs reject scoped-region values. |
| Ordinary first-class arena from `arena-make` | Does not by itself prove cross-thread lifetime or concurrent allocation safety. Safe code may use it for single-thread scratch workflows such as `with-escape`, but it is not a spanning owner for task-thread transfer/share. |
| Atomic first-class arena from `arena-make-atomic` | May be a spanning owner when the arena handle outlives every thread that can hold its values. Multiple threads may allocate into it through the section 7.3 allocation-target rules. Reset or destroy still requires a proof that all users have joined or otherwise released the values. |
| Raw pointers, raw integer addresses, and foreign handles | Do not establish ownership or lifetime. Safe code does not become transferable/shareable by carrying an address in `i64`, `Ptr`, `MutPtr`, or an opaque host handle. Crossing those values is allowed only by an explicitly unsafe API or by a safe wrapper with its own synchronization contract. |

The current process-lifetime implementation detail of the allocator is not a
permission to transfer thread-default allocations. The v1 source model is the
post-#2591 model: every thread has its own default arena, and only program/static
or atomic spanning owners are accepted for general cross-thread aggregate
storage.

#### Structural transferability

Transferability is one-way ownership movement from one thread to another. After
a safe send, spawn capture, or return transfer, the source thread may not use the
moved value except through the ordinary post-move rules. Copyable scalar values
may be copied instead of moved.

A value is transferable when all of the following hold:

- Its source type is structurally transferable.
- Every reachable owned allocation has a spanning owner from the table above.
- The operation can prove exclusive ownership of mutable reachable storage, or
  the reachable storage is immutable.
- No reachable value is a guard, reference, raw-pointer ownership claim, or
  other non-transferable synchronization token.

The baseline structural rules are:

- `unit`, `bool`, numeric scalars, `char`, and function symbols with no captured
  state are transferable by copy.
- Tuples, fixed arrays, structs, and enum values are transferable when every
  field, element, or payload is transferable and any reachable allocation owner
  spans the participating threads.
- `String` is transferable when its bytes are static/program-owned or owned by a
  spanning atomic arena. It is immutable, so the transfer does not create a
  mutation race.
- Dynamic arrays and `(Box T)` values are transferable only by exclusive move,
  only when their element/referent type is transferable, and only when their
  backing storage owner spans the participating threads.
- Closure values are transferable only when their environment record and every
  captured value are transferable. Captured references, scoped-region handles,
  ordinary-arena values, raw-pointer-derived ownership claims, mutable aliases,
  and guard values are rejected with targeted diagnostics.
- Raw pointers, mutable raw pointers, integer addresses, and foreign handles are
  not transferable in safe code unless a specific safe wrapper gives them a
  synchronization and lifetime contract.

#### Structural shareability

Shareability permits more than one thread to hold access to the same value at
the same time. A value is shareable only when all reachable storage has a
spanning owner and the source type exposes no unsynchronized safe mutation path,
or when all mutation is mediated by an accepted synchronization primitive.

Immutable data in a spanning owner is shareable: examples include copyable
scalars, immutable strings, and aggregates that recursively contain only
shareable immutable fields. Mutable data is not made shareable by living in an
atomic arena. Atomic arena allocation protects allocator metadata only; it does
not protect array elements, struct fields, enum payloads, raw pointer targets, or
foreign resources from data races.

Ordinary `(& r T)` and `(&mut r T)` reference values do not cross threads in v1,
even when their referent is program-owned. The current lifetime syntax has no
way to quantify a reference over a worker's dynamic lifetime, and mutable
references require single-thread exclusive access. Cross-thread read sharing is
expressed by copying or moving an owned immutable handle, not by sending a
borrowed reference. Cross-thread mutation is expressed through mutex guards,
channels, explicit safe atomics, or unsafe code.

#### Safe spawn and typed join

The accepted safe spawn shape is closure based:

- `thread/spawn` accepts a closure whose captured environment is structurally
  transferable. The closure itself is moved into the worker. The checker rejects
  captured stack references, borrowed `str` views, `(& r T)` / `(&mut r T)`
  values, scoped-region values, ordinary first-class arena values, raw
  pointer-derived ownership claims, mutable aliases that are still live in the
  parent, and lock/channel guard values.
- A worker starts with its own per-thread default arena. It may allocate
  temporary data there, but aggregate results that leave the worker through join
  must already live in a spanning owner or be explicitly cloned/moved into one
  by an accepted API.
- `thread/join` consumes the thread handle, waits for completion, and returns a
  result typed by the closure return type. Double join and use-after-join are
  ordinary use-after-move errors.
- Joining a worker is also the proof that the worker no longer allocates into,
  mutates through, or holds values from any atomic arena whose lifetime depended
  on that worker. Resetting or destroying such an arena before all users have
  joined remains unsafe or rejected.

Typed join does not launder ownership. Returning a `String`, dynamic array,
`Box`, tuple, struct, or enum from a worker is accepted only when the returned
value's reachable storage is already in a spanning owner or when the join API
performs an explicit, specified clone/move into a caller-selected spanning owner.
Returning a value allocated in the worker's default arena is rejected.

#### Mutexes and guards

The safe mutex surface protects shared mutable state through a lexical guard.
Exact type names are owned by #2592, but the required source contract is:

- A mutex shared across threads must itself be owned by a spanning owner.
- Locking a mutex yields a guard tied to both the mutex and the lexical cleanup
  scope, normally through `(with ([g (mutex/lock m) mutex/unlock]) ...)`.
- The guard grants the only safe mutable access path to the protected value for
  the guard scope. Ordinary mutable-reference exclusivity rules apply while the
  guard is live.
- Guard values are move-only and non-transferable. They cannot be returned,
  stored in longer-lived aggregates, captured by spawned closures, sent through
  channels, or held past the cleanup scope.
- Unlocking releases the guard's exclusive access. It does not change the arena
  owner of the protected value and does not make non-spanning data transferable.

#### Channels

Channels transfer ownership between threads. The channel object and any queued
storage used by the channel must be owned by a spanning owner or by runtime
state whose safe wrapper proves lifetime and synchronization.

`channel/send` consumes its message. The sender may not use the moved value after
a successful send, and a buffered channel owns queued messages until a receiver
takes them. `channel/recv` produces an owned value for the receiving thread. A
message type is accepted only when it is structurally transferable and its
reachable storage either already has a spanning owner or is cloned/moved into
the channel's spanning storage by a specified API. Sending references, guard
values, raw-pointer ownership claims, scoped-region values, or ordinary
thread-default aggregate values is rejected.

Closing, cancellation, and blocking policy are stdlib API details, but they must
preserve the same ownership rule: no safe channel operation may create two
unsynchronized mutable owners for the same reachable storage or let a message
outlive its arena owner.

#### Atomics

Safe atomic operations exist only where the language or stdlib explicitly
accepts an atomic type/helper with a specified width, alignment, ownership, and
memory-ordering contract. Until such helpers are specified, raw CPU atomics,
volatile-looking raw pointer operations, and FFI atomic intrinsics remain
unsafe-only escape hatches.

The minimal v1 policy is conservative: safe atomics are synchronization
operations for the specific atomic location they operate on, not a blanket
permission to share surrounding non-atomic data. Atomic allocation in an atomic
arena is allocator synchronization only. Programs that need shared mutable
ordinary data must use mutex guards, channel ownership transfer, an accepted
atomic helper for that exact field, or `(unsafe ...)`.

`stdlib/atomic.tl` is the first accepted safe atomic helper surface. It is
limited to one indexed dynamic-array element of type `i32` or `i64` and exposes
only load, store, add, and fetch-add operations with sequentially consistent
ordering. It has no public relaxed/acquire/release ordering parameter and does
not protect unrelated non-atomic locations.

---

## 7. Memory model

TypeLisp currently has syntax/type-model support for written reference types
(`(& arena T)` and `(&mut arena T)`) and SPEC-level immutable borrow expression
rules (`(& place)` / `(& arena place)`), including the borrowed `str` source
contract in section 3.11, but the source-level borrow checker is not
implemented yet. There is no implicit destructor, `drop`, `free`, or
garbage-collector model. Section 4.6.2 specifies move-only aggregate handle
ownership for v1 source semantics, but some compatibility paths may still
accept aggregate copies until the selfhost move checker lands. The
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

- Dynamic array element buffers, future `ByteBuf` backing stores, and escaping
  returned aggregates (enums, structs, strings, dynamic-array fat values) are
  heap-allocated.
- Non-escaping aggregate fat/inline storage is usually kept in the current stack frame.
- Allocation goes through `tl_alloc`, a backend-emitted bump allocator.
- There is **no garbage collector** or general `free`.
- Each thread has its own default arena. Default-arena allocations remain live
  until the compiled program exits unless an explicit same-thread region reset
  discards them; thread exit does not reclaim that thread's default arena in v1.

### 7.3 V1 reclamation direction

Issue #320 chose the near-term reclamation policy. The current per-thread
default arena remains process-lifetime by default because it is simple,
deterministic, and correct for one-shot compiled programs. It covers all current
heap allocation kinds within the allocating thread: fresh string storage from
`substring`, `str-cat`/the low-level concat primitives, `read-file`, `arg`, and
`int->string`; dynamic array element buffers and fat values; returned enum and
struct storage; and self-hosted data structures built from those primitives.
Future `ByteBuf` backing storage and closures are expected to allocate in the
same active arena until a more precise model exists.

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

The standard scratch workflows are:

- **Temporary scratch only:** use `(with-arena scratch ...)` for phase-local
  allocation and return only scalars or values allocated outside the scoped
  arena. This is the default safe choice.
- **Clone one result out:** allocate a reusable first-class scratch arena with
  `arena-make`, then wrap each transient build in `(with-escape scratch ...)`.
  The result is cloned into the enclosing active arena before the scratch arena
  is rewound.
- **One-shot clone-out:** use `(with-scratch body ...)` when a supported result
  should be cloned out of a fresh scratch arena and the caller does not need to
  reuse the arena handle across builds. The scratch arena is destroyed after the
  clone.
- **Keep results in a first-class arena:** allocate or receive an arena handle
  and wrap the build in `(in-arena arena ...)`. The saved active arena is
  restored afterward, and the returned owned value remains in the target arena.
- **Manual unsafe arena:** use `arena-set!`, `arena-rewind`, or
  `arena-destroy` only inside `(unsafe ...)` when the caller can prove all
  invalidated heap handles are dead. This is for compiler/tool internals that
  cannot express the workflow with the two safe forms.

Game-style frame/level/global lifetime layouts should use those surfaces by
lexical nesting: default program arena for global state, one `(with-arena level
...)` for per-level state, an inner `(with-arena frame ...)` for per-frame
scratch that returns only scalars or outer-owned values, and `(with-escape
scratch ...)` with a first-class scratch arena when a supported frame result
must be cloned into the active level state; use `(with-scratch ...)` for the
same clone-out when the scratch work is one-shot. The runnable cookbook is
`examples/arena_lifetimes.tl`. This v1 pattern does not model overlapping level
lifetimes, double-buffered levels, or event-driven unloads; those need the
overlapping-lifetime work tracked by #2568.

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
- String operations that create fresh storage (`substring`, `str-cat`,
  low-level concat primitives, `read-file`, `int->string`, `arg`), `make-array`,
  `box`, future `ByteBuf` construction/growth/copy-result helpers, and returned
  aggregate storage from calls inside the region.
- The body result must be region-free (scalars, or aggregates allocated *before*
  the `with-arena`).

The arena-model terminology calls the default allocation target the
program-lifetime arena and calls each nested `with-arena` body a scoped arena.
Unless a function explicitly says otherwise, allocation always uses the active
arena: the innermost scoped arena, or the default program-lifetime arena when
no scoped arena is active. Executable stdlib policy tests use `with-arena` to
verify these active-arena semantics.

#### Lifetime owners and v1 outlives model

The v1 checker treats a written lifetime name as the name of a visible owner,
not as an independently quantified region. The specified owner classes are:

- **Stack/frame owners:** function parameters and lexical bindings in the
  current frame. A reference type such as `(& x T)` names the stack slot or
  aggregate handle bound as `x`.
- **Lexical arena/region owners:** the implicit default program-lifetime arena and
  lexical `with-arena` binders. A scoped arena binder `phase` is named in
  `(& phase T)` reference types and in `(in phase T)` region-tagged handles.
  Untagged aggregate handles allocated outside any scoped arena are owned by
  the default program-lifetime arena; borrow inference uses the reserved
  lifetime name `program` for that storage, but there is no source binder to
  introduce.
- **Ordinary first-class arena owners:** handles returned by `arena-make`
  name single-thread allocation homes. They are not lexical binders and v1
  source code cannot write a lifetime name for them directly. Safe code may use
  them through `with-escape` and `in-arena`, but concurrent allocation into one
  ordinary arena is not defined.
- **Atomic first-class arena owners:** handles returned by the
  `arena-make-atomic` wrapper over `tl_arena_make_atomic` name allocation homes
  whose lifetime may span multiple threads. Multiple threads may make the same
  atomic arena current and allocate into it concurrently, subject to the source
  selection and lifetime rules below.

The v1 outlives relation is lexical. The same owner outlives itself. An owner
introduced by an outer parameter, `let` binding, or `with-arena` outlives
owners introduced in nested scopes. A nested stack slot or scoped arena does
not outlive its enclosing owner, so references and region-tagged handles tied
to the nested owner cannot be returned, stored into longer-lived bindings or
aggregates, or captured by closures that may escape. Non-lexical lifetime
shortening is deferred to #810.

`with-escape` is not a lexical lifetime binder and does not introduce a written
lifetime name. Its scratch arena is a first-class arena handle. The only
supported escape from that scratch arena is the form's clone step: supported
body results are cloned into the saved enclosing arena, the scratch arena is
rewound, and the result leaves the form without the scratch region tag.

Atomic arenas are shareable allocation owners, not synchronization primitives
for the values allocated inside them. A value owned by an atomic arena may cross
threads only when the atomic arena owner outlives both the sending and receiving
threads and the structural transfer/share classifier in section 6.5 accepts the
value. The arena owner proves storage lifetime only; mutation, aliasing, raw
pointer access, and interior synchronization remain separate obligations.

#### Standard library and builtin allocation policy

Written reference and arena lifetime syntax exists, and the borrowed `str`
frontend plus stdlib API migration have landed (#1453/#1454/#1082). Some stdlib
signatures still use compatibility `String`/aggregate types. The checker
therefore conservatively treats aggregate results from calls inside a scoped
arena as tagged with that arena. This is stricter than the future model for
functions that may return caller-owned data, but it prevents active-arena
values from escaping until explicit lifetime signatures are attached to the
stdlib surface.

| Category | Members | Arena behavior |
|----------|---------|----------------|
| Non-allocating inspection | `length`/`array-length` on arrays, `length`/`string-length`, `string-ref`/`char-at`, `string-eq`/`string=?`, `string->int`, stdlib string predicates such as `string-contains` | Reads caller-provided handles and returns scalars. |
| Returns active-arena owned data | `make-array`, `box`, `arg`, `read-file`, `file-read-chunk`, `read-stdin-line`, `read-stdin-bytes`, `str-cat`/low-level concat primitives, `substring`/`string-slice`, `int->string`, future `ByteBuf` construction/growth/copy-result helpers, stdlib trimming/replacement helpers when they build a new string | Fresh storage is allocated in the active arena and cannot escape a scoped arena. |
| Returns caller-provided data | `stdlib/string.tl` `string-replace` when no match is found; `stdlib/io.tl` `read-file-or` when the path is missing; check-only `stdlib/string_caller_result.tl` and `stdlib/io_caller_result.tl` companion surfaces | Compatibility wrapper calls inside a scoped arena are still treated conservatively as arena-tagged aggregate results. The companion modules express the borrowed/caller-owned distinction in source/typecheck-only reference-typed aggregates; ordinary lowering of those aggregate values still waits for reference/borrow lowering. |
| Mutates caller-provided storage | `array-set!`, future `byte-buf-set!`/`bytes-set!` style helpers | Mutates storage named by the caller; it does not allocate unless an owned-buffer growth operation is explicitly requested. Region checks reject storing shorter-lived aggregate handles into longer-lived containers, and borrowed `bytes` mutation requires an exclusive mutable view. |
| Host/runtime IO | `print*`, `panic`/`error`, `flush-stdout`, `write-file`, `file-exists?`, stdlib IO helpers | Performs target IO; any temporary strings used by the helper allocate in the active arena. |

The owned `String` / borrowed `str` source contract is specified in section
3.11, alongside the reserved `ByteBuf` / borrowed `bytes` binary-storage
contract. Check-only companion stdlib modules now expose borrow-typed
caller-result aggregate surfaces, while runnable compatibility wrappers still
use lowerable owned `String`/aggregate signatures. Except for the explicit
`stdlib/arena.tl` manual-control surface, no
current stdlib function manually resets arenas; safe scoped cleanup is owned by
`with-arena`. Source code that needs manual arena control imports
`stdlib/arena.tl` and uses the first-class arena helpers, with `arena-set!`,
`arena-destroy`, and `arena-rewind` gated by `(unsafe ...)`.

Nested `with-arena` forms create independent subregions whose values do not
mix. Inner-region values cannot escape to the outer region; outer-region values
can be used inside the inner region without restriction (they carry the outer
tag, not the inner one).

Linux and Windows native targets both implement `with-arena` reclamation through
`tl_region_mark` / `tl_region_reset`. Integration tests assert that repeated
scoped allocations restore the saved arena mark on both hosts.

#### First-class scratch arena escape - `with-escape`

Compiler internals and long-running tools may import `stdlib/arena.tl`, allocate
a first-class scratch arena with `arena-make`, switch to it for transient work,
and then keep only a deep-cloned result. The safe source form for this pattern
is:

```lisp test=check name=with-escape-example
(import "stdlib/arena.tl")
(import "stdlib/string.tl")

(define (build-message) : String
  (let
    [scratch : i64 (arena-make)]
    (with-escape scratch
      (int->string 42))))
```

`with-escape` evaluates the arena expression in the current arena, records the
enclosing active arena, switches to the scratch arena, marks it, evaluates the
body, switches back to the enclosing arena, clones the body result when the type
requires it, rewinds the scratch arena to the entry mark, and restores the
enclosing active arena. This lowers to the same `arena-current` / `arena-set!` /
`arena-mark` / `clone` / `arena-rewind` sequence that hand-written escape sites
used before. The form is intended for first-class scratch arenas; it is not a
lexical lifetime binder, and lexical region cleanup remains the job of
`with-arena`.

#### One-shot scratch arena escape - `with-scratch`

Use `(with-scratch body ...)` when the scratch arena is only needed for one
transient build:

```lisp test=check name=with-scratch-example
(import "stdlib/string.tl")

(define (build-message) : String
  (with-scratch
    (int->string 42)))
```

`with-scratch` creates a fresh first-class scratch arena, records the enclosing
active arena, switches to the scratch arena, evaluates the non-empty body
sequence, switches back to the enclosing arena, clones the body result when the
type requires it, destroys the scratch arena head, restores the enclosing active
arena, and returns the cloned result. It uses the same clone-supported result
rules and source-region stripping as `with-escape`, and rejects unsupported
result shapes with a `with-scratch` diagnostic.

#### First-class arena allocation target - `in-arena`

Use `(in-arena arena-expr body ...)` when a result should stay owned by a
first-class arena rather than being cloned back to the caller's active arena:

```lisp test=check name=in-arena-example
(import "stdlib/arena.tl")
(import "stdlib/string.tl")

(define (build-in-level [level : i64]) : String
  (in-arena level (int->string 42)))
```

`in-arena` evaluates `arena-expr` in the current arena, records the enclosing
active arena, switches to the target, evaluates the non-empty body sequence, and
restores the saved arena on normal completion, `(return ...)`, or recoverable
`try` propagation. It does not call `arena-mark`, `arena-rewind`, or
`arena-destroy`, and it does not clone the body result. The body result type is
returned unchanged. Nested lexical `with-arena` escape rules still apply:
`(in-arena scratch (with-arena inner (int->string 1)))` is rejected because the
inner scoped region would escape.

#### Atomic arena allocation target

The source wrapper for `tl_arena_make_atomic` is:

```lisp test=check name=arena-make-atomic-specified
(import "stdlib/arena.tl")

(define (main) : i64
  (let
    [shared : i64 (arena-make-atomic)]
    shared))
```

`arena-make-atomic` returns a first-class arena handle and does not make that
arena current. A thread allocates into an atomic arena by making it the active
allocation target for a dynamic extent. The safe spelling is `in-arena`: it
evaluates `arena-expr`, saves the calling thread's current arena, installs the
target for `body`, then restores the saved arena without marking, rewinding,
destroying, or cloning. With #2591, "current arena" is thread-local, so selecting
an atomic arena in one thread does not change another thread's default arena.
The lower-level `arena-set!` helper remains an unsafe manual operation for code
that cannot express its dynamic allocation extent with `in-arena`; callers must
prove that the selected arena is valid for the current thread and that later
reset/destroy operations cannot invalidate live handles.

Values allocated while an atomic arena is current are owned by that atomic arena
for thread-safety reasoning, even where the transitional lowerable type remains
an ordinary aggregate handle. The checker must reject safe cross-thread transfer
unless the atomic arena's lifetime spans every thread that can hold the value
and the section 6.5 structural classifier accepts the type shape. The ordinary
first-class arena returned by `arena-make` does not have this spanning-owner
property and must not be used as a concurrent allocation target.

Resetting or destroying an atomic arena while any worker can still allocate into
it or hold a value owned by it is rejected by safe code. The v1 proof shape is
"join all users before reset/destroy" unless a later checker slice provides an
equivalent ownership proof. Until that proof is implemented, `arena-rewind` and
`arena-destroy` on atomic arenas remain unsafe-only operations, matching the
ordinary manual arena helpers. The runtime helpers have no permission to make
use-after-reset deterministic for unsafe misuse; the no-UB guarantee is enforced
by rejecting the safe program before lowering.

#### Scoped non-memory resources - `with`

The `(with ([name init cleanup] ...) body ...)` form (§5.19) is the
source surface for deterministic cleanup of non-memory resources. It does not
select an allocation arena and does not reset heap storage. Cleanup is explicit
in the binding and must return `unit`; TypeLisp still has no implicit
destructors or automatic `drop`.

This keeps resource lifetime policy independent from arena lifetime policy:
files, process handles, locks, mapped files, and temporary paths use `with`;
heap allocation reclamation uses `with-arena` or explicit unsafe arena
operations below. Cleanup-owning aggregates (section 4.6.1) use the same `with`
owner scope plus a declared aggregate cleanup function for the field cleanup
plan. Compiler support is implemented (#907); move-only enforcement comes from
the section 4.6.2 checker.

#### Manual arena helpers

Programs that need manual control can import `stdlib/arena.tl` and use the
first-class arena helpers:

```lisp test=check name=arena-manual-helpers
(import "stdlib/arena.tl")

(define (main) : unit
  (let
    [home : i64 (arena-current)]
    [scratch : i64 (arena-make)]
    (unsafe
      (begin
        (arena-set! scratch)
        (arena-rewind (arena-mark))
        (arena-set! home)
        (arena-destroy scratch)))))
```

`arena-make`, `arena-make-atomic`, `arena-current`, and `arena-mark` are safe:
they create an arena handle, read the active arena handle, or record the active
arena bump pointer.
By themselves they do not switch the active arena, free arena chains, rewind
allocation, or invalidate live safe handles.

Linux runtime tests may opt into poison-on-reclaim mode with:

```lisp test=check name=arena-poison-enable-extern
(extern (tl_arena_poison_enable) : unit)
```

After `tl_arena_poison_enable` is called, Linux `tl_region_reset` and
`tl_arena_destroy` fill reclaimed or retired arena bytes with `0xA5` immediately
before a rewind, retirement, or unmap. This mode is off for normal compiler
output unless explicitly enabled by the program, and it is a debugging aid
rather than a safety boundary. Windows poison-on-reclaim behavior is currently
unsupported; the poison fixtures are covered on Linux and skipped on Windows.

A region reset mark invalidates every heap handle allocated after that mark, so
it is only valid when the caller can prove those values are dead, such as after a
compiler, formatter, package-tooling, or REPL iteration has discarded all
phase-local results. It is not a safe arbitrary source-level `free`
replacement.

Direct calls to these raw reset helpers require an unsafe context. The safe
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
- `ptr-read`, `ptr-write!`, `ptr-offset`, `ptr-cast`, `ptr->int`, `int->ptr`,
  and raw pointer atomics require `(unsafe ...)` because the typechecker cannot
  prove their memory or ABI preconditions.
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
  `.rodata`; `substring`, `string-slice`, `str-cat`, low-level concat
  primitives, `read-file`, `arg`, and `int->string` return fresh heap-allocated
  string storage. There is no source operation that mutates a string's bytes.
- Dynamic arrays are mutable heap buffers. `array-set!` mutates the buffer named
  by the live owner handle under the temporary compatibility rule in section
  4.6.2. Explicit shared mutable aliases require future reference/borrow
  semantics rather than copying the array handle.
- Struct and enum values are pointer-sized aggregate handles internally.
  Struct field-place assignment mutates selected fields in place through owned
  storage places or mutable references. Enum payloads are consumed by a
  by-value `match`; borrowing a scrutinee for non-consuming pattern inspection
  is deferred to the borrow checker.
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

```lisp test=ignore name=dynamic-array-aliasing reason="current compatibility aliasing behavior; future move checker rejects copied array handles"
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
- Structs with construction, field access, and field-place assignment.
- Dynamic arrays: `make-array`, `array-ref`, `array-set!`, `length`.
- Strings: literals, `string-ref`/`char-at`, `string-length`/`length`,
  `string-eq`/`string=?`, `str-cat`, `substring`/`string-slice`,
  `string->int`, `int->string`.
- Stdlib I/O helpers in `stdlib/io.tl`: `arg-count`, `arg`, `read-file`,
  `write-file`, `file-exists?`, `file-open`, `file-close`,
  `file-read-chunk`, `read-stdin-line`, `read-stdin-bytes`, `stdin-eof?`,
  `flush-stdout`, `print`, `print-bool`, `print-newline`,
  `print-string`/`print-str`, `print-char`, `print-float`, `print-error`,
  `panic`/`error`, and related recoverable wrappers. These are imported stdlib
  definitions, not implicit compiler builtins.
- First-class arena helpers in `stdlib/arena.tl`: `arena-make`,
  `arena-current`, `arena-mark`, `arena-set!`, `arena-destroy`, and
  `arena-rewind`; invalidating helpers require `(unsafe ...)`. The safe
  `in-arena` form switches to a first-class arena for one body without exposing
  `arena-set!` to safe code, and `with-scratch` performs one-shot scratch
  clone-out without exposing arena destruction to safe code.
- `extern` declarations, including unsafe declaration metadata for externs and
  top-level functions.
- Multi-file modules via `import`.
- Native x86_64 executable targets: `linux-x86_64` by default, and
  `windows-x86_64` for Windows x64 ABI output with CRT-linked runtime helpers.
- Transitional compiler compatibility builtins for string/array primitives such
  as `substring`, `string-ref`, and `array-ref`.
- Stdlib-owned FFI wrappers in `stdlib/io.tl`, `stdlib/env.tl`,
  `stdlib/fs.tl`, and `stdlib/cpu.tl` for argv, file I/O, stdio, panic/error,
  environment variables, filesystem status helpers, and CPUID/XGETBV.

### 8.2 What does NOT work (yet)

| Feature | Status |
|---------|--------|
| Tuple by-value ABI | Implemented: tuple parameters and returns compile by value |
| Fixed-array by-value return | Implemented |
| Tuple/Struct/Enum/String globals | Implemented, including runtime initializers (#331) |
| Reference captures in lambdas | Implemented for local non-escaping immutable captures (#808/#2280); escaping closures still reject reference captures. By-value captures work for scalars, String, dynamic arrays, tuples/structs/enums, and fixed arrays, including nested aggregate/fixed-array contents |
| Mutable captures (`set!` to captured names) in lambdas | Rejected by design (#2552): closure captures are by-value snapshots; assign lambda parameters/locals or mutate explicit captured storage instead |
| Tail call optimization | Direct/self and supported indirect function-value tail jumps implemented (#2506/#2363); ABI shapes that cannot be tail-jumped are conservatively emitted as ordinary calls |
| Raw pointer types, `(unsafe ...)`, and unsafe function/extern declarations | Implemented v1 parser/typechecker/lowering/backend surface |
| Raw pointer dereference/write/offset/cast | Implemented unsafe v1 operations; address-of, C-string helpers, volatile/atomic access, and borrow-checked references remain follow-ups |
| Garbage collection / general `free` | Not implemented; allocation is process-lifetime by default with unsafe explicit region reset for tool-owned phase boundaries |
| Move-only aggregate handle checking | Implemented: the selfhost checker enforces move-only aggregates with use-after-move, path-move, and move-while-borrowed diagnostics (#805/#1048/#1049/#1050) |
| `(with ...)` scoped non-memory resource cleanup | Implemented (#907): parser/typechecker/lowering with LIFO cleanup order |
| `(in-arena ...)` first-class arena target | Implemented (#2625): safe dynamic active-arena switch with restoration on normal and early exits, no mark/rewind/destroy/clone |
| Cleanup-owning aggregate declarations | Implemented for structs (#907); cleanup-owning enums remain reserved |
| SPMD / SIMD `foreach`, `spmd-reduce`, and `spmd-scan` | Scalar reference lowering implemented; AVX2/AVX-512 support a first contiguous `foreach` map/zip subset over `i8`, `u8`, `i16`, `u16`, `i32`, `u32`, `i64`, `u64`, `f32`, and `f64`, including public `(program-index)`/`(program-count)` lane identity forms for map values; AVX-512 also supports bool dynamic-array copies and bool-valued map results through private mask conversion; scalar gather-only dynamic-array reads are implemented with ordinary bounds checks while explicit SIMD modes reject non-contiguous gather shapes; eligible `spmd-reduce` folds, scalar inclusive `spmd-scan`, direct array-value `spmd-broadcast` maps, explicit `stdlib/atomic.tl` i32/i64 element helpers, and the current scalar/AVX-512 masked varying `if` subset are implemented; broader masked-if value results remain pending (#3356) |
| Public cross-lane/source SPMD gaps beyond implemented `spmd-reduce`/`spmd-scan`/`spmd-broadcast`, lane identities, masked-if subset, and explicit atomic helpers | Broader masked-if value results, vectorized/floating-point scans, general shuffles, remaining control-flow forms beyond masked `if`, and out-of-line varying calls remain deferred; public vector/mask/varying source type deferral is pinned (#2903), with live work split across #3356/#2767, #2852, and #2884 |
| Runtime SIMD dispatch (`defdispatch`) | Implemented for scalar/AVX2/AVX-512 variants with cached runtime selection and end-to-end selection verification |
| Windows region helpers | Implemented for `tl_region_mark`/`tl_region_reset` and `with-arena` scoped reclamation |
| Complete source locations for all semantic errors | Partial |
| REPL evaluation | Selfhost REPL bare expressions run through scratch build/run execution; public selfhost CLI routing is implemented |
| Package manager | Implemented v1: `typelisp.pkg` manifests, path and git/GitHub dependencies, dependency-DAG package builds, build-time `typelisp.lock` replay, explicit lock policy flags, deterministic lockfile rewrite, and package-cache reuse/refetch; registry support is deferred, semantic-version solving is a non-goal for the next phase, and workspaces are deferred |
| LSP / IDE support | Stdio diagnostics server implemented; richer IDE features pending |

---

## 9. Error handling

TypeLisp has one standard error-handling mechanism today: **panic**.

```lisp test=ignore name=panic-expression reason=not-standalone
(panic "message")
```

- Prints the message to stderr through the stdlib platform FFI binding.
- Calls the platform `exit` binding with status `134`.
- Panic is a terminal operation; it never returns normally.
- `error` is an alias for `panic`.

The stdlib declarations give `panic` and `error` the `never` return type. It can
satisfy any expected type and can merge with concrete `if` branch or `match` arm
result types.

```lisp test=compile name=panic-never-branch
(import "stdlib/io.tl")

(define (parse-or-zero [ok : bool]) : i64
  (if ok
    1
    (panic "parse failed")))
```

The older dummy-value style also remains valid, but it is no longer required
for builtin `panic`/`error`:

```lisp test=compile name=panic-dummy-value
(import "stdlib/io.tl")

(define (parse-or-zero-compat [ok : bool]) : i64
  (if ok
    1
    (begin
      (panic "parse failed")
      0)))
```

Function-local early exit uses the Lisp-shaped `(return expr)` form:

```lisp test=ignore name=early-return-guard reason="selfhost-only return; published stage0 may not support it yet"
(define (clamp-positive [x : i64]) : i64
  (begin
    (when (< x 0) (return 0))
    x))
```

- `(return expr)` is valid inside an enclosing function or lambda.
- `expr` is checked against the enclosing function's declared return type.
- The form has the compiler-internal bottom type, so it can appear in one
  branch of an `if` or `match` whose other branch produces the surrounding
  value.
- Active resource `with` cleanup functions and scoped `with-arena` resets run
  before the early exit leaves their scope.
- `(return expr)` is rejected outside a function and inside `foreach`/SPMD
  bodies.

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
(import "stdlib/str_cat.tl")
(import "stdlib/string.tl")

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
    (ErrI64 (str-cat "bad: " text))))

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

```lisp test=ignore name=result-try-success reason="try propagation awaits public test-mode coverage"
(import "stdlib/str_cat.tl")

(defenum ResultI64
  (OkI64 i64)
  (ErrI64 String))

(define (read-small [text : String]) : ResultI64
  (if (string-eq text "7")
    (OkI64 7)
    (ErrI64 (str-cat "bad: " text))))

(define (read-plus-one [text : String]) : ResultI64
  (let ([value : i64 (try (read-small text))])
    (OkI64 (+ value 1))))
```

```lisp test=ignore name=result-try-incompatible-error reason="negative propagation example; should be an expect-error once SPEC examples support this form"
(import "stdlib/str_cat.tl")

(defenum ResultI64
  (OkI64 i64)
  (ErrI64 String))

(defenum ResultBool
  (OkBool bool)
  (ErrBool bool))

(define (read-small [text : String]) : ResultI64
  (if (string-eq text "7")
    (OkI64 7)
    (ErrI64 (str-cat "bad: " text))))

(define (bad-propagation [text : String]) : ResultBool
  (let ([value : i64 (try (read-small text))])
    (OkBool (> value 0))))
```

Panic remains separate from recoverable results. It aborts instead of producing
an error variant, and its internal bottom type can still inhabit a
result-returning branch:

```lisp test=compile name=panic-vs-result
(import "stdlib/io.tl")

(defenum ResultI64
  (OkI64 i64)
  (ErrI64 String))

(define (read-or-abort [ok : bool]) : ResultI64
  (if ok
    (OkI64 7)
    (panic "not recoverable")))
```

Current implementation status: selfhost has explicit `comptime-decl` generated
concrete Option/Result family declarations and helper `define`s through the
generated-declaration registry. `(try expr)` supports the Result-like convention
of a concrete enum with one `Ok*` payload variant and one `Err*` payload variant,
and the Option-like convention of one `Some*` payload variant with one `None*`
absence variant.

---

## 10. CLI

```
Synopsis:
  typelisp - A typed Lisp/Scheme dialect with x86_64 backend

Usage:
  typelisp <command> [options]
  typelisp <command> --help

Commands:
  typelisp build          Build a source file or package artifact
  typelisp check          Type check a source file or package
  typelisp clean          Remove build artifacts
  typelisp compile        Generate assembly or IR
  typelisp doc            Generate documentation or run doc tests
  typelisp fmt            Format source files or a package
  typelisp init           Scaffold a package in the current directory
  typelisp inspect        Inspect a TypeLisp comptime image
  typelisp lint           Lint source files or a package
  typelisp lsp            Start stdio LSP diagnostics server
  typelisp new            Scaffold a new package directory
  typelisp repl           Start minimal stdio REPL
  typelisp run            Compile, link, and run a source file
  typelisp test           Run or check inline tests

Global Options:
  --help, -h                     Show root or command help

Common Command Options:
  --target <target>              linux-x86_64 or windows-x86_64
  --backend-mode <mode>          scalar, avx2, or avx512
  --manifest-path <file>         Package manifest path
  --stdlib-root <dir>            Search root for stdlib/... imports
  --opt-level <0|1|2>            Select optimizer level
  --cfg <name>                   Enable a compile-time cfg predicate name

Environment:
  TYPELISP_STDLIB_ROOT           Optional fallback root before embedded stdlib

Selected Command Forms:
  typelisp compile <file.tl> [-o <file>] [--emit-ir]
  typelisp compile --batch <input-output-list>
  typelisp build <file.tl> [-o <exe>]
  typelisp build [--manifest-path <typelisp.pkg>] [--profile dev|release] [--locked|--update-lock]
  typelisp inspect <file.tlci>
  typelisp run <file.tl> [-- <args>...]
  typelisp fmt [<file.tl>...] [--check]
  typelisp lint [<file.tl>...] [--check] [--deprecated-string-concat]
  typelisp test [<file.tl>] [--check]
```

`typelisp <command> --help` is the source of truth for command-specific usage
forms. `compile -o <file>` writes assembly or IR to the given path,
`compile --emit-ir` emits the lowered and optimized IR instead of assembly, and
`compile --batch <file>` reads input|output pairs in one compiler process.
`build --profile dev|release` selects the package build profile, `build
--release` aliases `--profile release`, and `build --manifest-path <file>` uses
an explicit package manifest. `build --locked` requires a matching
`typelisp.lock` and does not rewrite it; `build --update-lock` refreshes remote
pins and rewrites `typelisp.lock`. These lock-policy flags are valid only for
package builds. `fmt --check` reports files that would change
without writing them, while `lint --check` exits non-zero when lint findings are
present. `lint --deprecated-string-concat` enables the staged deprecation rule
for user-facing concat primitives. Without explicit files, `fmt` and `lint`
default to the nearest `typelisp.pkg` upward. `test --check` type-checks generated inline test
harnesses without assembling or running them; `test` defaults to the host target
unless `--target <target>` is supplied.

For source-file builds, the default executable path is the source path with the
`.tl` extension removed on Linux and with `.exe` on Windows. Source-file
`build` does not run the executable. The package build form writes the artifact
selected by `typelisp.pkg`'s `kind` field and a metadata-only
`<package-name>.tlci` image in the same profile directory. `inspect` validates
and renders `.tlci` files without executing or loading contained code.

Linux native build/run uses `as` and `ld`. Windows native build/run uses
`clang --target=x86_64-pc-windows-msvc` and `lld-link`, links against the CRT,
and emits a console `.exe`.

`check` is accepted as the public top-level type-check command.

The public `typelisp repl` command supports `.help`, `.type <expr>`, and `.exit`.
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
- Scalar `f64` and `f32` both use the float (`%xmm`) registers: `f64` moves with
  `movsd`, `f32` with single-precision `movss`.
- Return value: `%rax` (integer), `%xmm0` (float, `f64` or `f32`).
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
- Scalar `f64` and `f32` both use the float (`%xmm`) registers: `f64` moves with
  `movsd`, `f32` with single-precision `movss`.
- Return value: `%rax` (integer), `%xmm0` (float, `f64` or `f32`).
- Callers reserve 32 bytes of shadow space before each call.
- The CRT owns process startup; Windows output emits `main` and no Linux
  `_tl_start` wrapper.

### 11.3 Data layout

Default TypeLisp aggregate layout is stable source metadata. Structs use
declaration-order inline storage with natural alignment. Enums use a TypeLisp
tagged-union layout: an 8-byte tag at offset 0 plus max-aligned payload
storage. Target C ABI call/return lowering is a separate backend contract.

| Type | Size | Alignment |
|------|------|-----------|
| `i8`/`u8`/`bool`/`char` | 1 | 1 |
| `i16`/`u16` | 2 | 2 |
| `i32`/`u32`/`f32` | 4 | 4 |
| `i64`/`u64`/`f64`/func ptr | 8 | 8 |
| `(Ptr T)` / `(MutPtr T)` | 8 | 8 |
| `String`/`DynArray`/`Box`/reference-like handles | 8 | 8 |
| Struct values | declaration-dependent | declaration-dependent |
| Enum values | declaration-dependent | declaration-dependent |

- Structs: sequential layout with natural alignment per field. There is no
  padding minimization; fields are placed in declaration order.
- Enums: tag word (8 bytes) plus max payload storage. Each variant payload is
  laid out from offset 8 using natural alignment for each payload position.
- `String` and dynamic-array source values are handle-sized in this layout;
  their backing storage is larger implementation-owned data.
- The current IR/ABI may still carry aggregate values through pointer-shaped
  heap handles in positions not covered by layout queries. That is an
  implementation detail and not the source layout contract.
- `(:repr c)` is accepted as struct compatibility/ABI-intent metadata and does
  not change default struct field offsets. Backend extern lowering validates
  target C ABI aggregate classes separately.

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
(import "stdlib/io.tl")

(define (main) : i64
  (begin
    (print-string "hello\n")
    0))  ; prints hello + newline, returns 0
```

### Extern call

```lisp test=run name=extern-tl-alloc exit=0 stdout=""
(extern (tl_alloc [arg0 : i64]) : u64)

(define (main) : i64
  (begin
    (tl_alloc 16)
    0))
```

### Raw pointer FFI sketch

```lisp test=ignore name=raw-pointer-ffi-sketch reason="requires an external pointer provider"
(extern (c-buffer) : (MutPtr u8))

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
                | cfg-decl
                | comptime-decl
                | comptime-decls
                | define-func
                | unsafe-decl
                | dispatch-decl
                | defmacro
                | extern-decl
                | module-decl
                | import-decl
                | export-decl
                | include-str-decl
                | include-bin-decl
                | defenum
                | defstruct
                | test-decl
                | module-macro-call

cfg-decl      ::= "(" "cfg" cfg-predicate top-level ")"
cfg-predicate ::= ident
                | "(" "all" cfg-predicate* ")"
                | "(" "any" cfg-predicate* ")"
                | "(" "not" cfg-predicate ")"
comptime-decl ::= "(" "comptime-decl" generated-meta? generated-payload ")"
comptime-decls ::= "(" "comptime-decls" generated-bundle-meta generated-payload+ ")"
generated-meta ::= "(" ":generated" qualified-name ident expr* ")"
generated-bundle-meta ::= "(" ":generated" qualified-name expr* ")"
generated-payload ::= defstruct | defenum | define-var | define-func
define-var    ::= "(" "define" ident [":" type] expr ")"
include-str-decl ::= "(" "include-str" ident string ")"
include-bin-decl ::= "(" "include-bin" ident string ")"
define-func   ::= "(" "define" "(" ident param* ")" [":" type] expr ")"
unsafe-decl   ::= "(" "unsafe" unsafe-decl-payload ")"
unsafe-decl-payload ::= define-func | extern-decl
dispatch-decl ::= "(" "defdispatch" ident dispatch-variant+ ")"
dispatch-variant ::= "(" dispatch-isa ident ")"
dispatch-isa  ::= "scalar" | "avx2" | "avx512"
defmacro      ::= "(" "defmacro" "(" ident macro-operand* ")" ":" macro-result-type expr+ ")"
macro-operand ::= "[" ident ":" type "]"
                | "[" ident ":" type "..." "]"      ; variadic final operand only
macro-result-type ::= type
                    | "module"                      ; declaration-emitting macro
                    | "decls"                       ; declaration-splicing macro
extern-decl   ::= "(" "extern" ident extern-meta* ":" type ")"
                | "(" "extern" extern-head extern-meta* ":" type extern-meta* ")"
extern-head   ::= "(" ident extern-param* extern-varargs? ")"
extern-param  ::= "[" ident ":" type "]"
extern-varargs ::= "..."
                | "[" ident ":" "..." ident "]"
extern-meta   ::= "(" ":abi" "c" ")"
                | "(" ":symbol" string ")"
                | "(" ":link-lib" string ")"
                | "(" ":link-search" string ")"
                | "(" ":link-arg" string ")"
module-decl   ::= "(" "module" module-ident ")"
import-decl   ::= "(" "import" string ["module" module-ident] [import-alias] ")"
                | "(" "import" module-ident [import-alias] ")"
                | "(" "import" macro-call [import-alias] ")"
import-alias  ::= ("as" | ":as") ident
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
                | aggregate-lifetime-meta
                | aggregate-cleanup-meta
enum-meta     ::= aggregate-lifetime-meta
                | aggregate-cleanup-meta       ; reserved, rejected in v1
aggregate-lifetime-meta ::= "(" ":lifetimes" ident+ ")"
aggregate-cleanup-meta ::= "(" ":cleanup" ident ")"
test-decl     ::= "(" "test" ident expr+ ")"
module-macro-call ::= macro-call                    ; must resolve to a `: Decls` macro

param         ::= "[" ident ":" type "]"
field         ::= "(" ident type field-meta* ")"
field-meta    ::= "(" ":cleanup" ident ")"
                | "(" ":owned" ")"
variant       ::= "(" ident variant-payload* ")"
variant-payload ::= type field-meta*           ; payload cleanup metadata reserved, rejected in v1

expr          ::= literal
                | ident
                | "(" "if" expr expr expr ")"
                | "(" "cond" cond-clause+ cond-else-clause ")"
                | "(" "when" expr expr ")"
                | "(" "unless" expr expr ")"
                | "(" "let" binding+ expr ")"
                | "(" "while" expr expr ")"
                | "(" "begin" expr+ ")"
                | "(" "set!" ident expr ")"
                | "(" "ann" expr ":" type ")"
                | "(" "cast" expr ":" type ")"
                | "(" "match" expr match-arm+ ")"
                | "(" "foreach" foreach-clause expr ")"
                | "(" "cfg" cfg-predicate expr [expr] ")"
                | "(" "spmd-reduce" reduce-op foreach-clause expr expr ")"
                | "(" "spmd-scan" reduce-op scan-clause expr expr ")"
                | "(" "spmd-broadcast" expr expr ")"
                | "(" spmd-lane-form ")"
                | "(" "lambda" "(" param* ")" [":" type] expr ")"
                | "(" "return" expr ")"
                | "(" "with-arena" ident expr+ ")"
                | "(" "with-escape" expr expr+ ")"
                | "(" "with-scratch" expr+ ")"
                | "(" "in-arena" expr expr+ ")"
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
                | "(" expr call-operand* ")"  ; function or macro call

macro-call    ::= "(" qualified-name call-operand* ")"

call-operand  ::= expr
                | "[" expr expr "]"            ; macro-only ExprClause operand

cond-clause   ::= "[" expr expr "]"
cond-else-clause ::= "[" "else" expr "]"

borrow-expr   ::= "(" "&" borrow-place ")"
                | "(" "&" ident borrow-place ")"
                | "(" "&mut" borrow-place ")"
                | "(" "&mut" ident borrow-place ")"
borrow-place  ::= ident
                | "(" "struct-get" borrow-place ident ")"
                | "(" "tuple-ref" borrow-place integer ")"
                | "(" "array-ref" borrow-place expr ")"

;; Dotted field sugar such as `p.x` is an `ident` in this grammar and becomes a
;; borrow-place only when its leading segment resolves to a local binding.

binding       ::= "[" ident [":" type] expr "]"
resource-binding ::= "[" ident expr expr "]"  ; name init cleanup-fn
foreach-clause ::= "(" "[" ident ":" type expr expr "]" ")"
scan-clause   ::= "(" "[" ident ":" type expr expr "]"
                      "[" ident ":" type expr "]" ")"
reduce-op     ::= "sum" | "min" | "max" | "all" | "any"
spmd-lane-form ::= "program-index" | "program-count"
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
                | "ExprClause" | "ExprClauseList"   ; macro-only bracket operand values
                | "(" "Tuple" type+ ")"
                | "(" "Array" type [integer] ")"
                | ptr-type
                | ref-type
                | macro-type
                | "(" "->" type+ ")"
                | "(" "in" ident type ")"              ; region-tagged (v1)
                | nominal-type

nominal-type  ::= ident                                ; zero-lifetime enum/struct
                | "(" ident lifetime-arg+ ")"          ; lifetime-only nominal use
lifetime-arg  ::= ident

ptr-type      ::= "(" "Ptr" type ")"
                | "(" "MutPtr" type ")"

ref-type      ::= "(" "&" ident type ")"
                | "(" "&mut" ident type ")"

macro-type    ::= "(" "macro" "(" macro-type-slot* ")" type ")"
macro-type-slot ::= type
                  | type "..."                         ; variadic final slot only

module-ident  ::= ident ("/" ident)*
qualified-name ::= ident | module-ident "/" ident
ident         ::= [a-zA-Z_][a-zA-Z0-9_!?+-=*/<>:]*
integer       ::= [-]?[0-9]+
float         ::= [-]?[0-9]+\.[0-9]+
bool          ::= "true" | "false"
char          ::= "'" char-payload "'"
                | "'\\" char-escape "'"
char-payload  ::= any source character except "'" "\\" newline carriage-return
char-escape   ::= "n" | "t" | "r" | "0" | "\\" | "'"
string        ::= \"...\"
```

---

## 14. Changelog

### 0.1.0-dev

- Initial specification covering the language as implemented.
- Specified the v1 atomic arena runtime/source contract for concurrent
  allocation and cross-thread arena ownership (#2641).
