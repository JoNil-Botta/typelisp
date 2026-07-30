# TypeLisp Language Specification

> **Version:** 0.1.0-dev  
> **Targets:** x86_64 Linux (System V AMD64 ABI) and x86_64 Windows (Win64 ABI). macOS and ARM are not supported and are not near-term goals.  
> **Constraint:** self-hosted TypeLisp implementation; zero third-party dependencies.

This document is the specification of the TypeLisp language: what compiles,
what types mean, and what compiled programs promise. It describes the
language at its decided end state; section 8 records where the current
implementation still falls short of a rule in this document. The issue
tracker records design decisions and the work in flight.

---

## 1. Overview

TypeLisp is a statically typed Lisp/Scheme dialect that compiles to native
x86_64 assembly. Every expression has a known type at compile time. There is
no runtime type tagging, no garbage collector, and no interpreter.

### Design goals

The language is built around these pillars; later sections give the binding
contracts for each.

- **Typed.** Every expression has a known type at compile time; no runtime
  type tagging.
- **Native.** Programs compile straight to x86_64 machine code for
  `linux-x86_64` and `windows-x86_64`. No bytecode VM, no interpreter, no
  garbage collector.
- **Self-hosted, zero dependencies.** Compiler, stdlib, tooling, and tests
  are written in TypeLisp; each published stage0 builds its own successor.
  The only build inputs are the native assembler/linker toolchain.
- **Safe.** Safe code has no undefined behavior (see the table below).
  Ownership, moves, borrows, lifetimes, and arena regions are checked
  statically, in the spirit of Rust but with arenas instead of general
  `free` or garbage collection.
- **Comptime as the abstraction mechanism.** No source-level generics,
  traits, interfaces, or `impl`; compile-time generation and typed macros
  produce concrete declarations (section 3.7).
- **SPMD data parallelism.** ISPC-style `foreach`/`spmd-reduce`/`spmd-scan`
  with uniform/varying semantics and scalar-equivalent SIMD lowering
  (section 5.15).
- **Module identity.** C3-style modules where module identity participates
  in name resolution and symbol naming (section 4.4).
- **Fast.** Generated code quality should approach LLVM (`clang -O2`) on
  the benchmark corpus while compilation itself stays fast. Performance is
  tracked deterministically through paired C baselines and
  instruction-count CI gates.

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
Optimizations may rely on the static type, move, borrow, and region facts
below, but must not reinterpret accepted safe code as having behavior outside
this table.

| Safety area | Safe-code outcome | Binding rule |
|-------------|-------------------|--------------|
| Integer `+`, `-`, `*`, and `neg` overflow | Defined wrap | Wrap modulo 2^N for the result type width; signed results interpret the wrapped bits as two's-complement values. See section 5.4. |
| Integer `/` and `%` invalid operands | Deterministic runtime trap | Divisor zero and signed minimum divided/remaindered by `-1` trap through the integer division/remainder abort path. See section 5.4. |
| Integer shift counts | Deterministic runtime trap | `shl`/`shr` trap when the count is negative or not less than the left operand's bit width. See section 5.4. |
| Scalar numeric casts | Defined result | Integer/integer, integer/`char`, `f64` ↔ `f32`, and integer/`char` ↔ float casts use defined truncation, sign/zero-extension, and round-to-nearest/truncate-toward-zero rules. See section 3.8. |
| Non-numeric casts | Static reject | Casts touching non-numeric types are rejected before lowering. See section 3.8. |
| Array, string, slice, and generated collection bounds | Deterministic runtime trap | Out-of-bounds indexing, invalid slice ranges, invalid buffer lengths, and allocation byte-count overflow trap through the bounds-check abort path. SPMD inactive tail lanes perform no bounds checks or memory accesses. See sections 5.15 and 6.1. |
| Initialized-before-use and no use-after-move | Static reject | Safe code cannot read an uninitialized place or a place whose move-only value has been moved. Move-only aggregate semantics are specified in section 4.7.2. |
| Borrow/reference validity and arena escape | Static reject | References and region-tagged values cannot outlive their lifetime/arena, be returned or stored into a longer-lived slot, or be captured by an escaping closure. Non-lexical last-use shortening applies to straight-line sequences and path-sensitive `if`/`match` joins; loop joins are conservative. See sections 3.9, 3.10, 5.16, and 7.3. |
| Mutation through shared references | Static reject | Safe code cannot write through an immutable/shared reference; mutable-reference writes require exclusive access. Aggregate-handle mutation is governed by the move and aliasing rules in sections 4.7.2 and 7.6. |
| SPMD safe-code data-race freedom | Static reject | Safe `foreach`/SPMD code rejects varying calls, unsupported varying control flow, unsafe shared mutation, and reduction shapes that cannot be proven race-free. See section 5.15. |
| Task-thread data-race freedom | Static reject | Safe task-threading APIs reject captured, sent, returned, or shared values whose arena owner does not prove storage lifetime across the participating threads, or whose structural classification does not prove race-free access. See section 6.5. |
| Invalid enum/struct states | Static reject | Safe code constructs enums and structs only through their checked constructors and pattern forms. Arbitrary bit construction, invalid variants, invalid field layouts, and recursive-by-value aggregate states are rejected. See sections 3.5, 4.7, and 5.13. |
| Raw pointers, syscalls, foreign ABI assumptions, and manual arena reset | Static reject | Safe code may pass, return, compare, and null-test raw pointer values, but dereference, write, offset, pointer/integer casts, volatile access, direct syscall invocation, foreign ABI invariants beyond the declared signature, and invalidating manual arena operations require `(unsafe ...)`. See sections 3.4, 5.20, 7.3, and 7.4. |
| Invalid comptime-to-runtime values | Static reject | Comptime generation and reflection cannot smuggle invalid runtime values, invalid types, or unstable compiler-internal identities into safe runtime code; runtime observation of comptime-only metadata is rejected. See sections 3.7 and 5.17. |
| Valid comptime-generated runtime values | Defined result | Accepted generated declarations and values have ordinary valid runtime representations and follow the same safe-code contract as hand-written declarations. See sections 3.7 and 5.17. |

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
Optimizer → constant folding, GVN/CSE, copy propagation, DCE, LICM,
            inlining, strength reduction; opt-level 2 adds scalar
            register allocation
    ↓
Backend → x86_64 assembly (.s)
    ↓
Native toolchain → executable (ELF on Linux, PE on Windows)
```

---

## 2. Lexical structure

### 2.1 Tokens

The lexer produces exactly fourteen token kinds (`Token` in `src/token.tl`).
Keywords, booleans, `unit`, and identifiers are **not** distinct tokens: every
one of them is a `Sym`, and the parser decides what a symbol means from its
position. A token table that lists `define`, `if`, `true`, or `unit` as token
kinds does not describe this lexer.

| Token | Lexeme | Notes |
|-------|--------|-------|
| `LParen` | `(` | |
| `RParen` | `)` | |
| `LBracket` | `[` | Binding clauses, parameter lists, `cond` arms |
| `RBracket` | `]` | |
| `Int` | `[-]?([0-9]+ \| 0[xX][0-9a-fA-F]+ \| 0[bB][01]+)` | Integer literal; carries the original text |
| `Float` | `[-]?[0-9]+\.[0-9]+` | `f64` literal; carries the original text |
| `Str` | `"..."` | String literal, interned |
| `Char` | `'x'`, `'
'`, `'''` | Character literal |
| `Sym` | see below | Interned symbol: every keyword, identifier, `true`/`false`, `unit`, operator, and dotted path |
| `Quote` | `'` | Only when not opening a character literal |
| `Backtick` | `` ` `` | Quasiquote |
| `Comma` | `,` | Unquote |
| `CommaAt` | `,@` | Unquote-splicing |
| `End` | | End of input |

#### Symbols

A symbol is a run of alphanumerics and these punctuation characters:

```
- + * / ? ! > < = & : _ . %
```

Punctuation may appear **at the start** of a symbol as well as inside it, so
`&mut`, `->`, `<=`, `%`, `!`, and `set!` are all single `Sym` tokens. `.` is a
symbol character rather than a token, which is why a dotted member access such as
`string.eq` lexes as one symbol and is split later by name resolution.

`:` is a symbol character with three additional rules:

- a symbol beginning with `:` at the head of a list is a metadata keyword, as in
  `(:symbol "printf")` and `(:lifetimes source)`;
- `:as` is lexed as one whole symbol, for `(import stdlib.string as s)`;
- a trailing `:` is kept attached in a package-qualified prefix such as `pkg:`,
  which is an exception to the ordinary splitting of `:`.

Elsewhere `:` separates a binder from its type, as in `[x : i64]`, where it is a
`Sym` in its own right.

#### Quote versus character literal

`'` is ambiguous and resolved by lookahead: it opens a `Char` when the source
matches a character literal, and is otherwise a `Quote` token. A legacy character
spelling is still accepted for compatibility.

### 2.2 Comments

Semicolon starts a line comment: the lexer skips everything from `;` through
the next newline. Double semicolons are simply two semicolon characters; the
first one starts the comment.

The documentation extractor recognizes public documentation comments before
comments are discarded:

- `;#` starts a module/file documentation line.
- `;:` starts an outer item documentation line attached to the next supported
  top-level item: value `define`, function `define`, `extern`, `defenum`, or
  `defstruct`.
- `;#` and `;:` are the only public documentation comment syntaxes.
- `;` and `;;` are ordinary comments and are not public documentation.
- Outer item doc lines must be contiguous. A blank line, ordinary comment,
  module doc, unsupported top-level form, or unrelated source text clears the
  pending item doc block. A pending block at EOF is ignored.

Documentation tests are fenced examples inside public documentation comments.
`typelisp doc --test <file.tl>` recognizes Markdown code fences whose info
string starts with `typelisp` or `tl`, extracts them from `;#` module docs and
attached `;:` item docs, and checks each example as a standalone TypeLisp
source file. Results are reported per file for multiple explicit inputs and
for package doctests. An example passes when it parses, resolves imports, and
type-checks. Adding `expect-error` after the language tag inverts the
expectation: the example must fail during loading, parsing, or type checking.
`run` is mutually exclusive with `expect-error`. A runnable fence must include
`;; doctest-exit: <integer>` in the example body and may include
`;; doctest-stdout: -` / `;; doctest-stderr: -` or `literal:<escaped text>`
with `\n`, `\t`, `\r`, and `\\` escapes. Runnable examples execute on targets
that support the build/run path; other targets report an unsupported
runnable-doctest failure. Fences in other languages are ignored; unknown
TypeLisp fence options, empty TypeLisp examples, and unterminated TypeLisp
fences are malformed doctests.

`typelisp doc` generates Markdown documentation. Rendering
`typelisp doc input.tl -o output.md` loads the entry file with the normal
import resolver and emits one deterministic Markdown document for the entry
plus each reachable imported module once, including module navigation and
source/module sections. Package documentation uses the package source
discovery path selected by `--manifest-path <typelisp.pkg>`, or the nearest
manifest when no explicit input is supplied; package doc generation requires
`-o <out.md>`.

### 2.3 String escapes

| Escape | Meaning |
|--------|---------|
| `\\n` | Newline (LF, `0x0A`) |
| `\\t` | Tab (`0x09`) |
| `\\r` | Carriage return (`0x0D`) |
| `\\\` | Backslash |
| `\\"` | Double quote |

Any other escaped character denotes that character literally: `\0` in a
string is the character `0`, not a NUL byte.

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
expected type is present. Source float constants are finite-only: decimal
float literal text that parses to non-finite `f64`, or that rounds to
non-finite `f32` in a contextual `f32` position, is rejected during
typechecking. There is no source syntax for infinities or NaN: `NaN`, `nan`,
`Infinity`, `inf`, and similar spellings are ordinary identifiers and remain
unbound unless a program declares such names.

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
- Fixed-size, heterogeneous. Layout is sequential with natural alignment per
  element.
- Tuple literals lower to pointer values over inline element storage, and
  `tuple-ref` reads tuple values in local/expression positions.
- Tuple function parameters and by-value tuple returns are not part of the
  backend ABI; tuples travel by pointer handle.

**Fixed array:** `(Array type size)`
- Size must be a compile-time constant.
- Fixed-array literals lower to inline element storage. Values are passed
  around by pointer handle inside compiled code.
- `array-ref` and `array-set!` on fixed arrays are bounds-checked and use the
  compile-time length. By-value fixed-array returns are rejected by backend
  validation.
- Public `Array` means this fixed-size form only. Fixed arrays, stdlib
  vectors, and slices are the collection surface of the language; growable or
  runtime-sized collections use the vector and slice surfaces.
- Collection APIs inspect existing storage through immutable borrows and
  mutate through `&mut`. Mutating collection operations update storage in
  place instead of returning copied whole collections.

Unsized `(Array T)` — written without a size — is a compiler-internal
compatibility buffer, not a public source type. The compiler and stdlib use it
only for vector backing storage, SPMD lane and result buffers behind the
vector/slice surface, FFI/runtime buffers, and compiler-internal pools. Where
it appears internally, its value is a pointer to inline fat storage
`(data_ptr : u64, length : i64)`; the stored length is always non-negative;
allocation rejects negative lengths, traps if `length * sizeof(type)` would
overflow an `i64` byte count, and initializes every live element according to
the ZII `init` rules in section 5.12.1. It is not valid as a global
initializer, and public APIs must not expose it as a growable collection
type. Its internal spelling `__tl_dyn-array` names the same compatibility
buffer and is accepted unconditionally in compiler and stdlib sources; it is
not a public source type in either form.

**Owned string:** `String`
- `String` is an owned, immutable byte-string handle. The handle is a
  pointer-sized aggregate value whose pointed-to inline storage is a
  `{data_ptr, length}` pair.
- String literals have type `String`. Their bytes live in static read-only
  data, but the source value is still an owned `String` handle, not a
  borrowed `str`.
- Runtime-created strings from `str-cat`/the low-level concat primitives,
  `substring`, `read-file`, `arg`, `int->string`, stdin/file reads, and
  stdlib helpers allocate fresh `String` storage in the active arena.
- `String` is move-only under the aggregate handle rules in section 4.7.2.
  Non-consuming string operations borrow the string through
  `(& lifetime str)` views rather than consuming the owned handle.

**Borrowed string referent:** `str`
- `str` is an immutable borrowed byte-string referent. It is not a
  first-class value type.
- Bare `str` is rejected in value positions: parameters, returns, locals,
  globals, fields, enum payloads, tuple elements, and array element types.
- The only accepted source form for borrowed text is an immutable reference
  `(& lifetime str)`. Mutable string references `(&mut lifetime str)` are
  rejected; mutable bytes use `ByteBuf` and `bytes`.
- `str` is not NUL-terminated. Its length is carried with the borrowed view.

**Owned mutable byte buffer:** `ByteBuf`
- `ByteBuf` is an owned, move-only mutable byte buffer allocated in the
  active arena. It stores a data pointer, live length, and capacity.
- The live range `[0, len)` is initialized byte storage. The spare capacity
  range `[len, capacity)` is reserved implementation storage and cannot be
  read by safe code.
- `ByteBuf` has no text, encoding, or NUL-termination invariant.
- Growing a `ByteBuf` may allocate a new active-arena backing store and copy
  the live bytes. The old backing store is not reclaimed until its arena is
  reset or the process exits.

**Borrowed byte-slice referent:** `bytes`
- `bytes` is a borrowed byte-slice referent, not a by-value type.
- `(& lifetime bytes)` is an immutable borrowed byte view.
- `(&mut lifetime bytes)` is an exclusive mutable byte view over a
  fixed-length range. It may update existing bytes but cannot grow the owner.
- Bare `bytes` is rejected in value positions: parameters, returns, locals,
  globals, fields, enum payloads, tuple elements, and array element types.

### 3.3 Function types

`(-> arg1 arg2 ... ret)`
- Function pointers exist in the type system and ABI.
- Direct calls are resolved at compile time; indirect calls through function
  pointer values use `call *%rax`.
- A named top-level function can be used as a non-capturing function pointer
  value, e.g. `(apply1 inc 41)` where `apply1` takes a `(-> i64 i64)`.
- Non-capturing `lambda` literals are lifted to deterministic synthetic
  top-level functions and materialized as raw function pointer values.
- Capturing `lambda` literals build heap-allocated closure environments and
  evaluate to closure descriptor values. Supported captures are scalars,
  function values, `String` handles, array handles, and tuples of scalars
  (see §5.14).

Function parameters may opt into consuming ownership semantics. A named
function or lambda parameter spells the effect after its type:

```lisp test=ignore name=consume-parameter-syntax reason="illustrative declaration"
(define (into-length [source : String (:consume)]) : i64
  (string-length source))
```

The corresponding callable parameter type is `(:consume T)`, for example
`(-> (:consume String) i64)`. The marker is part of static callable identity:
a `(-> String i64)` value is not interchangeable with a
`(-> (:consume String) i64)` value. It does not change argument layout,
calling convention, or generated ABI.

`:consume` is valid only on runtime, non-reference function parameters. It is
rejected on `comptime` parameters, extern parameters, `(& lifetime T)`, and
`(&mut lifetime T)`. It may appear in direct, qualified, generated, lambda,
and function-value signatures; all preserve the same static effect.

### 3.4 Raw pointer types

Raw pointers are the explicit unsafe surface for FFI and low-level memory
work. They are intentionally separate from safe references and borrowing: raw
pointers are unsafe values, not checked references.

```lisp test=ignore name=raw-pointer-type-template reason=template
(extern (read-byte [arg0 : (Ptr u8)]) : u8)
(extern (write-byte [arg0 : (MutPtr u8)] [arg1 : u8]) : unit)
```

Type forms:

- `(Ptr T)` is a raw pointer to a value of type `T` that may be read through
  unsafe operations but may not be written through source-level pointer write
  operations.
- `(MutPtr T)` is a raw pointer to mutable storage for a value of type `T`;
  unsafe reads and writes are allowed.
- `Ptr`/`MutPtr` are source-level types, not ownership or lifetime types.
  They carry no borrow, aliasing, provenance, bounds, initialization,
  alignment, or non-null guarantee.
- Raw pointer values are pointer-sized, nullable, freely copyable ABI values.
  Copying a pointer copies only the address.
- There is no implicit conversion between `Ptr` and `MutPtr`; use the
  explicit unsafe `ptr-cast` operation.
- `T` may be any backend ABI value type that can be loaded or stored as a
  value. The tuple and fixed-array by-value ABI limitations apply.

Safe code may mention raw pointer types, bind/copy/pass/return raw pointer
values, call `extern` functions whose signatures contain raw pointers,
construct typed null pointers, and test pointers for null. Safe code may not
dereference, write through, offset, or cast raw pointers.

`(ptr-addr-of place)` is the unsafe source operation for deriving a raw
pointer from compiler-known storage. The v1 `place` grammar is deliberately
narrow: whole local or parameter storage, struct-field paths rooted in that
storage, and fixed-array element paths rooted in that storage. The result is a
raw pointer value; it carries no checked borrow, lifetime pin, provenance,
aliasing, or move restriction. The caller is responsible for keeping the owner
storage live and valid for every later raw-pointer use.

#### 3.4.1 Arena-owned `(Box T)` indirection

`(Box T)` is an explicit, safe, arena-owned indirection type. A box value is a
pointer-shaped owning handle to storage that contains one `T`, allocated in
the active arena. It is the source-level escape hatch for recursive aggregate
layouts under the default inline aggregate contract.

`(Box T)` is distinct from every other pointer-like surface:

- `(Ptr T)` / `(MutPtr T)` are unsafe, nullable, copyable raw addresses for
  FFI/runtime work. They do not own the pointed-to value.
- `(& r T)` / `(&mut r T)` are non-owning checked references tied to an owner
  lifetime or arena.
- `(Box T)` owns the allocated `T` value. The box handle is move-only, not
  copyable, and its storage is reclaimed only with the arena that owns it.

Box type syntax is a built-in type constructor like `(Array T N)`,
`(Tuple ...)`, and raw pointer types. It is not source-level generics. The
parser must reject malformed box types such as `(Box)`, `(Box A B)`, and
`(Box T extra)` with a source-located type diagnostic.

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
box. Subsequent use of the projected value is still governed by the move
rules: copyable `T` values may be copied out, but moving a move-only `T` out
of a box through `box-get` is an aggregate path move and is rejected. Use
`(box-take b)` to destructively move the boxed value out; this consumes the
box handle, and subsequent use of that handle is rejected by the move checker.

`(set! (box-get b) value)` mutates the value stored in a box when `b` is a
storage place such as a local, parameter, or supported aggregate path. The
value must typecheck against the boxed `T`, must satisfy the same
region/reference store checks as other storage-place mutations, and the box
handle itself is not moved. A mutable borrow of `(box-get b)` borrows the
boxed storage under the ordinary lexical exclusivity rules.

Examples:

```lisp test=ignore name=box-recursive-list reason=illustrative
(defenum ListI64
  (ListNil)
  (ListCons i64 (Box ListI64)))

(define one-two : ListI64
  (ListCons 1 (box (ListCons 2 (box ListNil)))))
```

```lisp test=ignore name=box-recursive-tree reason=illustrative
(defenum Tree
  (Leaf i64)
  (Node (Box Tree) (Box Tree)))

(define small-tree : Tree
  (Node (box (Leaf 1)) (box (Leaf 2))))
```

```lisp test=ignore name=box-get-copyable-field reason=illustrative
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
- Layout: `(tag : u64, payload ...)` — tag word + maximum payload size across
  all variants.
- Nullary variants have no payload; they occupy only the tag word.
- Variant constructors and patterns may be written as unqualified names
  (`Red`, `(Some x)`) or as enum-qualified names (`Color.Red`,
  `(Option.Some x)`). Duplicate variant base names are allowed across
  different enums when uses are enum-qualified; duplicate variant names
  within the same enum are rejected.
- Pattern matching via `match` (§5.13) is exhaustive and type-checked.
- Enum values are heap-allocated when returned from functions (to avoid
  variable-sized stack slots).
- Module-qualified imported variants use the same dotted member form, for
  example `json.Json.Null` through an alias or `pkg.json.Json.Null` through a
  visible full module path. `Color::Red` is not TypeLisp syntax.

#### 3.5.2 Structs (product types)

```lisp test=check name=struct-declaration
(defstruct Point
  (x i64)
  (y i64))
```

- Layout: fields stored sequentially with natural alignment per field. No tag
  word.
- Constructor syntax: `(Point 10 20)` — a call-like expression.
- Field access: `(struct-get p x)` generates a GEP+load at the field's byte
  offset. When the leading dotted segment is a local binding, `p.x` is sugar
  for `(struct-get p x)`, and chains such as `p.inner.x` nest the same access.
- Field mutation: `(set! (struct-get place x) value)` writes one field in
  place and returns `unit`. `(set! place.x value)` is the corresponding local
  dotted sugar.
- Dotted numeric segments such as `p.0` are not index sugar; use `tuple-ref`
  or `array-ref`.
- Structs are heap-allocated when returned from functions (same rule as
  enums).
- Not valid as global variables.

#### 3.5.3 Default inline aggregate layout and `(:repr c)` compatibility

Ordinary TypeLisp structs use a stable C-compatible inline field layout by
default. Fields are stored in declaration order. Each field starts at the next
offset aligned to that field's natural alignment, and the total struct size is
rounded up to the maximum field alignment. Empty structs have size 0 and
alignment 1.

```lisp test=ignore name=default-struct-layout-syntax reason=illustrative
(defstruct Stat
  (size i64)
  (mtime i64))
```

The metadata form `(:repr c)` may appear immediately after a struct name and
before the first field:

```lisp test=ignore name=repr-c-struct-compat-syntax reason="compatibility metadata"
(defstruct CompatStat
  (:repr c)
  (size i64)
  (mtime i64))
```

For struct layout, `(:repr c)` is a compatibility/ABI-intent marker and does
not change field offsets, size, or alignment; omitting it does not select a
different layout. Metadata forms must appear before all fields; a metadata
form after a field is rejected. Duplicate `:repr` metadata is rejected.
Unknown metadata keys and unknown representation names are rejected. Cleanup
ownership metadata is specified separately in section 4.7.1 and is not a layout
contract. `packed`, `(:repr packed)`, and equivalent packed-layout spellings
are reserved and rejected.

TypeLisp enum layout is a tagged union by default. The tag is an 8-byte
integer at offset 0. Variant payload storage starts at offset 8; payloads are
placed in variant declaration order using the same natural-alignment rule as
struct fields. The enum size and alignment are the maximum aligned storage
needed by any variant. Payload offsets are available to compiler layout logic
through the inline layout query path.

Layout queries use these default inline layouts for ordinary structs and
enums. Target C ABI call/return lowering for by-value aggregate externs is
separate: the backend must still validate the target ABI classes it supports
before lowering an extern call or return. A source layout being stable does
not by itself mean every aggregate shape is accepted in every external ABI
position. The Windows x64 C ABI path accepts default-layout enum aggregates
by classifying a synthetic aggregate view consisting of the 8-byte tag
followed by the max-sized payload union. Tag-only enums are scalar register
aggregates; payload enum arguments larger than 8 bytes are passed by hidden
reference and payload enum returns larger than 8 bytes use sret. The Linux
x86_64 System V C ABI path uses the same synthetic enum view and classifies
it with the shared System V aggregate classifier: register-class enum
arguments/returns use the normal integer/SSE register slots, larger enum
arguments are MEMORY-class stack copies, and larger enum returns use sret.

Supported targets use an x86_64 data model: fixed-width integer and floating
types use their explicit sizes; `bool` and `char` are one byte; raw pointers
are 8 bytes with 8-byte alignment on both Linux x86_64 System V and Windows
x64. If future targets need different pointer sizes or alignments, layout
queries are target-sensitive compile-time results and tests must either pin
the target or assert the target-specific values.

### 3.6 Type aliases

There are no explicit type aliases. Identifiers naming enums or structs are
resolved to their nominal types during type checking.

### 3.7 Abstraction policy: comptime generation, not generics/traits

TypeLisp has no Rust-style source-level generics, traits, interfaces, `impl`
blocks, or generic type constructors such as `Option<T>` and `Result<T,E>`.
There are no trait objects, vtables, or runtime type-erased dispatch.
Generic-looking top-level forms are reserved only to produce a diagnostic
that points users at comptime-generated concrete declarations.

Reusable abstractions are built by compile-time code that inspects type
values — compile-time metadata such as `(type T)` and `(type-key (type T))` —
and emits ordinary concrete `defstruct`, `defenum`, `define`, and related
implementation declarations. Declaration generation is expressed as
declaration-emitting `defmacro` declarations (section 3.7.1): `: Module` for
generated module families bound by `import`, and `: Decls` for declarations
spliced into the current module.

#### 3.7.1 Typed expression macros

Macros are compile-time expression transformers. They are declared with
`defmacro`, checked through a function-type-like `macro` type, and expanded
before ordinary runtime typechecking and lowering. A macro is not a runtime
value and cannot be stored in variables, passed to functions, placed in
fields, or called indirectly.

Macro signatures use ordinary produced types, with `Expr` as an explicit
wildcard capture, `ExprClause` as a general bracket-clause capture, and
`ExprBindingClause` as a let-like binding-clause capture. An ordinary operand
slot states the type that the operand expression must produce at the call
site. For example, a macro with type `(macro (bool bool) bool)` takes two
operand expressions that must each typecheck as `bool` and produces an
expression that must typecheck as `bool`. A fixed slot declared `Expr`
accepts any ordinary operand expression without checking its produced type
before expansion; the macro receives the syntax as an `Expr`, and ordinary
typechecking validates the expanded expression afterward. The macro may call
`(expr-type expr)` to query the captured expression's produced type when
ordinary typechecking can determine it; the query does not evaluate the
runtime expression and reports a macro-time diagnostic for syntax that cannot
be typed in the caller context.

A fixed slot declared `ExprClause` accepts exactly one bracket-list operand
`[first second]`, where `first` and `second` are ordinary expressions
preserved as syntax. The bracket form is valid only in macro call operands;
it is not a general expression, and ordinary calls or non-bracket macro slots
reject it with a source-located diagnostic. Empty clauses, one-element
clauses, and clauses with more than two elements are rejected.

A fixed slot declared `ExprBindingClause` accepts exactly one binding-clause
operand, either `[name init]` or `[name : Type init]`. The `name` must be a
source identifier and is preserved as the user-facing binding name. The
optional type annotation and initializer are preserved as syntax; the type
annotation is not resolved before macro expansion. These operands are
distinct from `ExprClause`: `[x : i64 1]` is accepted only for
`ExprBindingClause`, while `ExprClause` remains exactly `[expr expr]`.

A fixed slot declared `type` accepts a concrete compile-time type operand. It
may carry the validation-only kind constraint described in section 3.7.1.3,
for example `[T : type (:kind struct enum)]`. This is a constraint on a macro
operand, not a source-level type parameter or generic type variable.

A fixed slot declared `Module` is a by-name module strategy operand. The
operand must be an imported module alias visible at the call site or a
visible dotted module identity; unresolved names and legacy slash-qualified
names are diagnostics at the operand span. The macro body receives the
resolved canonical module identity as a compile-time `String`. `Module`
operands are not runtime values, are not first-class macro values, and cannot
be variadic.

A final slot may be variadic, written `T ...`. For ordinary `T`, the macro
body receives the remaining operands as an `ExprList`; for `Expr ...`, they
are captured without per-operand produced-type checks. For `ExprClause ...`,
every remaining operand must be a two-expression bracket clause and the macro
body receives an `ExprClauseList`. For `ExprBindingClause ...`, every
remaining operand must be a binding clause and the macro body receives an
`ExprBindingClauseList`.

As the one user-defined mixed-shape exception, a non-final
`ExprBindingClause ...` slot consumes the maximal consecutive prefix of
binding-clause operands and may be followed by one or more ordinary operand
slots. A non-bracket operand ends the prefix; a bracket operand in the prefix
must be a valid binding clause and otherwise produces the focused
`ExprBindingClause` diagnostic. Other non-final variadic kinds are rejected
at the macro declaration because their split point would be ambiguous.

The implicit-prelude `for` macro uses the ordinary mixed-shape signature
`[bindings : ExprBindingClause ...] [body : Expr ...]`. It validates a
non-empty binding prefix and body in checked-in stdlib source. There is no
macro-name or declaration-identity exception in parser, expansion, or
typechecking; a renamed copy of the declaration has the same semantics.

Macro bodies can build expression literals with `expr-bool`, `expr-int`,
`expr-string`, and `expr-var`. `expr-binary-data` builds an opaque `(Array u8)`
static payload from a compile-time string, without materializing array-literal
syntax. `expr-struct-get` builds a field access whose
field token is computed during macro CTFE, `expr-tuple-ref` builds a tuple
element access whose index is computed during macro CTFE, and
`expr-struct-set` builds the matching field assignment expression.
`expr-mut-borrow` builds an inferred-lifetime `(&mut place)` expression;
`expr-list-empty` and `expr-list-cons` build ordered argument lists; and
`expr-call` builds an ordinary call from a callee expression and that list.
`expr-mut-call0`, `expr-mut-call1`, and `expr-mut-call2` are compact
fixed-arity builders that take a callee expression, a place, and zero, one, or two
ordinary captured expressions respectively. They build the same ordinary call
with an inferred `(&mut place)` first argument without requiring a temporary
argument-list value.
`expr-list-fold-if(items, when-true, when-false, continue-on-true)` builds one
right-associated `if` chain from a dense `ExprList`: every item is a condition,
and `continue-on-true` selects whether the accumulated suffix belongs in the
true or false branch. `expr-clause-list-fold-if(items, missing-final,
else-not-final)` performs the corresponding `ExprClauseList` fold: a final
`else` supplies the initial result, a missing final `else` yields
`missing-final`, and a non-final `else` yields `else-not-final`. These are
generic macro sequence operations, not macro-name hooks; user-defined macros
may use them to construct iterative syntax without recursively emitting macro
calls. Each consumed input charges the shared deterministic CTFE fuel budget.
The generated program typechecks the resulting borrow and call normally, so a
mutable-borrow receiver must still be a caller place and every supplied
argument is evaluated once in source order.
`pattern-wildcard`, `pattern-binding`, `pattern-variant`,
`pattern-list-empty`, `pattern-list-cons`, `pattern-list-bindings`, `match-arm`,
`match-arm-list-empty`, `match-arm-list-cons`, and `expr-match` build
generated match expressions from computed pattern names and payload bindings.
`pattern-binding-typed` adds captured type syntax to a binding pattern.
`expr-resource-scope`, `expr-let-scope`, and `expr-set-var` build scopes and
assignments whose binding identity is supplied at macro time.
`expr-begin-unit`, `expr-not`, and `expr-while` provide the remaining generic
statement-loop composition used by source macros. `syntax-name-fresh` gives
computed text a reusable fresh syntax identity: builders that bind or refer to
that returned value preserve the identity even if caller source uses the same
spelling.
`pattern-list-bindings(prefix, count)` builds a dense ascending list of binding
patterns named `prefix0` through `prefix<count - 1>`; a negative count is a
compile-time diagnostic.
Generated matches are still checked by the ordinary typechecker for variant
resolution, payload arity, arm result types, and exhaustiveness after macro
expansion.

Macro bodies can inspect variadic expression captures with `expr-list-length`
and `expr-list-nth`. `expr-list-type-nth` requires a captured type-literal
operand and resolves it as a type value for reflection. Dense capture lists are
indexed from zero; empty lists therefore have length `0` and reject every list
item access. They can
inspect clause captures with `expr-clause-first`, `expr-clause-second`,
`expr-clause-list-length`, and `expr-clause-list-nth`.
`expr-clause-list->expr-list` converts a clause list back into a list of
bracket-clause operand syntax for explicit splicing into recursive macro
calls. They can inspect binding-clause captures with
`expr-binding-clause-name`, `expr-binding-clause-has-type?`,
`expr-binding-clause-type`, `expr-binding-clause-init`,
`expr-binding-clause-list-length`, and `expr-binding-clause-list-nth`.
`expr-binding-clause-list->expr-list` converts a binding-clause list back
into bracket-clause operand syntax for explicit splicing into macro calls.
Cons-list helpers such as `expr-list-head` and `expr-list-tail` are not part
of the public macro ABI.

Macro bodies can inspect module strategy operands with `module-name` and
`module-export-macro?`. `module-hook` validates that the strategy module
exports the named hook macro and builds an `Expr` that calls that hook by its
canonical module identity; a missing hook is diagnosed as
`typecheck: strategy module <module> does not export hook <name>`. This is
by-name hook dispatch for generated code, not a macro value that can be
stored or called indirectly.

`Expr`, `ExprList`, `ExprClause`, `ExprClauseList`, `ExprBindingClause`,
`ExprBindingClauseList`, `Pattern`, `PatternList`, `MatchArm`, and
`MatchArmList` are compile-time-only types. They are valid in macro bodies
and explicit `(comptime ...)` helper code, but they have no runtime
representation. The same rule covers `type` values, declaration metadata, and
generated identity keys: none of them has a runtime representation. The
compiler tracks the checked produced type of each `Expr` internally; there is
no source-level `Expr<T>`. Constrained `type` operands remain concrete
macro-time values and do not introduce generic macro types.

Macro bodies build expression values with quote forms. The reader accepts
both prefix shorthand and the equivalent list-headed forms:

```lisp test=ignore name=macro-quote-surface reason=illustrative
'form        ; (quote form)
`form        ; (quasiquote form)
,expr        ; (unquote expr), valid inside quasiquote
,@expr       ; (unquote-splicing expr), valid in quasiquote list positions
```

`quote` produces an `Expr` for the template without evaluating it.
`quasiquote` produces an `Expr` while evaluating `unquote` operands as
compile-time `Expr` values and inserting their checked AST. `unquote-splicing`
evaluates to an `ExprList` and splices that list into the surrounding
template list. Clause lists and binding-clause lists do not splice
implicitly; use `expr-clause-list->expr-list` or
`expr-binding-clause-list->expr-list` when a macro needs to splice generated
bracket operands. `unquote` and `unquote-splicing` outside quasiquote are
rejected.

Captured string-literal syntax is inspectable through
`(expr-string? expr)` and `(expr-string-value expr)`. The predicate is false
for expressions that merely produce `String`; the extractor rejects those
non-literals with a macro diagnostic. `(comptime.string-slice text start len)`
provides bounded byte-range parsing over compiler-owned comptime strings.

The source surface is:

```lisp test=ignore name=macro-defmacro-surface reason=illustrative
(defmacro (and2 [lhs : bool] [rhs : bool]) : bool
  (expr-if lhs rhs (expr-bool false)))

(defmacro (all [first : bool] [rest : bool ...]) : bool
  ;; `first` is an Expr; `rest` is an ExprList.
  (fold-bool-and first rest))

(defmacro (pick-first [arms : ExprClause ...]) : i64
  (if (= (expr-clause-list-length arms) 0)
    (expr-int 0)
    (let [arm : ExprClause (expr-clause-list-nth arms 0)]
      `(if ,(expr-clause-first arm)
         ,(expr-clause-second arm)
         ,(expr-int 0)))))
```

The canonical binding types for those declarations are `(macro (bool bool)
bool)`, `(macro (bool bool ...) bool)`, and `(macro (ExprClause ...) i64)`.
The `defmacro` operand list names the macro body's compile-time parameters
and their call-site produced types. Fixed ordinary operands bind as `Expr`,
fixed `ExprClause` operands bind as `ExprClause`, fixed `ExprBindingClause`
operands bind as `ExprBindingClause`, fixed `Module` operands bind as
canonical module identity `String` values, variadic ordinary operands bind as
`ExprList`, variadic `ExprClause` operands bind as `ExprClauseList`, and
variadic `ExprBindingClause` operands bind as `ExprBindingClauseList`. The
macro body must typecheck as `Expr`, and the produced fragment must
post-expand typecheck as the declared result type.

Typed expansion has three checks:

1. The macro call site is checked from the macro signature before expansion.
   Ordinary operand type errors are reported at the operand source span;
   `Expr` operands are wildcard syntax captures and skip the produced-type
   check; `ExprClause` operands must use `[expr expr]` syntax;
   `ExprBindingClause` operands must use `[name expr]` or
   `[name : Type expr]` syntax.
2. The macro body is checked as compile-time TypeLisp over the macro-only
   syntax types.
3. The expanded expression is checked again by the ordinary typechecker as a
   safety net; failures are compiler or macro diagnostics with expansion
   spans.

Declaration-emitting macros extend `defmacro` with two module-scope result
categories:

- `: Module` means the macro body produces exactly one `(module ...)`
  declaration. It is called only through import syntax:
  `(import (macro args) as alias)`, `(import (macro args).*)`,
  `(import (macro args).item)`, or `(import (macro args).item as alias)`.
  A generated module has no inherent final identity segment, so bare
  `(import (macro args))` is rejected. `as` binds a qualified module alias;
  `.*` imports every item unqualified; `.item` imports exactly one item
  unqualified and may combine with `as` to rename that item. `.*` cannot
  combine with `as`. The macro operand is always the nested call form; a flat
  import such as `(import vector i64)` is not a module macro import. The
  generated module participates in ordinary dot-qualified lookup,
  typechecking, lowering, tests, docs, and diagnostics after expansion.
  When generated module or declaration output itself contains a module-macro
  import, operands whose callee parameter is `: type` may name a captured
  outer `: type` macro operand by its generated template name. Expansion
  substitutes the captured concrete type before resolving that nested import;
  this does not introduce source-level type parameters.
- `: Decls` means the macro body produces a declaration list. A call at
  module scope, for example `(point-vec i64)`, is replaced by those
  declarations at that exact location. One returned declaration is inserted
  directly; multiple returned declarations are treated as if wrapped in an
  implicit `(begin ...)`. No import binding is created. This form is for
  one-off helper declarations; module-shaped reusable families should prefer
  `: Module`.

Expression macros are the expression-position form above: the declared result
is the produced expression type that the expansion must satisfy after
splicing, while the macro body itself constructs `Expr` syntax. `: Expr` is
the wildcard expression result for macros that intentionally defer all
produced-type checking to the expanded form. `: Module` and `: Decls` are not
runtime types, cannot appear in value positions, and are valid only as macro
result annotations.

The legacy `comptime-decl` and `comptime-decls` source forms are removed.
Parsers reject either spelling in declaration or expression position with a
migration diagnostic directing callers to a `defmacro` whose result is
`Module` or `Decls`.

Module-scope expansion runs before ordinary typechecking:

1. Parse the module, collect source imports, and resolve/load imported
   modules.
2. Build the macro namespace from local and imported `defmacro` declarations.
3. Expand module-scope macro imports and `: Decls` calls. If expansion emits
   new imports, resolve those imports and repeat this step to a fixed point.
4. Recurse into generated modules, then typecheck the fully expanded module.

The macro must be visible in the ordinary macro namespace: a local macro in
the same module regardless of source order, an imported macro referenced
through its provider qualifier, or a qualified macro name such as
`(stdlib.vector.vector i64)`. Bare macro names resolve only to local
declarations or the implicit core macro prelude. In particular, importing
`stdlib.vector` does not make bare `(vector i64)` call `vector.vector`; callers
must write `(vector.vector i64)` (or use the explicitly bound provider alias).
A macro with `: Module` used
outside `import`, a macro with `: Decls` used in expression position or
import syntax, and an expression macro used at module scope are diagnostics.

Two unqualified generated module imports, whether through `.*` or `.item`,
that bring in the same name create the same kind of namespace collision as
hand-written imports. The diagnostic should name both generated module
identities and suggest qualified access through an explicit alias.

Generated module identity and deduplication are keyed by the canonical macro
module identity, macro name, and evaluated argument-key strings. Each
argument key is a compile-time `String`: type operands key by resolved type
identity through `type-key`; `Module` operands key by the resolved canonical
strategy module identity, so an alias and the corresponding visible full
module path deduplicate to the same generated module; non-type comptime
arguments use stable compiler-owned keys or explicit generator-defined string
keys. `type-key` strings are opaque inputs to the identity and must not be
parsed by user programs, and direct runtime observation of identity metadata
is rejected. Generated identities always use canonical module identities,
never import aliases or source-relative paths.

Each generated declaration has a stable identity: the generating macro's
canonical module identity and name, the argument keys, and the generated item
name — the nominal type name for a `defstruct` or `defenum`, the value or
function name for a `define`. Repeated generation with the same identity is
idempotent only when the new output is structurally the same declaration
after normalizing spans, doc comments, and non-semantic formatting; the
compiler reuses the existing declaration and does not create a second
namespace item. Repeating the same identity with a different declaration
kind, signature, field/variant shape, body, or namespace effects is an
incompatible-duplicate diagnostic. Different generated identities that bind
the same visible value/type/constructor/variant name are ordinary duplicate
namespace errors, with the generated keys included in the diagnostic.

Generated declarations enter the same namespaces as hand-written
declarations: `defstruct` binds the nominal type, struct constructor, and
fields according to the ordinary struct rules; `defenum` binds the nominal
type plus variant constructors and patterns according to the ordinary enum
rules; `define` binds the ordinary value/function namespace item. After
insertion, generated declarations participate in symbol collection,
typechecking, lowering, documentation extraction, tests, and diagnostics like
source declarations. Generated functions and constructors lower to stable
symbols derived from the canonical module identity plus declaration identity;
display names are deterministic and collision-free within the TypeLisp
module/declaration identity model, with no further cross-run ABI promise.
Documentation tools show generated declarations when they are part of the
public API and include generated-origin metadata rather than treating them as
compiler internals.

Diagnostics for generated declarations report the most useful source
locations: the macro call or import site, the generated declaration span when
available, and the generated identity key. Type errors inside generated
declarations point at the generated declaration and include an expansion
stack back to the call site. Duplicate diagnostics show both the existing
generated identity and the conflicting request. When specialization rebuilds
source-authored generated metadata, it uses a concrete generated payload span
when available, otherwise a metadata-argument span, retains the owning source
path, and reports generated declaration and identity context as diagnostic
notes.

Collection modules that expose generated-module surfaces must keep their
identity keys stable and must not rely on compiler-private generator names or
marker payloads. Hashmap support is stdlib-owned: declaration-emitting module
macros provide the public `(hashmap K V)` surface. `String` key maps support
borrowed lookup/contains/remove wrappers; `i64` key maps use scalar keys
directly. Aggregate-key support, where provided by a stdlib family, derives
deterministic hash/equality from declaration-order struct fields, enum variant
tag plus declaration-order payloads, tuple elements, or fixed-array elements.
Supported leaves are unit, `bool`, `char`, fixed-width integers, and `String`;
structs, enums, tuples, and fixed arrays may nest those finite structural
members recursively when the complete key is cloneable. Unsupported key shapes
must be rejected by the shared stdlib hash/equality policy instead of using
source-level traits, implicit `Hash`/`Eq` bounds, runtime type IDs, or address
hashing. Generated hashmap-style families may also
expose borrowed-value lookup helpers such as `*-get-value-borrowed`. These
helpers are independent from borrowed-key lookup: the key path controls
whether lookup can inspect a borrowed key without copying it, while
borrowed-value lookup returns a lifetime-parameterized result whose found
branch borrows the map-owned value and is invalidated by map mutation,
removal, resizing, or rehashing. Stdlib Option/Result and collection families
reuse this identity and duplicate policy rather than inventing
family-specific generation paths.

#### 3.7.1.1 Comptime purity for macros and generated declarations

`defmacro` bodies and explicit `(comptime ...)` code are safe compile-time
TypeLisp. The checked comptime path is a deterministic transformer over
compiler-owned syntax and metadata, not a way to perform host I/O or call
target FFI during compilation.

The purity rule is direct and transitive through helpers reachable from the
macro body:

- `(unsafe ...)` blocks, unsafe declarations, raw-pointer operations,
  low-level FFI bridge forms, direct syscalls, process entry state, and host
  CPU queries are rejected.
- `extern` declarations and references are rejected, including helper calls
  that reach an extern.
- The host-facing stdlib module families `io`, `fs`, `process`, and `env` are
  off-limits in comptime paths. This covers both explicit qualified module
  references and imported helper bodies that reach their extern/unsafe
  implementation. `random` helpers are not banned as a module family, but any
  system-seeded or host-facing implementation path is rejected by the same
  extern/unsafe rule.
- Allocation through the active compiler arena is allowed. Pure
  CTFE-supported helpers such as string equality/concatenation, byte-range
  string slicing, string length, `int->string`, layout/reflection queries, and the
  `Expr`/`ExprList`/`ExprClause` constructor and inspector surface are
  available.
- CTFE lexical `let` bindings may be updated with `set!` and used by `while`.
  This is compile-time-local mutation only: assignments store only CTFE values,
  cannot address runtime places, and every loop iteration shares the enclosing
  deterministic fuel budget. A non-terminating loop reports the normal
  compile-time evaluation-limit diagnostic.
- Macro and generator code may call `(comptime-error message)` where
  `message` is a compile-time `String`. It returns `never`, aborts the
  current CTFE expansion/evaluation, reports `message` at the call
  expression, is a pure deterministic CTFE helper, and is rejected if it
  reaches runtime lowering.

Declaration-emitting macro output is different from the macro execution path:
after a pure `: Module` or `: Decls` transformer returns syntax, the expanded
declarations are checked as ordinary runtime declarations. Generated output
may therefore contain explicit `(unsafe ...)` runtime blocks and
`(unsafe decl)` wrappers, and those forms are accepted or rejected by the
same unsafe-context rules used for hand-written declarations.

Scalar CTFE supports finite `f64` literals and finite `f32` values produced
by context or explicit precision casts. The ordinary float `+`, `-`, `*`,
`/`, unary negation, and comparison operators are supported when both
operands have the same CTFE float kind; `f32` arithmetic rounds results
through binary32. Float literal text is parsed deterministically from the
source grammar, folded results are serialized through the compiler-owned
shortest round-tripping formatter, and optimizer folding uses the same
parse/format helpers. CTFE rejects float division by zero deterministically
and rejects any non-finite float literal, cast result, arithmetic result, or
unary result. Optimizer constant folding follows the same finite-only
materialization policy: division by zero and non-finite folded results are
not folded, so runtime behavior stays the generated machine-code behavior for
those expressions. Signed zero is finite and may be parsed, folded, and
emitted normally. Lowered IR/backend float constants carry explicit IEEE-754
bit payloads instead of decimal text: `f64` uses the full 64-bit binary64
payload, while `f32` stores the low 32 binary32 bits in the same payload
field. Assembly/object emission writes those bits directly (`.quad` for
`f64`, `.long`/4-byte object records for `f32`) rather than reparsing decimal
strings. There is no portable source syntax for infinities or NaNs, and CTFE
does not materialize non-finite values.

The rule applies to the comptime path, not to every runtime call of the same
function. A helper that is safe along the macro/comptime call graph may
remain runtime-callable elsewhere; a helper reached from a macro is rejected
if that reachable body depends on unsafe, extern, or banned host facilities.
Diagnostics should point at the offending reference and include the reachable
reference path, for example `macro -> helper -> extern-name`.

Expansion runs after parsing/import loading and before runtime typechecking.
The expander resolves a list head in the macro namespace first; if no macro
is found, the form is left for ordinary value-call checking. A module may not
declare a local value/function and a local macro with the same unqualified
name. Macro expansion is hygienic (section 3.7.2); parser-owned
guard/conditional forms such as `when`, `unless`, and `cond` introduce no
user-visible bindings.

Local `defmacro` declarations are visible throughout their module regardless
of source order, matching functions, values, and types. A macro may therefore
be called before its declaration, and one macro may expand to a call of
another macro declared later in the same module. Declarations produced by
`: Decls` or `: Module` macros participate in the module-wide macro table for
subsequent fixed-point expansion and ordinary typechecking, but a macro
emitted by a declaration-emitting macro is not visible while evaluating the
macro that emits it.

#### 3.7.1.2 Stdlib-owned comptime syntax and reflection types

The public macro/comptime syntax and reflection surface is owned by the
stdlib, not by ad hoc compiler-only handles. The declarations live in the
stdlib comptime module and are ordinary `defenum`/`defstruct` declarations,
but the compiler treats them as **well-known types**: their module identity,
type names, variant names, field names, field order, arity, payload types,
and compile-time-only behavior are pinned by this SPEC and verified when the
stdlib is loaded. The marker is the verified `stdlib.comptime` module/type
contract.

The well-known set is:

- Syntax values: `Expr`, `ExprList`, `ExprClause`, `ExprClauseList`,
  `ExprBindingClause`, `ExprBindingClauseList`, `Pattern`, `PatternList`,
  `MatchArm`, and `MatchArmList`.
- Reflection values: `TypeInfo` plus the associated field, variant, payload,
  parameter, and sequence types needed to represent the section 5.17
  reflection data as ordinary TypeLisp values.

`Expr` is the public source-expression AST used by macros. It mirrors source
expression forms, not checked compiler internals: literals,
variable/reference names, calls, blocks, control-flow expressions, aggregate
constructors, pattern forms where needed by macro operands, quote/quasiquote
forms, and other section 5 source expressions may appear as variants. It must
not expose typed AST nodes, IR values, CFG blocks, liveness data, register
allocation state, backend object records, or any representation that
optimizer/backend work needs freedom to change.

`TypeInfo` is the public, stable reflection value form of section 5.17. It
may represent builtin types, arrays, functions, tuples, structs, enums, and
the reserved/partial shapes that `type-kind` can classify. It exposes
language metadata such as nominal identity, fields, variants, payloads,
parameters, and opaque `type-key` identity. It must not expose runtime type
objects, method tables, optimizer facts, layout internals beyond the explicit
layout-query surface, or compiler symbol-table handles.

`ExprList`, `ExprClauseList`, `ExprBindingClauseList`, `PatternList`,
`MatchArmList`, and reflection sequences are dense, length-indexed sequence
wrappers over arrays (or an equivalent compiler-verified dense
representation). Their public API is length/index/iteration-oriented;
`pattern-list-bindings` provides dense computed binding construction.
Recursive cons cells are not part of the public contract, and cons-list
bridge names are not part of the public macro ABI.

The public enum variant policy follows the dotted qualified variant
direction: stdlib declarations use short variant names such as `Var`, `Call`,
`Struct`, or `Enum`, and source code refers to them through enum-qualified
names such as `Expr.Var` and `TypeInfo.Struct`.

Spans, lexical context, expansion scopes, and provenance are compiler
metadata attached to syntax values, not ordinary public fields on every
`Expr` variant. Conceptually this is a side table keyed by compiler-owned
node identity. The compiler must preserve that metadata through stdlib-typed
manipulation:

- `quote` and `quasiquote` allocate fresh syntax values whose provenance
  points at the template source span and macro definition context.
- `unquote` and `unquote-splicing` insert existing syntax values with their
  existing provenance and lexical context.
- Public constructors allocate fresh syntax values and attach the constructor
  call span as fallback provenance unless a dedicated provenance-preserving
  helper is used.
- Transformations that rebuild syntax from an existing node should preserve
  the original node's user-facing provenance when that is the least
  surprising diagnostic source.

Debug or diagnostics helpers may expose rendered spans or printable
expression forms, but source code cannot forge lexical contexts, expansion
scopes, or raw node identities. Any operation that feeds an `Expr` back into
the expander must carry valid compiler provenance. This rule composes with
the hygiene rules in section 3.7.2: quote/quasiquote template identifiers
carry the macro definition context, and unquoted caller syntax keeps its
use-site context.

The verification rule is fail-closed. A `--stdlib-root` tree or embedded
stdlib whose well-known declarations do not match the pinned contract is
rejected before macro expansion or generated declaration evaluation. The
diagnostic should name the module/type and the first mismatch, for example:

```text
typecheck: stdlib well-known type mismatch for stdlib.comptime.Expr: expected variant Call at index 4
```

Targeted diagnostics cover at least these cases:

- Missing or renamed `Expr` / `TypeInfo` variants.
- Variant payload arity or type mismatch.
- `ExprList` or reflection sequence declarations that expose a cons-list
  shape instead of the dense sequence contract.
- Runtime-usable declarations for comptime-only types.
- A stale stdlib root whose well-known declaration contract does not match
  the compiler.

The compiler may use the verified stdlib declarations as its real macro-time
representation. CTFE interpretation and compiled comptime execution must
observe the same source-level types and produce byte-identical expanded
declarations for the same inputs. A mismatch is a compiler bug or
stdlib-version diagnostic, not a silent fallback to a separate internal
`Expr` ABI.

#### 3.7.1.3 Constraints on macro `type` operands

A fixed `defmacro` operand whose declared type is exactly `type` may carry one
optional kind constraint after its type annotation:

```lisp test=ignore name=macro-type-kind-constraint-surface reason=illustrative-signature-fragment
[T : type (:kind i64 i32 string)]
```

The names following `:kind` are unquoted grammar names corresponding
one-to-one with the stable strings returned by `type-kind` in section 5.17.
The list must be non-empty and contain no duplicate names. A concrete type
satisfies the constraint when its `type-kind` result is one of the listed
names. Shape names such as `array`, `tuple`, `struct`, and `enum` use the same
namespace as scalar names; reserved/partial names such as `ptr`, `ref`, and
`type-var` may be named explicitly but gain no reflection operations beyond
those specified in section 5.17.

This initial vocabulary is intentionally shallow. `(:kind struct enum)` says
only that the top-level concrete type is a struct or enum. It does not prove
that every nested field is cloneable, equatable, serializable, or otherwise
supports an operation. There are no built-in `cloneable`, `equatable`, or
`serializable` constraint names, no user-declared constraint/implementation
registry, and no implicit hook lookup. A macro that needs a recursive
property must still inspect the concrete type graph during CTFE and issue a
targeted error for an unsupported nested type. A `Module` strategy operand
may still be checked explicitly with `module-export-macro?` / `module-hook` as
described above; that is separate from the `type` operand's `:kind` filter.

The constraint is legal on a fixed `type` operand of an expression, `: Decls`,
or `: Module` macro. It is not legal on a variadic operand, on `Expr`,
`ExprClause`, `Module`, or ordinary produced-type operands, or on parameters
of `define`, `lambda`, `defstruct`, or `defenum`. Only one `(:kind ...)` form
may appear on an operand. An unconstrained `[T : type]` retains its current
meaning and accepts every concrete type value. These rules keep the surface
macro-only: the operand name cannot appear as an abstract runtime type, and
generated declarations use it only after substitution with the concrete type
argument.

Constraint processing has two distinct times:

1. When a macro declaration is collected, the compiler validates placement,
   arity, and every kind name. An empty list, duplicate or unknown kind,
   additional constraint form, or constraint on an unsupported operand is a
   macro-definition diagnostic at the constraint span. Unsupported future
   spellings must be rejected rather than ignored.
2. At every macro call or generated-module import, the compiler first resolves
   each `type` operand to its concrete type, then validates its `:kind`
   constraint before the transformer body executes, before any nested
   generator CTFE can observe the operand, and before a cached generated
   module is reused. A passing operand is bound as the same concrete
   compile-time `type` value as an unconstrained operand. A failing operand
   does not run the transformer and does not create or reuse generated output.

The normal post-expansion typecheck remains mandatory. Kind constraints move
unsupported top-level shapes to the operand site; they do not by themselves
prove a generated body correct for all nested concrete types. They are also
the fact vocabulary used by the definition-time abstract macro-body checker.
For each constrained `type` operand, the checker validates executable
reflection uses once over the declared kind set. A `type-kind` equality branch
refines that set for its then/else bodies, and direct `let` aliases preserve
the operand's facts; shape-specific reflection is accepted only when every
remaining kind supports it. The checker does not infer unrelated capabilities.
Concrete transformer CTFE and the normal post-expansion typecheck remain the
safeguards for fixed-array lengths, reflection indexes, nested-type
properties, cleanup ownership, and final substitutions. Unconstrained `type`
operands retain the existing concrete-only behavior.

A failed satisfaction diagnostic must point at the concrete type operand and
name the canonical macro, parameter, rendered concrete type, and allowed kind
set. `type-key` may be included as supplementary identity information but is
opaque and must not be the only rendering of the type. For example:

```text
typecheck: macro app.scalar-eq type operand T rejects (Array i64 4): expected one of :kind i64, i32, bool
```

Definition diagnostics must similarly name the macro and operand, for example
`typecheck: macro app.bad type operand T has unknown constraint kind record`.
Nested generated-module imports use the nested call's operand span and macro
name, so an outer generator failure does not obscure which constraint failed.

An equality-like expression macro can state its finite scalar surface without
claiming a general equality trait:

```lisp test=ignore name=macro-type-kind-constraint-equality reason=illustrative-call-site-contract
(defmacro (scalar-eq
  [T : type (:kind i64 i32 i16 i8 u64 u32 u16 u8 f64 f32 bool char)]
  [left : Expr]
  [right : Expr]) : bool
  `(= ,left ,right))

;; Accepted: T resolves to i64 before transformer CTFE.
(scalar-eq i64 left right)

;; Rejected at `(Array i64 4)`, before scalar-eq executes.
(scalar-eq (Array i64 4) left right)
```

A generated serializer family can restrict its first slice to reflected
aggregate shapes while keeping format behavior in an explicit strategy
module:

```lisp test=ignore name=macro-type-kind-constraint-generated-module reason=illustrative-strategy-module-contract
(defmacro (record-codec
  [format : Module]
  [T : type (:kind struct enum)]) : Module
  (let
    [name : Expr
      (expr-var
        (string-append
          (string-append
            (string-append "generated.codec." (module-name format))
            ".")
          (type-key T)))]
    `(begin
      (module ,name)
      (define reflected-kind : String ,(expr-string (type-kind T))))))

(import stdlib.json as json)
(import (record-codec json Person) as person-json)
```

For `: Module` identity and deduplication, a constraint is signature
validation only and does not add an argument-key component. A successful call
continues to key by canonical macro identity plus the concrete `type-key` and
other evaluated argument keys described above. Reordering or narrowing the
allowed `:kind` list therefore changes which calls are accepted, not the
identity of output for a still-valid concrete argument. A rejected call has
no generated identity. The existing structural same-identity check continues
to diagnose a generator that emits different declarations for the same key.

#### 3.7.2 Hygienic expression macros

Macro expansion is fully hygienic, not gensym-only renaming. Gensym is enough
to keep a macro's temporary binder from capturing a caller identifier, but it
does not make free identifiers in a macro template resolve in the macro's
definition environment. TypeLisp guarantees both properties, so macros may
safely introduce bindings.

The compiler represents macro-time syntax internally as scoped syntax
objects: an AST node plus source span and lexical context. The source-level
type remains the single `Expr` / `ExprList` surface; scope sets, definition
contexts, and expansion marks are compiler metadata, not source-level type
parameters.

Rules:

- Each identifier has a printed name and a scope set. Name resolution uses
  the scoped identifier, not only the printed name.
- A macro declaration stores the lexical definition context in its macro
  metadata. For macros imported across modules, the serialized/imported macro
  metadata must carry enough definition-context information for template free
  identifiers to keep resolving as they did at the macro definition site.
- Identifiers that come from a quoted or quasiquoted macro template carry the
  macro definition context.
- Each macro expansion adds a fresh expansion scope to identifiers introduced
  by the template. Binding forms introduced by the template apply that fresh
  scope to their own introduced references, so generated locals can refer to
  each other without colliding with same-name caller locals.
- Syntax supplied by the caller through `unquote` or `unquote-splicing`
  preserves its use-site context. A caller expression inserted under a
  macro-introduced binder therefore still resolves to the caller binding it
  originally named, unless the caller explicitly supplied syntax that refers
  to the macro-introduced identifier through an intentional escape API.
- Nested and recursive macro expansion compose by retaining all existing
  scopes and adding a new expansion scope for each expansion step.

`quote` and `quasiquote` both produce scoped template syntax. `unquote`
evaluates to an `Expr` and inserts that expression with its existing scope
set. `unquote-splicing` evaluates to an `ExprList` and inserts every element
with its existing scope set. `unquote` and `unquote-splicing` outside
quasiquote remain syntax errors. Converting an `Expr` to printable/debug text
may drop scope details, but any operation that feeds syntax back into the
expander must keep or explicitly reconstruct lexical context.

Worked example: a macro-introduced temporary binding must not capture a
same-name user variable inside an unquoted body.

```lisp test=ignore name=macro-hygiene-temp-binder reason=illustrative
(defmacro (with-temp-plus [value : i64] [body : i64]) : i64
  `(let [tmp : i64 ,value]
     (+ tmp ,body)))

(define (main) : i64
  (let [tmp : i64 40]
    (with-temp-plus 1 (+ tmp 1))))
```

The result is `42`: the `tmp` in the macro template's `(+ tmp ...)` resolves
to the macro-introduced binder, while the `tmp` inside the unquoted caller
body keeps the caller scope and resolves to the outer `let`.

Worked example: a free identifier in a macro template resolves in the macro
definition environment even when the use site shadows the same printed name.

```lisp test=ignore name=macro-hygiene-definition-context reason=illustrative
(define (macro-helper [x : bool]) : bool
  (not x))

(defmacro (unless2 [condition : bool] [body : unit]) : unit
  `(if (macro-helper ,condition)
     ,body
     unit))

(define (main) : unit
  (let [macro-helper : bool true]
    (unless2 false (print-string "ok"))))
```

The `macro-helper` referenced by the template is the top-level function
visible where `unless2` was defined. The caller's local boolean named
`macro-helper` does not capture that reference.

Diagnostics should report source spans from the most useful user-facing
syntax: call-site spans for invalid operands and unquoted caller syntax,
template spans for invalid macro-produced forms, and an expansion stack when
an error crosses a macro boundary. Diagnostics should not expose generated
internal names except in deliberate debug output.

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

### 3.9 Region-tagged types

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
- `(Array T)` - runtime-sized dynamic buffer storage
- Enum and struct values returned from functions inside the region
- Tuple values

Scalars (`i64`, `bool`, `char`, `f64`, etc.), function values, and fixed-size
arrays are **not** region-tagged because they do not allocate through
`tl_alloc`.

A region-tagged type `(in r T)` is a **subtype** of the plain type `T` for
operations that do not escape the region: field access, `array-ref`,
`array-set!`, `match` arms, `print-string`, and function calls whose parameter
types accept `T`. It is **not** a subtype where the value would leave the
region's scope: as the result of the `with-arena` form, stored into an outer
`let` or global, captured by an escaping closure, or returned from an enclosing
function.

**Confinement rule:** Region-tagged values do not cross function boundaries.
Function parameter and return types are written without region tags; passing a
region-tagged value to a function or returning one is an escape error. There
are no region-polymorphic function types; every function type is
region-agnostic and can neither accept nor produce region-tagged handles.

### 3.10 Reference types and borrow expressions

Reference types are lifetime-bearing:

```lisp test=ignore name=reference-type-syntax reason=syntax-only
(& arena T)
(&mut arena T)
```

- `(& arena T)` is an immutable reference type to `T` tied to lifetime/arena
  name `arena`.
- `(&mut arena T)` is a mutable reference type to `T` tied to lifetime/arena
  name `arena`.
- The lifetime name is a bare identifier and matches the
  `(with-arena arena ...)` binder shape.
- Immutable references are copyable pointer/provenance values. Copying an
  immutable reference aliases the same immutable referent and does not move or
  copy the referent.
- Mutable references are exclusive, non-copying handles to the same referent.
  The checker enforces many immutable borrows or one mutable borrow for
  tracked local, parameter, and global place paths. Tracked aggregate-place
  paths conflict only when they are the same path or one is an ancestor of the
  other, so mutable borrows of disjoint sibling fields may coexist while
  overlapping whole-field, same-field, and field-element borrows are rejected.
  The same exclusivity rules apply to direct mutation of a borrowed global.
  Borrows end at their last use under the non-lexical lifetime rule below.
- Array operations accept reference receivers: `array-ref` reads through an
  immutable or mutable array reference, and `array-set!` / `array-push!` write
  through an owned array or a mutable array reference. Borrowed `str` source
  semantics are specified in section 3.11.

In function signatures, the ordinary spelling elides the lifetime name:

```lisp test=ignore name=reference-signature-elision-syntax reason="signature-only syntax example"
(& T)
(&mut T)
```

These are type forms, not borrow expressions. Expression position continues to
use `(& place)` / `(&mut place)`, so the enclosing grammar context
unambiguously selects the meaning.

Borrow expressions:

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
- Mutable borrows of scalar, register-resident by-value locals are accepted
  only as immediate call arguments. The compiler materializes a temporary and
  writes it back after the call. Binding or storing such a mutable reference is
  rejected.
- Borrow expressions are the explicit spelling. At call sites, a parameter of
  type `(& lifetime T)` may also auto-borrow an argument place under the same
  immutable borrow rules below. There is no general implicit conversion from
  `T` to `(& lifetime T)` outside typed calls, and mutable references always
  require explicit `(&mut ...)`.
- The referent type is the place's value type, except that borrowing a `String`
  place produces `(& lifetime str)`. When the place type is an arena-tagged
  wrapper `(in arena T)`, the reference type is `(& arena T)`, not
  `(& arena (in arena T))`; for `(in arena String)`, the reference type is
  `(& arena str)`.

**Borrowable places.** The checker accepts borrows of places whose
owner/provenance is statically known:

- Local bindings and function parameters.
- Global variables, including supported aggregate field and element
  projections rooted in global storage.
- Aggregate field and element projections rooted in a borrowable place. In a
  borrow expression, forms such as `(struct-get p field)`, dotted field sugar
  `p.field`, `(tuple-ref t 0)`, and array element access `(array-ref items i)`
  are treated as projections, not by-value reads.
- Arena-owned aggregate handles: `String`, `ByteBuf`, struct, enum, tuple, and
  dynamic-buffer handles allocated in the active arena. Handles with type
  `(in phase T)` infer lifetime `phase`; untagged heap handles allocated in
  the default program-lifetime arena infer the reserved lifetime name
  `program`.

The checker rejects borrows of arbitrary rvalues and temporaries whose owner
cannot be named. Bind the value first if it should have a lexical owner.

**Returned stored-reference reborrows.** A field or tuple element that stores a
reference can be reborrowed through iterator-like state. If that reborrow is
returned from a nested lexical scope, its live borrow remains attached to the
original source projection rather than the state-local field. Mutating,
growing, moving, or mutably borrowing that source projection is rejected until
the returned reference/result's last use; disjoint sibling projections remain
independent.

**Shared collection iterators.** A generated collection iterator may store an
`(& source Collection)` projection and return a result carrying an `(& source
T)` item. The iterator state and every yielded item retain a shared borrow of
the source, so reads may coexist but moving, mutating, growing, or mutably
borrowing the collection is rejected until the relevant state/result's last
use. Repeated exhausted steps return a concrete `Done` result. `String`
elements retain the language's immutable-text rule and use `(& source str)`
items under this convention.

**Lending collection iterators.** A generated mutable collection iterator may
store an `(&mut source Collection)` projection and return a result carrying an
`(&mut source T)` item. This is a lending operation: the iterator state keeps
the source exclusively borrowed, and a previously yielded item/result must be
dead before the next mutable step. The checker does not assume dynamic indexes
are disjoint. Consequently, mutation, growth, or conflicting borrows of the
collection are rejected while the iterator state or a yielded item is live;
they are accepted after the last proven use. Repeated exhausted steps return a
concrete `Done` result. `String` elements remain immutable and use `(& source
str)` items under this convention. Scalar `for` selects this protocol for a
mutable source.

**Consuming collection iterators.** A generated collection module may expose
`into-iterator` with a `(:consume)` collection parameter and `into-next` over
mutable iterator state. Construction moves the source exactly once. Each
`IntoNext.Item` owns its `T` payload; `Done` is explicit and remains stable on
repeated calls. Generated vectors keep an internal live-slot map and extract each
item through checked `array-take!`, never through `array-ref`, `clone`, or a
hidden copy. For cleanup-owning element types, backing storage contains only
constructed elements: capacity never creates spare owners. `IntoNext` is itself
cleanup-owning, so an abandoned `Item` cleans its payload, while abandoning the
`IntoIter` drains exactly the still-live, unvisited slots and `Done` is a no-op.

**Scalar `for`.** The implicit-prelude macro has the let-like form
`(for [item source] body...)`; an optional item annotation is written
`[item : ItemType source]`. One or more leading clauses are accepted. Every
source expression is evaluated once, in source order, as its iterator state is
constructed once before stepping begins. Source ownership selects the defining
module's protocol names:

- `&T` uses `iterator` and `next`, yielding shared items.
- `&mut T` uses `iterator-mut` and `next-mut`, yielding lending mutable items.
- Owned `T` uses `into-iterator` and `into-next`, yielding owned items.

Each step result is an enum with `Done` and `Item`; a missing protocol function
or variant is a source-located typecheck diagnostic. Multiple clauses use
zip-shortest semantics: later iterators are stepped only after every earlier
iterator yielded `Item`, and the loop ends as soon as any iterator yields
`Done`. Item bindings exist only in `body`, every body expression must produce
`unit`, and the whole form produces `unit`. A type annotation is checked
against the yielded owned/reference type and reports the expected and yielded
types on mismatch. Cleanup-owning iterator state uses its declared resource
cleanup scope, so early `break`, `return`, or normal exhaustion cleans
unvisited consuming items. In a zipped loop, every cleanup-owning item acquired
before a later iterator reports `Done` is cleaned exactly once, in reverse
acquisition order. The same item scopes unwind on `break`, `continue`, and
`return`; moving an item in the body transfers that responsibility and suppresses
its loop cleanup. This scalar construct is unrelated to SPMD `foreach` (section
5.15).

The scalar expansion is the ordinary checked-in `defmacro` in
`stdlib/core_macros.tl`. It uses only the public `stdlib.comptime` syntax and
reflection operations described in section 3.7.1. Compiler passes have no
native `for` planner, name predicate, declaration-identity dispatch, or hidden
AST-construction hook. Bare and explicitly qualified imports therefore execute
the same transformer body, as does a renamed copy.

**Lifetime name selection.** For `(& place)`, the checker chooses the reference
lifetime from the owner:

- A local or parameter root named `x` gives references rooted in `x` the
  lifetime name `x`.
- A global root named `x` gives references rooted in `x` the lifetime name
  `x`, unless its arena-tagged type supplies the owner lifetime below.
- A field, tuple element, or array element projection inherits the lifetime
  name of its root place.
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
borrow ends at its last use under the non-lexical lifetime rule below;
explicit borrow expressions use the same rule. An argument that is already an
`(&mut actual-lifetime T)` place weakens to `(& actual-lifetime T)` through the
same tracked shared-reborrow rewrite; this does not consume the mutable
reference, and a returned or stored shared result keeps the reborrow live until
its last use. There is no inverse `&T` to `&mut T` strengthening. Macros are
checked after expansion. Extern C ABI calls do
not participate because safe reference types are not legal C ABI parameter
values. Arbitrary rvalues and temporaries are rejected because they have no
stable lexical owner:

**Two-phase mutable call borrows.** For a typed TypeLisp call argument, an
explicit top-level `(&mut place)` passed to a mutable-reference formal reserves
exclusive access while later arguments are checked, then activates at the call
boundary. During the reservation, later arguments may perform non-mutating reads
and shared borrows of the same place when those shared borrows do not escape the
argument expression. This covers collection update idioms such as passing
`(&mut items)` and computing `array-length items` or a scalar helper call from
`(& items)` in a later argument. The reservation still rejects a second mutable
borrow of an overlapping path, moving or mutating the owner, and any shared
borrow that is returned, stored, or otherwise live across activation. The rule
is intentionally scoped to typed call argument evaluation; it is not general
non-lexical lifetime inference or delayed activation outside call arguments.

```lisp test=ignore name=auto-borrow-reject-temporary reason="negative example for immutable call-site auto-borrowing"
(define (takes-ref [n : (& value i64)]) : i64
  (read-ref n))

(define (bad-auto-borrow-temporary [n : i64]) : i64
  (takes-ref (+ n 1)))
```

Reference lifetimes may be written directly in structural container types:
fixed arrays such as `(Array (& n i64) 1)`, tuple elements, and nested
structural types. Those lifetimes are preserved through `array-ref` and
`tuple-ref`. Structural return types that expose the reference lifetime
directly, such as `(& n T)`, `(Tuple (& n T))`, and `(Array (& n T) k)`, may be
returned when the lifetime is tied to an input.

#### 3.10.1 Function-signature lifetime elision

Elision applies only to named function declarations, lambdas, and `(-> ...)`
function types, including references nested in tuples, arrays, boxes, pointers,
and nested function signatures that form part of those contracts. It does not
apply to fields, enum payloads, globals, local annotations, or nominal lifetime
argument lists; those positions require an explicit lifetime or `program`.

- Each elided input reference receives a distinct hidden, signature-local
  lifetime. Two `(& T)` inputs therefore do not imply that their callers share
  a lifetime.
- Explicit and elided input references may coexist. Distinct explicit lifetime
  names count separately; repeated explicit names count once.
- An elided output reference is assigned the sole distinct input lifetime when
  exactly one exists. The rule applies recursively to structural output types.
- If there are zero or multiple distinct input lifetimes, any elided output
  reference is rejected with `typecheck: elided reference return is ambiguous;
  write an explicit lifetime`. TypeLisp has no receiver-specific exception.
- Explicit output lifetimes preserve their existing meaning and remain required
  when an API intentionally relates multiple inputs or chooses `program`.

```lisp test=ignore name=reference-signature-elision-examples reason="examples rely on surrounding declarations"
(define (view [item : (&mut Item)]) : (& Item)
  (& item))

;; Each input is distinct, so this has no elided reference result.
(define (same? [left : (& Item)] [right : (& Item)]) : bool
  (= left.id right.id))

;; This is rejected: the result could refer to either input.
(define (choose [left : (& Item)] [right : (& Item)]) : (& Item)
  left)

;; State the relationship explicitly when it matters.
(define (choose-left [left : (& selected Item)] [right : (& other Item)])
  : (& selected Item)
  left)
```

#### 3.10.2 Lifetime-parameterized named aggregates

Named structs and enums may declare lifetime parameters with lifetime metadata
after the nominal name and before all fields or variants, alongside any other
declaration metadata:

```lisp test=ignore name=lifetime-parameterized-aggregate-declaration reason="illustrative declaration; not a standalone program"
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
  enums. It is rejected with `(:repr c)` because safe references are not C ABI
  fields.
- Lifetime metadata is independent of cleanup ownership metadata.
  Cleanup-owning structs and enums may also have lifetime parameters; the
  lifetime and cleanup contracts are validated independently.

Type-use sites supply lifetime arguments with a lifetime-only nominal type form:

```lisp test=ignore name=lifetime-parameterized-aggregate-type-use reason="illustrative type use; not a standalone program"
(define (first-ref [pair : (RefPair a b)]) : (& a i64)
  (struct-get pair left))

(define (select-ref [value : (MaybeRef a)]) : i64
  (match value
    [(SomeRef r) 1]
    [NoRef 0]))
```

`(Name a b)` is a nominal type use for the already-declared struct or enum
`Name` with lifetime arguments `a` and `b`. The arguments are lifetime names,
not type expressions. `(Array ...)`, `(Tuple ...)`, `(Box T)`, `(Ptr T)`,
`(& a T)`, and the other built-in type constructors are the only built-in
type constructors. TypeLisp rejects source-level generic type constructors,
generic functions, traits, and type parameters; `(Name T)` is not a
type-parameter application unless `T` is a lifetime name in scope.

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
- There is no lifetime subtyping or implicit lifetime coercion. Two nominal
  lifetime types are equal only when they have the same nominal identity and
  the same lifetime argument list after substitution.
- Nested uses are allowed wherever ordinary types are allowed, including
  function parameters and returns, `let` annotations, struct fields, enum
  payloads, tuple elements, arrays, boxes, pointers, and references.

Declaration lifetime parameters are substituted by position. If
`RefPair` declares `(:lifetimes a b)`, then the field type `(& a i64)` becomes
`(& x i64)` in `(RefPair x y)`, and `(& b str)` becomes `(& y str)`.
Substitution applies recursively through nested nominal types, arrays, tuples,
boxes, pointers, and references.

Struct constructor checking uses the substituted field types. A constructor
call for a lifetime-parameterized struct produces the corresponding nominal
lifetime type when every argument's stored lifetime matches the substituted
field type:

```lisp test=ignore name=lifetime-parameterized-struct-constructor reason="illustrative constructor example; not a standalone program"
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

```lisp test=ignore name=lifetime-parameterized-enum-constructor-match reason="illustrative enum example; not a standalone program"
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

```lisp test=ignore name=lifetime-parameterized-return-ok reason="illustrative return example; not a standalone program"
(define (keep-ref [value : (& a i64)]) : (RefBox a)
  (RefBox value))
```

The checker rejects returned, stored, or assigned nominal aggregate values when
any stored reference lifetime is local, scoped, unknown, untied to an input, or
otherwise shorter than the destination lifetime:

```lisp test=ignore name=lifetime-parameterized-return-reject-local reason="negative example for the nominal lifetime checker"
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

There are no runtime generics or type parameters, no trait-like bounds, and no
lifetime subtyping or coercion. Function-signature reference elision is the
only lifetime elision syntax; stored references and nominal lifetime arguments
remain explicit.

**Non-lexical lifetime rule.** A borrow lives until the last use of a
reference value that carries the borrow lifetime. This shortening applies
across expression sequences such as `begin`, `unsafe`, and `let`/resource
bodies after their bindings have been established, and across path-sensitive
`if`/`match` joins. Branch-local borrows that do not escape the taken branch
end at their last in-branch reference use; borrows that escape through the
branch result, an outer assignment, or a lifetime-parameterized aggregate
result remain live after the join until the escaping value's last use. Loop
bodies use the same local shortening for borrows created and killed within one
iteration. Facts that may be carried by an outer lifetime-bearing local or
aggregate stay live across later iterations and the loop exit until the
carried value's last proven use; when the checker cannot prove otherwise it
keeps the fact live conservatively. A plain auto-borrowed call argument whose
callee does not return or store a reference tied to the argument lifetime ends
after the call expression. If the reference result is bound, stored in a
lifetime-parameterized aggregate, returned, or otherwise remains available as a
reference value, the owner remains borrowed until that value's last proven use.

Lexical scopes are the conservative boundary for flows the checker does not
prove: function/lambda bodies, `with-arena` bodies, resource `with` bodies,
and broader SPMD/control-flow surfaces outside the checked loop-body summaries.
When a borrow crosses one of those boundaries and a later reference use remains
possible, it is kept live for the conservative scope instead of being shortened
through the join.

While an immutable borrow is live, later move-only by-value moves, `set!`
assignment to the borrowed place, and mutable borrows/mutations of the same
place are rejected by the move/borrow checker. Multiple immutable borrows of
the same place are allowed.

While a mutable borrow is live, later immutable or mutable borrows and writes of
the same tracked path, any ancestor path, or any descendant path are rejected.
Ordinary direct reads/accesses of those paths are rejected too; reads through the
mutable reference value itself are accepted. Sibling aggregate projections
are independent when the checker can name both paths, for example
simultaneous mutable borrows of two different struct fields rooted in the same
local. Lexical mutable reborrowing is supported: a nested scope may borrow a
descendant through an existing mutable reference, and the outer mutable
reference becomes usable again after that nested scope ends. Using or mutating
through the outer reference while the inner reborrow is still live is
rejected. Storage-backed mutable borrow conflicts end at their last use under
the same non-lexical lifetime rule as immutable borrows.

**Invalid escapes.** The checker rejects references that would outlive their
owner or arena:

- Returning a reference to a local, parameter stack slot, temporary, or scoped
  arena unless the lifetime-parameter rules of section 3.10.1 prove the return
  is tied to an input or arena that outlives the call.
- Assigning or storing a shorter-lived reference into a longer-lived local,
  global, aggregate field, enum payload, tuple element, or array element.
- Capturing a reference in a closure value whose use is not proven
  non-escaping by section 3.10.2.
- Letting a reference to `(in inner T)` data escape the `with-arena inner`
  body. Outer-arena references may be used inside inner arenas without gaining
  the inner lifetime.

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

(define (borrow-places [p : Pair] [items : (Array i64 4)]) : i64
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

```lisp test=ignore name=borrow-reject-return-local reason="negative example for the immutable borrow checker"
(define (bad-return-local [x : i64]) : (& x i64)
  (& x))
```

```lisp test=ignore name=borrow-reject-temporary reason="negative example for the immutable borrow checker"
(define (bad-temporary) : i64
  (let [r (& (int->string 42))]
    0))
```

```lisp test=ignore name=borrow-reject-arena-escape reason="negative example for the immutable borrow checker"
(define (bad-arena-return) : (& phase str)
  (with-arena phase
    (let [s (int->string 42)]
      (& phase s))))
```

```lisp test=ignore name=borrow-reject-closure-capture reason="negative example for the immutable borrow checker"
(define (takes-captured [x : (& n i64)]) : i64
  0)

(define (bad-capture [n : i64]) : (-> i64)
  (let [r (& n)]
    (lambda () (takes-captured r))))
```

#### 3.10.3 Closure reference captures

A lambda may capture a binding whose type contains an immutable reference when
the checker proves the closure value does not escape the reference's lifetime.
Closures that would escape reject reference captures.

A closure is **reference-capturing** when any captured binding has a type that
contains `(& lifetime T)`. Capturing `(&mut lifetime T)` is rejected. Capturing
region-tagged owner values such as `(in r String)` is governed by section 3.9.

The source function type `(-> args ... ret)` does not encode captured
lifetimes. TypeLisp therefore uses checker-only escape classification rather
than a source-visible type-level capture marker. The checker may attach
internal capture-lifetime facts to lambda expressions and local closure
bindings while checking a lexical scope. If a flow would erase those facts, the
flow is treated as escaping and is rejected. The runtime closure descriptor ABI
is unchanged.

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
non-escaping cases above. The checker rejects these flows for a
reference-capturing closure:

- Returning it from a function or lambda, because `(-> args ... ret)` carries no
  captured-lifetime marker.
- Producing it as the result of `with-arena`, resource `with`, `let`, `match`,
  or another lexical scope when that exits the lifetime of any captured
  reference.
- Assigning it into a binding whose scope is not contained within every
  captured reference lifetime, including assignment into an outer local.
- Storing it in a global/top-level slot.
- Storing it in an aggregate, tuple, fixed array, enum payload, struct field,
  or `Box`.
- Passing it to an ordinary named function, function pointer, extern, or other
  callee whose body/contract is not checker-known to invoke the closure without
  retaining or returning it.
- Capturing it inside another closure that is not itself proven non-escaping.

No public annotation marks a callee as non-escaping; unknown callees are
therefore escaping by default.

Nested arenas follow the same lifetime containment rule. A closure created in
an inner arena may capture an outer reference when the closure cannot outlive
the outer owner; leaving the inner arena is allowed only if the closure does not
also capture inner references or inner region-tagged owner values and the
remaining outer-scope uses are still proven non-escaping. A closure that captures
`(& inner T)` cannot escape the `with-arena inner` body.

```lisp test=ignore name=closure-reference-local-ok reason="illustrative reference-capturing closure; not a standalone program"
(define (read-ref [x : (& n i64)]) : i64
  0)

(define (closure-local-reference-ok [n : i64]) : i64
  (let [r : (& n i64) (& n)]
    (let [f : (-> i64) (lambda () (read-ref r))]
      (f))))
```

```lisp test=ignore name=closure-reference-return-reject reason="negative example for the reference-capturing closure checker"
(define (read-ref [x : (& n i64)]) : i64
  0)

(define (bad-return-reference-closure [n : i64]) : (-> i64)
  (let [r : (& n i64) (& n)]
    (lambda () (read-ref r))))
```

```lisp test=ignore name=closure-reference-store-reject reason="negative example for the reference-capturing closure checker"
(defstruct SavedCallback
  (run (-> i64)))

(define (read-ref [x : (& n i64)]) : i64
  0)

(define (bad-store-reference-closure [n : i64]) : SavedCallback
  (let [r : (& n i64) (& n)]
    (SavedCallback (lambda () (read-ref r)))))
```

```lisp test=ignore name=closure-reference-pass-unknown-reject reason="negative example for the reference-capturing closure checker"
(define (call-now [f : (-> i64)]) : i64
  (f))

(define (read-ref [x : (& n i64)]) : i64
  0)

(define (bad-pass-reference-closure [n : i64]) : i64
  (let [r : (& n i64) (& n)]
    (call-now (lambda () (read-ref r)))))
```

```lisp test=ignore name=closure-reference-nested-arena-ok reason="illustrative reference-capturing closure; not a standalone program"
(define (closure-nested-arena-outer-ref-ok) : i64
  (with-arena outer
    (let [text : String (int->string 42)]
      (let [view : (& outer str) (& outer text)]
        (with-arena inner
          (let [f : (-> i64) (lambda () (string-length view))]
            (f)))))))
```

```lisp test=ignore name=closure-reference-inner-arena-reject reason="negative example for the reference-capturing closure checker"
(define (bad-inner-arena-reference-closure) : (-> i64)
  (with-arena inner
    (let [text : String (int->string 42)]
      (let [view : (& inner str) (& inner text)]
        (lambda () (string-length view))))))
```

### 3.11 Owned `String`, borrowed `str`, and byte buffers

This section defines the source contract for text and binary data: owned
`String` with borrowed `str` views, and owned `ByteBuf` with borrowed `bytes`
views. Borrowing a `String` place produces a `(& lifetime str)` view, and
stdlib string helpers take borrowed-`str` inputs (for example `string-eq` and
`substring` in `stdlib/string.tl`).

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
- String literals have type `String`. There is no static-borrowed string
  literal type and no implicit static lifetime.

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
specified in section 3.10.1. Without a declared lifetime relationship,
returning or storing a borrowed `str` is rejected unless the checker can prove
the reference is purely local to the current lexical scope:

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

Binary IO, FFI, and builder code share one byte-buffer family:

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
`ByteBuf` follows the move-only aggregate rules in section 4.7.2.

`bytes` is a borrowed referent like `str`, not a first-class value type. It
appears only behind `&` or `&mut`. An immutable `bytes` view permits reads only.
A mutable `bytes` view is exclusive and fixed-length: it may write existing
indices but cannot append, reserve, or change the owner's length. Direct
indexing, slicing, and mutation helpers for `ByteBuf`/`bytes` use the same
runtime bounds discipline as arrays and strings: negative or out-of-range
indices and invalid `[start, start + len)` slices trap through the ordinary
out-of-bounds path unless an API is explicitly named as checked/try-style.

The stdlib module `stdlib/byte_buf.tl` provides `byte-buf-*` helper names for
owned-buffer operations and `bytes-*` helper names for borrowed-slice
operations. The semantic operations are:

- create an empty buffer or a buffer with capacity;
- inspect length/capacity and read initialized bytes;
- push, set, clear, and reserve through an owned `ByteBuf` place or a mutable
  reference to that owner;
- borrow the live range as `(& r bytes)` or `(&mut r bytes)`;
- copy from a `String`, `(& r str)`, or `(& r bytes)` into a fresh `ByteBuf`;
- copy a `ByteBuf` or `(& r bytes)` into a fresh active-arena `String`.

Conversions are explicit:

- `String` and `(& r str)` may be viewed as immutable `(& r bytes)` without
  copying because TypeLisp strings are byte strings. They never produce
  `(&mut r bytes)`.
- `String` / `str` to `ByteBuf` copies into new mutable active-arena storage.
- `ByteBuf` to `String` copies the live bytes into a new immutable active-arena
  `String`. There is no borrowed `str` view of mutable buffer storage.
- `ByteBuf` to `(& r bytes)` or `(&mut r bytes)` is a borrow of the live range
  with no copy. While an immutable view is live, mutation/growth through the
  owner is rejected. While a mutable view is live, any aliasing read, write,
  move, or growth of the owner is rejected by the borrow checker.

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

C APIs that require NUL-terminated strings require an explicit NUL-terminated
copy such as the `ffi-c-string-*`/`ffi-cstr` family; neither `ByteBuf` nor
`bytes` implies trailing NUL, forbids interior NUL, or coerces to a C string
pointer. Binary IO helpers accept `(& r bytes)` for non-consuming writes,
return owned `ByteBuf` for allocated reads, and fill caller-provided
`ByteBuf`/`(&mut r bytes)` storage only under the exclusive mutable-borrow
rules.

`TextBuf` is intentionally separate. It is an append-oriented text builder over
owned or borrowed string chunks whose render operation materializes an immutable
`String`; it is not a random-access mutable byte buffer and must not become the
binary slice contract by accident. Generated modules such as `(slice i64)` in
`stdlib/vector_slice.tl` are typed collection views. `bytes` is the
language-wide raw byte-slice referent for binary data and FFI/IO boundaries.

#### API classification

Stdlib and builtin text APIs use borrowed `str` for non-consuming text inputs
and owned `String` results for allocation sites.

| Category | Members | Ownership contract |
|----------|---------|--------------------|
| Non-consuming text inspection | Imported `stdlib/string.tl` helpers `string-length`, `string-ref`/`char-at`, `string-eq`/`string=?`, `string->int`, and predicates such as `string-contains`, `string-contains-char`, and `is-string-prefix-at` | Accept borrowed `(& r str)` inputs and return scalars. They do not move or allocate text. |
| Text output and diagnostics | `print-string`/`print-str`, `print-error`, `panic`/`error`, process stdin strings | Accept borrowed `(& r str)` text/path/message inputs. Text-to-binary I/O conversion is explicit. |
| Active-arena owned string results | `arg`, `int->string`, `str-cat`/low-level concat primitives, `substring`/`string-slice`, stdlib trim/replacement helpers when they build text, env/path split/join helpers | Return owned `String` storage allocated in the active arena. Results created inside a scoped arena cannot escape that arena. |
| Borrowed string views | `substring-view`/`string-slice-view`, stdlib trim `*-view` helpers | Return `(& r str)` views tied to the input lifetime. Bounds traps match the owned-copy APIs. They do not copy bytes; a runtime helper may allocate fixed metadata for the view record, but it does not take ownership of or extend the backing bytes. |
| Caller-provided fallback/result values | `stdlib/string.tl` `string-replace` when no match is found, `stdlib/io.tl` `read-file-or` `ByteBuf` fallback paths; companion modules `stdlib/string_caller_result.tl` and `stdlib/io_caller_result.tl` | Preserve the caller-owned value instead of allocating. The I/O companion is an explicit binary-to-text materialization boundary for callers that need a borrowed textual fallback. |
| Mutable or binary byte storage | `ByteBuf`, `(& r bytes)`, `(&mut r bytes)`, `read-file`, `try-read-file`, `file-read-chunk`, `read-stdin-line`, `read-stdin-bytes`, `write-file`, append/write status helpers, `file-write`, `stdout-write`, `stderr-write` | Allocated reads return active-arena `ByteBuf`; non-consuming writes take borrowed `(& r bytes)`. Binary data is not modeled as `str`, and mutable byte views remain exclusive. |

#### ABI and lowering representation

`String` uses an aggregate-handle representation: a pointer-sized source value
points at a 16-byte string record containing `(data_ptr, length)`. The record
may describe static literal bytes or active-arena storage.

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
initializers, including struct, enum, tuple, fixed-array, and compatibility
dynamic-array values, are lowered through generated runtime initializer
functions when static data emission is not sufficient. Those initializer
functions run before the selected `main`.

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

### 4.2 `(define (name [param : type] ...) [: ret_type] body...)` — function

Defines a named function.

- Parameters must be explicitly typed.
- Return type defaults to `unit` when omitted.
- The body is one or more expressions. Multiple body expressions are evaluated
  as an implicit `begin`; the last expression provides the function result.
- The entry point is a function named `main` with return type `i64` or `unit`.
  If `main` is missing, the compiler synthesizes one that returns 0.
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

```lisp test=ignore name=extern-function-head-varargs reason="requires native symbols"
(extern (printf [fmt : (Ptr u8)] ...) : i32 (:symbol "printf"))
(extern (sumf [count : i64] [value : ...f64]) : i32 (:symbol "sumf"))
```

In a function-head extern, bare `...` marks an open C varargs tail. A bracketed
parameter whose type is `...T` marks a typed C varargs tail; every variadic call
argument must typecheck as `T`. The marker must be final, and the fixed argument
count is derived from its position. The marker is not included in the declared
fixed function type. Varargs markers are valid only for direct function extern
declarations, not for bare external data values or raw function-pointer data
symbols.

Metadata appears outside the function head after the return type:

- `(:abi c)` selects the C ABI. Unknown ABI names are rejected.
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

Extern link metadata strings must be non-empty. Link metadata may be repeated.
Source `build`/`run` collects extern-owned link inputs from the source and its
imports, then merges explicit CLI `--link-lib`, `--link-search`, and
`--link-arg` inputs after metadata inputs. Exact duplicate values within each
input class are removed while preserving stable first-seen order.

External calls and `extern` declarations use the metadata symbol without the
`_tl_` TypeLisp function prefix. Symbol text is passed through the deterministic
assembler-safe encoder used by the backend, so unsupported symbol characters are
escaped consistently. Ordinary TypeLisp declarations use module-prefixed
`_tl_...` linker symbols.

Extern signatures may use backend-supported scalar values, `unit`, function
pointers, raw pointers, and pointer-sized TypeLisp runtime handles such as
`String`, compatibility dynamic arrays, structs, and enums. Tuple values, fixed
arrays, references, regions, and unsupported aggregate forms are rejected for
extern parameters and returns; pass a raw pointer when a foreign API needs
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
expansion, and lowering. Safe code may mention the declared name only by
entering an explicit `(unsafe ...)` expression; a safe direct call or safe
function-value reference is rejected and the diagnostic names the callee. An
unsafe function body is still checked as ordinary safe code unless the body
itself uses `(unsafe ...)`. A local or later declaration that shadows the same
name does not inherit the unsafe marker.

### 4.4 `(import module.path)` — modules and imports

Imports a module by its canonical dotted identity. Importing a module loads it
and, by default, binds a qualified module alias; it does not merge the module's
declarations into the local unqualified namespace. Members of an imported
module are reached through dotted qualified names (§4.4.3). The default alias
is the final segment of the imported module identity. If that alias would
collide with an existing module alias, the import is rejected unless the source
supplies an explicit alias: after `(import math.vector as vec)`, importing
`io.vector` requires a spelling such as `(import io.vector as io-vec)`.

The import forms are:

```lisp test=ignore name=module-import-final-syntax reason="import form overview"
(import stdlib.io)             ; binds alias `io`; use `io.write`
(import stdlib.io as io2)      ; binds alias `io2`; use `io2.write`
(import stdlib.io.*)           ; imports all items unqualified
(import stdlib.io.write)       ; imports item `write` unqualified
(import stdlib.io.write as w)  ; imports item `write` as `w`
```

`.*` and `.item` are the only ways to pull a module's items into the
unqualified namespace. `.*` imports every item and cannot combine with `as`.
`.item` imports one item and may combine with `as` to rename the local binding.
The resolver uses the longest dotted prefix that names a loadable module; if
exactly one segment remains, that segment is the selected item. The import is
rejected if more than one segment remains or if the remaining segment is not
declared by the resolved module.

Two unqualified imports, whether through `.*` or `.item`, that bring in the
same name are a namespace collision. The diagnostic names both module
identities and suggests alias-qualified access instead. Prelude bare names such
as `panic`, `print*`, and the deliberately retained prelude exceptions come
from the implicit prelude and are not affected by these import rules.

Multi-item selected imports are deferred in v1. Spellings such as
`(import stdlib.io :only (read write))` are reserved and rejected until a
follow-up specifies their shadowing and re-export rules.

Each module loads once per program: different import spellings that resolve to
the same module load one instance, and non-macro import cycles terminate
through that load-once rule rather than being rejected. Cycles through macro
tables are rejected; see §4.4.4.

Earlier revisions imported modules by source-file path, as in
`(import "lib/util.tl")`. That spelling remains accepted only as a temporary
compatibility surface for named migration fixtures and is scheduled for
removal; new source uses dotted module identities.

#### 4.4.1 Module identities

A module has a canonical identity independent of the source-path spelling that
loaded it. The canonical identity is a dotted identifier path such as
`stdlib.string`, `compiler.lower`, or `math.vector`. It is stable across
platform path separators and package-root spellings.

If a source file is imported by dotted identity, that identity is the canonical
module identity for files without an explicit module declaration. Package and
stdlib path imports also infer a stable dotted identity from the normalized
source path without its `.tl` suffix. Legacy local relative-path imports without
an expected module preserve their historical flat importer context. An explicit
`(module ident)` declaration is a legacy module-boundary marker that overrides
the inferred identity for following declarations until another module boundary
appears. Different spellings that normalize to the same source file load one
module instance.

Identity resolution maps a dotted identity to a source file:

- Identities under `stdlib.` resolve through the configured stdlib roots.
  Explicit `--stdlib-root <dir>` entries are searched first, then the optional
  `TYPELISP_STDLIB_ROOT` environment root, then the compiler's embedded stdlib.
  A module reachable from the importing module's own source tree takes
  precedence over configured stdlib roots and embedded modules. Stdlib roots
  serve only normal relative suffixes under the root; suffixes containing
  components such as `..` are not resolved through stdlib fallback.
- During a package build, an import whose leading segment is a dependency alias
  declared in the current `typelisp.pkg` resolves from that dependency's
  package root, and the resolved module must stay below that root. The
  dependency alias contributes to the loader identity, but an explicit
  `(module ...)` declaration inside the file remains the public source-level
  identity.
- Other identities resolve from the importing module's source tree, with
  identity segments mapping to path components relative to the importing
  file's directory.

The compiler-injected `stdlib.runtime` and `stdlib.core_macros` preludes are
resolved independently of an entry module's source tree. Explicit
`--stdlib-root` entries take precedence, followed by `TYPELISP_STDLIB_ROOT` and
the embedded stdlib payload. The fixed `stdlib/<name>.tl` disk spelling is only
a compatibility fallback when the embedded payload does not contain that
prelude (for example, during a seed bootstrap). Regardless of the physical
source selected, these preludes retain their canonical `stdlib.*` module and
path identities.

#### 4.4.2 Default visibility

Every top-level item of a module is visible to any module that imports it.
There is no export declaration and no private/public distinction: all of the
following are reachable through a qualified name from any importing module, and
remain in separate namespaces.

- Values: function `define`s, variable `define`s, and TypeLisp declarations for
  `extern`s.
- Types: enum and struct type names.
- Macros: top-level `defmacro` declarations. Macros live in a separate
  compile-time namespace and are looked up only while expanding expression
  heads, so a macro and a value may share a spelling.
- Enum variant constructors and struct constructors/field accessors.

Cross-module access therefore requires only that the item exist and that the
referencing module import (or be) the defining module. A missing member, or a
namespace mismatch such as using a value-qualified name where a type is
required, is still a source-located error; there is no separate
private/exported check. An `(export ...)` form is not a recognized declaration.

```lisp test=ignore name=module-default-visibility reason="module identity example"
;; geometry.tl, imported with `(import geometry)`.
(defstruct Point
  (x i64)
  (y i64))
;; No export form: `Point`, its constructor, and its fields are all reachable as
;; `geometry.Point`, `(geometry.Point x y)`, and `(struct-get p x)` from any
;; module that imports `geometry`.
```

#### 4.4.3 Qualified lookup

Qualified source names use `.`: `alias.name` for one alias segment and
`module.path.name` for a full canonical module path. Full canonical paths are
accepted only when that module identity has been imported in the current module
or when the use appears inside the same module. Unqualified lookup searches only
local declarations and local bindings. It does not search imported modules.
Slash-qualified source names such as `alias/name` are rejected; `/` is the
ordinary division operator.

In expression and place contexts, a dotted name whose leading segment is a
local binding is local struct-field sugar before qualified module lookup. For
example, `data.value` resolves as `(struct-get data value)` when `data` is a
local binding, even if `data` is also an imported module alias. If the leading
segment is not local, the qualified lookup rules below apply.

Qualified lookup applies to:

- Values: `(vec.dot a b)`, `config.default-timeout`.
- Types: `[p : geometry.Point]`.
- Enum variants and patterns: `(json.Some value)` and `[(json.Err e) ...]`.
- Struct constructors: `(geometry.Point 3 4)`.
- Struct fields: `(struct-get p x)` resolves `x` through the receiver's struct
  type; fields of an imported struct are reachable from any importing module.
- Macros: `(bool.and2 a b)` resolves `and2` in the imported module's macro
  namespace during expansion.
- Generated declarations: generated family keys include the generator module
  identity plus the generated declaration identity.

Missing module aliases, ambiguous aliases, missing qualified members, and using
a value-qualified name where a type is required are source-located errors.

Example with colliding local names:

```lisp test=ignore name=qualified-colliding-modules reason="multi-file example"
;; left.tl
(define same : i64 20)
(define (get) : i64 same)

;; right.tl
(define same : i64 22)
(define (get) : i64 same)

;; main.tl
(import left)
(import right)
(define (main) : i64 (+ (left.get) (right.get)))
```

#### 4.4.4 Macro import and expansion ordering

Macro-bearing modules use the same module identities and resolution rules as
ordinary imports (sections 4.4 and 4.4.1); there is no separate macro search
path.

The compile driver loads `stdlib.core_macros` as an implicit macro prelude.
Bare `when`, `unless`, `and`, `or`, scalar `for`, and bracket-arm `cond`
resolve to the prelude macros of `stdlib.core_macros` unless a local or
imported macro with the same name takes precedence. The core `cond` surface is
`(cond [test expr] ... [else fallback])`; flat
`(cond test expr ... fallback)` calls are rejected. The module can also be
imported explicitly, for example `(import stdlib.core_macros as core)`, and its
macros called through the alias: `core.when`, `core.unless`, `core.and`,
`core.or`, `core.cond`, and `core.for`.

Before expanding a module's non-import forms, the loader collects its import
declarations, recursively loads imported modules, and builds the imported macro
namespace from each dependency's macro declarations. Imported macros are then
available for the entire expansion of the importing module through qualified
names such as `bool.and2`; the imported macro's typed signature is used for
call-site checking, and operand expressions are not evaluated before expansion.

Local macros are module-scope declarations. A local `defmacro` is available to
all non-import forms in its module after imports and generated declarations
have been processed, regardless of whether the call appears before or after the
declaration. Local macros may call imported macros and any local macro in the
same module; recursive expansion is bounded by the macro expansion depth limit
and rejected with a source-located diagnostic.

Imported-macro tables are complete after the imported module's own imports and
local macro declarations have been collected. A cycle that requires a macro
from a module whose macro table is still being built is rejected. Non-macro
import cycles keep the load-once behavior described in section 4.4.

Required diagnostics:

- Missing macro: a qualified macro head names an imported module but that
  module declares no macro of that name.
- Duplicate macro: two distinct macro declarations share the same
  `(module, macro-name)` identity.
- Recursive macro expansion: expanding a macro reaches the implementation's
  deterministic depth limit, typically because macros expand to each other in a
  cycle.

Cross-module macro use:

```lisp test=ignore name=module-imported-macro-use reason="multi-file example"
;; bool-macros.tl
(defmacro (and2 [lhs : bool] [rhs : bool]) : bool
  (expr-if lhs rhs (expr-bool false)))

;; main.tl
(import bool-macros as bool)
(define (main) : i64
  (if (bool.and2 true true) 0 1))
```

No export form is involved: every macro is visible to importers (§4.4.2).

Forward local macro use:

```lisp test=ignore name=module-forward-local-macro-use reason="macro ordering example"
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
as a string literal. This is a module-loader directive, not a runtime
operation: the loader reads the file and expands the directive into an ordinary
string-valued `define` before typechecking, lowering, and codegen, so later
stages only ever see a normal global.

- Text-only: the file is read as UTF-8 source payload. Use `include-bin` for
  arbitrary binary payloads.
- `path` is a string file path: relative paths resolve from the including
  file's directory, and `stdlib/...` paths use the stdlib-root and
  embedded-stdlib precedence of §4.4.1, including the rejection of
  parent-escape (`..`) suffixes through stdlib fallback. The included file is
  read as raw text — it is not parsed as a module, runs no imports or tests,
  and does not participate in import deduplication.
- An include failure reports both the including file and the requested path.

#### 4.4.7 `(include-bin name "path")` - embed a binary file

Embeds the exact byte contents of `path` as a global `name : (Array u8)`. This
is the binary sibling of `include-str`: the module loader resolves and reads
the file during compilation, then expands the directive into a generated global
definition before typechecking, lowering, and codegen.

- Bytes are embedded exactly as read, including NUL bytes, bytes above 127, and
  trailing newlines. There is no UTF-8 decoding, escaping, or source parsing.
- `path` resolution and failure diagnostics are the same as `include-str`.
- The representation is a process-global byte-buffer header pointing at
  writable static data; no startup copy is required. Because the surface type
  is mutable, writes mutate the global static payload for the process; treat
  included payloads as read-only unless that shared mutation is intended.

The compiler-owned `(include-str-lzss name "path")` form is the compressed
runtime-static sibling of `include-str` and `include-bin`. It uses the same
explicit input and path-resolution rules, deterministically LZSS-compresses
the text at the loader boundary, and defines an opaque static
`name : (Array u8)`. The bounded binary-data payload starts with the
compiler-owned `__typelisp_embedded_stdlib_lzss_v1__` marker, the decimal
uncompressed byte length and a newline, followed by the token stream. This
form exists for compiler-owned source payload tables.

#### 4.4.8 `(include-str-comptime name "path")` - compile-time text input

Reads the exact text contents of `path` and defines a zero-argument macro
`name`. Calling `(name)` expands to a string literal containing those bytes.
The text is available to macro CTFE but has no runtime global and is not
embedded in generated code unless a macro explicitly emits it.

Path resolution, raw-text handling, and diagnostics are the same as
`include-str`. A common declaration-macro pattern is to inspect the expanded
literal with `comptime.expr-string-value`, transform its bytes at compile time,
and emit the result with `comptime.expr-binary-data`.

`comptime.expr-binary-data(bytes)` constructs an opaque expression of type
`(Array u8)` from a compile-time `String`. It lowers directly to static binary
data; the bytes are not represented as source syntax or an array literal.

#### 4.4.9 `(cfg predicate declaration)` - conditional compilation

`cfg` conditionally includes source forms before normal declaration parsing and
import resolution. A top-level declaration may be wrapped as
`(cfg predicate declaration)`: if `predicate` is true, `declaration` is parsed
in place; if it is false, the declaration is skipped.

Predicates are inspired by Rust `cfg`:

- `name` is true when the compiler command enabled `--cfg name`.
- `(all predicate...)` is true when every operand is true; with no operands it
  is true.
- `(any predicate...)` is true when any operand is true; with no operands it is
  false.
- `(not predicate)` negates exactly one predicate.

In addition to explicit `--cfg` names, the compiler enables target OS
predicates from the selected backend target. `linux-x86_64` enables `linux`,
`unix`, `target-linux`, and `os-linux`. `windows-x86_64` enables `windows`,
`target-windows`, and `os-windows`. These names are available to both top-level
and expression-level `cfg` forms, including imports.

Inactive branches must still be lexically valid S-expressions, but they are not
parsed as TypeLisp declarations or expressions. This supports stage and
platform conditionals where one compilation can see declarations that another
must skip.

Expression lists may also contain `(cfg predicate expr)` forms. A false
expression-list cfg is omitted. In required expression position, `(cfg
predicate then-expr)` evaluates to `unit` when the predicate is false; `(cfg
predicate then-expr else-expr)` parses only the selected expression.

### 4.5 `(test name body...)` - inline test item

Declares a source-owned inline test. The name is an identifier. The body must
contain one or more expressions; multiple expressions are sequenced like
`begin`.

Production commands (`check`, `compile`, `build`, and `run`) type-check inline
tests owned by the explicitly named source — or by the package's own discovered
sources when operating on a package — before ordinary production emission. That
preflight enables the `test` cfg predicate, so source-local fixture
declarations can be written as `(cfg test ...)`; ordinary production loading
leaves them inactive. `test` items and test-only helper declarations are
dropped before production lowering and codegen, so valid inline tests cannot
change emitted assembly. Imports provide runtime declarations but do not have
their inline tests checked merely because they were imported.

`typelisp test <file.tl>` loads the import graph, lowers inline tests owned by
the requested source into private unit-returning functions, skips any
production `main`, generates a test-owned `main`, and runs the resulting
executable. `typelisp test --check <file.tl>` type-checks the generated harness
without assembling or linking. Before invoking each selected test, the runner
prints its name and declaration location. It runs all selected tests after
ordinary assertion failures, prints `ok` or `FAILED` per test, lists every
recorded assertion message, and prints final passed, failed, and total counts
in declaration order. Assertion helpers in `stdlib.test` record failures while
a generated test harness is active; outside that harness they retain aborting
behavior. A run exits `1` when assertions failed. A hard panic, trap, or other
unexpected harness termination stops the process and is reported by the test
command with exit `2`.

`typelisp test --filter <substring>` selects inline-test names containing the
case-sensitive substring. In package mode the same filter selects integration
test paths. `typelisp test --list` prints the selected names and declaration
locations without compiling or running a harness; it may be combined with
`--filter` but not `--check`.

Example:
```lisp test=check name=inline-test-declaration
(import stdlib.io)

(define (inc [x : i64]) : i64 (+ x 1))

(test inc-basic
  (if (= (inc 41) 42)
    unit
    (io.panic "inc result")))
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
- `kind` is optional: `bin` (native executable) or `staticlib` (static
  archive), as symbols or strings; `lib` is accepted as an alias for
  `staticlib`.
- `entry` is optional and resolved relative to the manifest directory. It
  defaults to `src/main.tl` for `bin` packages and `src/lib.tl` for `staticlib`
  packages; an explicit `entry` string overrides the convention default.
- When both `kind` and `entry` are omitted from a disk-backed manifest, package
  loading inspects the manifest directory: only `src/main.tl` present selects
  `bin`, only `src/lib.tl` present selects `staticlib`, and both or neither
  present is a diagnostic requiring an explicit `kind` or `entry`. A manifest
  parsed without filesystem context defaults to `bin`.
- `dependencies` is optional. Each entry has an alias symbol and either a
  string root path, `(alias "relative/or/absolute/path")`, or a GitHub
  shorthand source, `(alias (github "owner/repo" (rev "commit")))`.
- GitHub shorthand also accepts `github.com/owner/repo` addresses. It requires
  exactly one non-empty `rev`, `tag`, or `branch` string pin and normalizes to
  a git remote URL with a pin fragment such as
  `https://github.com/owner/repo.git#rev=commit`.
- Dependency aliases use the same character rules as package names: ASCII
  letters, digits, `-`, and `_`. Duplicate aliases are rejected.
- Relative dependency paths are resolved relative to the manifest directory;
  absolute dependency paths are used as written. Remote dependencies resolve
  through `typelisp.lock` and the package cache before falling back to `git`;
  resolved commits are recorded as deterministic lock entries. `--locked`
  requires matching lock entries and never rewrites `typelisp.lock`; missing,
  stale, or extra lock entries fail. `--update-lock` refreshes remote pins and
  rewrites `typelisp.lock`.
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
  non-string values, and unknown versions are rejected; emitters write stable,
  human-readable entries sorted by alias. Package builds load `typelisp.lock`
  from the declaring package root and replay an entry only when its alias, URL,
  pin kind, and pin value match the manifest dependency; replay converts the
  dependency to the recorded exact commit before fetching. Missing or stale
  entries are resolved from the manifest pin and included in the next emitted
  lockfile; a deterministic lockfile is written whenever the package has remote
  dependencies or a prior lockfile exists.
- The remote package cache is a deterministic v1 root at
  `target/typelisp/cache/packages/v1` below the package root. Entry paths are
  derived from the normalized remote URL and an exact commit; `tag` and
  `branch` pins are resolved to commits before key construction. An entry is
  reusable only when its metadata matches the URL/commit key, its completion
  marker is valid, and the cached root contains `typelisp.pkg`; complete
  entries are reused without invoking `git`, including during locked replay.
  Partial or corrupt entries are never reused and are refetched through a
  staging directory.
- Local dependency manifests are loaded into a normalized DAG keyed by manifest
  path before build execution. Transitive dependency packages build once per
  root build invocation, diamond graphs de-duplicate the common archive, and
  independent ready nodes are scheduled concurrently when async process handles
  are available (with a serial fallback preserving the same ordering and
  diagnostics). Dependency cycles fail before code generation with a diagnostic
  that includes the manifest path chain.
- Dependency packages must be `staticlib` packages; a `bin` dependency is
  rejected as a package-graph diagnostic.
- `typelisp build --manifest-path path/to/typelisp.pkg` builds the entry file
  through the same module loader and compiler pipeline as `compile`.
  `typelisp build` without `--manifest-path` searches for `typelisp.pkg` from
  the current directory upward.
- `typelisp run [--manifest-path path/to/typelisp.pkg]` uses the same package
  discovery and package build pipeline as `build`, then executes the emitted
  `bin` artifact. Package runtime arguments follow `--`. `staticlib` packages
  are not executable.
- Package `typelisp check` typechecks the manifest entry's transitive import
  closure once — the same program closure that package `build` validates — and
  both typecheck doc-comment examples only in that closure. Source files
  outside the closure are intentionally not package check/build inputs;
  validate them through explicit file checks, `typelisp doc --test <file>`, or
  package test coverage.
- Package `typelisp lint` checks every discovered package source. For package
  dead-code lint, `staticlib` packages treat every top-level declaration as an
  external API root. `bin` packages use the declared `main`, top-level test
  bodies, macro-import calls, and generated-declaration metadata as roots;
  top-level declarations unreachable from those roots are lint findings unless
  suppressed with `;; lint-allow: dead-code`.
- Package builds accept `--profile dev|release` and `--release`. The default
  profile is `release`; `--release` is an alias for `--profile release`.
  `--opt-level 0|1|2` overrides the profile's optimizer level. Without an
  explicit level, `release` uses level 2 and `dev` uses level 0.
- Package builds accept `--locked` and `--update-lock` as described above.
  These flags are rejected for source-file builds and non-package commands.
- Build outputs are written under `target/<profile>/` in the package root.
  `bin` packages produce `<package-name>` on Linux and `<package-name>.exe` on
  Windows. `staticlib` packages produce `lib<package-name>.a` on Linux and
  `<package-name>.lib` on Windows. Assembly and object side artifacts use the
  same profile directory. Package builds also produce a host comptime image
  named `<package-name>.tlci` in the same profile directory; dependency DAG
  builds produce each dependency's tlci next to its static archive without
  changing runtime link behavior. Macro-free packages emit metadata-only
  images. Packages with package-owned macro declarations emit deterministic
  code-bearing images and one registration-table record per macro. Supported
  expression/value transformer bodies execute compiled template (nested calls,
  literals, plain symbols, unquoted operands, unquote-splicing), literal,
  computed-if, and fold operations through the host callback ABI; supported
  let-rooted bodies evaluate their computed binding inits (expression
  variables from string append/type-key chains and scalar/string computed
  expressions) through session locals and then emit compiled template,
  bracket-clause, borrow, array, match, and let declarations the same way;
  unsupported bodies retain an explicit registered shell and interpreted
  fallback. General
  consumer catalog
  discovery/dispatch is a separate integration layer. The tlci path is
  target-independent in v1: cross-target builds keep target runtime artifacts
  separate while sharing the host comptime image path.
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
  - Relative `search-paths` (all-target and per-target) are resolved against
    the manifest directory before the linker runs, so builds are independent of
    the caller's working directory. Absolute search paths, library names, and
    raw arguments are used as written.
  - Effective link inputs for a `bin` build are assembled in first-seen order
    with exact duplicates removed within each class (libraries, search paths,
    raw args): all-target manifest inputs, then the selected target's inputs,
    then source `extern` link metadata from the package entry/import graph,
    then the static archives of package dependencies (kept positional after the
    requested libraries and arguments). On Linux, any non-empty link input
    switches the package link from the freestanding `ld` path to the `cc` path
    so the program links against the C runtime and the requested libraries.
  - The `link` section affects only `bin` artifacts. `staticlib` packages emit
    an archive, and a dependency package's `link` section is not propagated to
    a dependent `bin`; declare shared native inputs in the binary package's own
    manifest. Dynamic/shared library output is out of scope for the package
    layer.
- Dependency modules are imported by dotted identity: an import whose leading
  segment is a dependency alias declared in the manifest resolves from that
  dependency's package root, as specified in §4.4.1.
- Out of scope by design:
  - Registries. The model is explicit local paths plus git/GitHub sources
    fetched by the host `git` CLI and pinned by `typelisp.lock`. A future
    registry must be optional for building checked-in packages, TypeLisp-owned,
    and compatible with the zero third-party dependency policy.
  - Semantic-version solving. Manifests name exact `rev`, `tag`, or `branch`
    pins and lock replay records exact commits; the build does not solve
    version ranges, choose among competing versions, or fetch multiple
    candidates.
  - Workspaces. Package roots have independent manifests, locks, target
    directories, and dependency DAGs. A future workspace model may group local
    packages and share orchestration/lock policy, but every package must
    continue to build without a workspace file.
  - Implicit preludes and dynamic/shared library output. Namespace isolation
    and qualified symbol access are specified by the module model in section
    4.4, not by package resolution itself.

### 4.7 `(defenum ...)` and `(defstruct ...)`

See §3.5.

#### 4.7.1 Cleanup-owning aggregate declarations

Cleanup-required values must be passed to a cleanup function exactly once
before their owner scope exits. Ordinary aggregates do not own such values: a
`defstruct` or `defenum` without cleanup metadata must reject
cleanup-required fields or payloads and cleanup-owning aggregate fields or
payloads. Ordinary aggregate construction therefore cannot silently hide
cleanup responsibility in a value with no cleanup plan.

A cleanup-owning struct opts in with type-level `(:cleanup cleanup-fn)`
metadata immediately after the struct name and before all fields. The metadata
declares the cleanup function for the struct type and makes values of that
type move-only:

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
compiler exposes exactly one such function per cleanup-owning struct and
rejects any other top-level value with the same name. Its type is
`(-> T unit)`, where `T` is the struct type. The generated cleanup function
owns its argument, runs the struct field cleanup plan below, and returns
`unit`. Source-level custom cleanup hooks for the whole value are reserved;
v1 cleanup behavior is fully determined by field metadata and nested
cleanup-owning field types.

Struct field metadata may include exactly one cleanup marker after the field
type:

- `(:cleanup field-cleanup-fn)` marks a direct resource field and names the
  cleanup function for that field. The function must have type `(-> F unit)`,
  where `F` is the field type.
- `(:owned)` marks a field whose type is itself cleanup-owning. The field uses
  that type's declared cleanup function.

Field-level cleanup metadata is accepted only inside a cleanup-owning struct,
which may also contain ordinary fields with no cleanup marker. Every
cleanup-required field must have `(:cleanup ...)`; every cleanup-owning
aggregate field must have `(:owned)`; a field may not specify both. Field
metadata is part of the owning contract, not layout, and is incompatible with
`(:repr c)` in v1: a C ABI struct cannot own cleanup-required resources.

Cleanup for a struct value is deterministic. When the owner scope cleans a
value of cleanup-owning struct type:

1. The value is marked moved, so later reads, copies, stores, or returns of
   the same owner are rejected.
2. Fields with cleanup metadata are cleaned in reverse declaration order.
3. For `(:cleanup f)`, the compiler calls `f` with the field value.
4. For `(:owned)`, the compiler recursively calls the field type's declared
   cleanup function.
5. Fields without cleanup metadata are not cleaned.

Nested cleanup completes before the previous field begins. A field that has
already been moved out is no longer cleaned by the containing struct;
responsibility moved with the field. Moving a field out of a cleanup-owning
struct leaves the whole struct partially moved, so later cleanup of the whole
value is rejected unless the field is definitely reinitialized before the
owner scope exits.

Cleanup-owning structs are move-only. Assigning, passing as an ordinary
by-value argument, returning, storing in another aggregate, or binding to
another name transfers ownership unless the operation is explicitly a borrow
(section 3.10). After such a move, the source value cannot be used. Copying a
cleanup-owning value is never allowed. A cleanup-owning value cannot be stored
in a global, captured by an escaping closure, or returned from a `with` scope
that owns it.

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
    (let [copy h]
      (struct-get h fd))))
```

The `let` binding moves `h` into `copy`; the later read from `h` is rejected
as a use-after-move. The compiler also ensures the moved value still has
exactly one owner that will clean it.

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

`leak-handle` is rejected because the `with` scope owns `h`; returning it
would escape the cleanup scope.

`with` is the v1 owner scope for cleanup-owning aggregates. If a `with`
binding initializes a cleanup-owning struct, its cleanup position must be the
struct's declared cleanup function; any other cleanup function is rejected. A
resource value moved into a cleanup-owning aggregate is not also cleaned by
the source binding. `let` has no cleanup behavior; creating a cleanup-owning
value in `let` is valid only if the value is immediately moved into another
owner whose cleanup is statically known.

Cleanup runs when the owner scope exits normally and before recoverable
`(try ...)` propagation leaves the scope. If initialization of a later `with`
binding propagates recoverably, already-initialized earlier cleanup-owning
values are cleaned in the same reverse-binding order as other resources.
Cleanup functions return `unit`; if a cleanup function panics, the program
aborts and the language does not guarantee that remaining field, nested, or
outer cleanups run. A direct `panic`/abort has no unwinding cleanup guarantee.

Cleanup-owning `defenum` declarations use the shape
`(defenum Name (:cleanup cleanup-fn) variant+)`. The metadata is accepted and
validated: payload cleanup functions are typechecked, and ordinary enum
payloads that store cleanup-required or cleanup-owning values without an
owning cleanup contract are rejected. Lowering emits the declared cleanup
function as a match over the active variant. It cleans only that variant's
payload, in reverse payload declaration order, using field-style `(:cleanup
...)` and `(:owned)` payload metadata.

#### 4.7.2 Move-only aggregate handle semantics

Aggregate handles are move-only in v1.

**Copyable v1 types.** A use of a copyable value duplicates the value and
leaves the source initialized. Copyable types are:

- Scalar primitives: all integer widths, `f64`, backend-accepted `f32`
  positions, `bool`, `char`, and `unit`.
- The compiler-internal `never` type, which has no runtime value to move.
- Raw pointers `(Ptr T)` and `(MutPtr T)`; copying a pointer copies only the
  address and carries no ownership guarantee.
- Named top-level function values and non-capturing function pointers.

Safe reference values and their copy/aliasing rules are specified by section
3.10, not by this section.

**Move-only v1 types.** A by-value use of a move-only value transfers
ownership and marks the source place moved. Move-only types are:

- `String`.
- `ByteBuf`.
- Compatibility dynamic arrays `(Array T)`.
- Boxes `(Box T)`.
- Fixed arrays `(Array T N)`.
- Tuples `(Tuple ...)`.
- Default-layout structs and enums.
- Cleanup-owning structs (section 4.7.1).
- Capturing closure values. A closure that captures only copyable values may
  be classified copyable in a future revision; the v1 checker treats capturing
  closures conservatively as move-only unless it can prove all captures are
  copyable.

A region wrapper `(in r T)` preserves the copy/move class of `T`; the region
tag only constrains where the value may escape. Type aliases preserve the
aliased type's class.

**Move sites.** The checker treats these by-value positions as moves for
move-only values and as copies for copyable values:

- `let` initialization. `(let [b a] body)` moves `a` into `b` when `a` is
  move-only; `a` is unusable afterward.
- A variable or place used as a by-value expression result, including a
  block's final expression.
- Function-call arguments whose parameter is marked `(:consume)`. A marked
  move-only argument is consumed through the same whole-place and tracked-path
  move rules as other moves; a marked copyable argument remains a copy and
  creates no moved state. Arguments are evaluated left-to-right, so earlier
  moves are visible while checking later arguments and the remaining
  expression. Unmarked parameters retain their established compatibility
  behavior, including any type-specific intrinsic consuming rules.
- Function returns. Returning a move-only local or parameter moves it to the
  caller. Returning from a `with` owner scope is still rejected when it would
  bypass required cleanup.
- `set!` right-hand sides. Assigning a move-only value into a definitely moved
  or definitely uninitialized local moves the value into that slot. Assigning
  over an initialized move-only slot is rejected in v1: there is no implicit
  drop, destructor, or replacement cleanup. Move-only globals are rejected.
- Tuple, fixed-array, struct, and enum constructors. Constructor arguments are
  consumed by value unless their expression is copyable or explicitly borrowed
  by a reference form.
- `array-set!` value arguments. A move-only element value would be consumed by
  the store, but v1 rejects arrays of move-only elements and stores of
  move-only elements; unique mutable element access and element replacement
  cleanup are reserved.
- `match` scrutinees. Matching a move-only enum by value consumes the whole
  enum value. Payload bindings then own the active payload values for that
  arm. Matching `(& place)` when the borrowed referent is an enum is the
  non-consuming borrowed form described below.
- Closure capture. Capturing a move-only local by value moves it into the
  closure environment at closure creation time; the local cannot be used after
  the lambda literal. Immutable reference captures are governed by section
  3.10.2; mutable reference captures are rejected in v1.

Repeated loop bodies are conservative move contexts. Moving a move-only owner
binding that is visible before a `while` or `foreach` body is rejected because
a later iteration could reuse the moved owner. Moving an owner created inside
the loop body is allowed for that iteration. Body move state is not propagated
after the loop because the loop may execute zero times.

**Non-consuming use sites.** A non-consuming use may inspect a move-only value
without moving it. In v1 these are limited to:

- Immutable and mutable borrow expressions `(& place)` / `(&mut place)` and
  their explicit-lifetime forms.
- Borrowed enum matches over `(& place)` / `(& lifetime place)`. The match
  inspects the active enum variant without moving the enum owner.
- Compatibility inspection calls whose signatures are not reference-typed:
  imported `stdlib.string` helpers `string-length`, `string-ref`/`char-at`,
  `string-eq`/`string=?`, `string->int`, `print-string`/`print-str`,
  `print-error`, compatibility dynamic-array `length`/`array-length`,
  `array-ref` when the element type is copyable, `struct-get` when the
  selected field type is copyable, and stdlib predicates that only inspect
  their aggregate argument.
- `array-set!` and `array-push!` on an owned array receiver or mutable
  reference receiver. These operations mutate the array storage and do not
  move the array handle; immutable-reference receivers are rejected.
- Struct field-place assignment `(set! (struct-get place field) value)` on an
  owned struct receiver or mutable-reference receiver. Local dotted sugar such
  as `(set! place.field value)` is the same place operation. This mutates only
  the selected field; immutable-reference receivers are rejected.
- Box-place assignment `(set! (box-get place) value)` and mutable borrows of
  `(box-get place)` through a live box storage place. These operations mutate
  or borrow the boxed storage and do not move the box handle.

Ordinary user-defined function parameters are by-value unless their type is a
reference type, but an unmarked parameter does not opt a broad move-only value
into call-site consumption. Use `(:consume)` when the callee takes ownership.
This opt-in preserves compatibility for existing unmarked APIs. Types with an
independent intrinsic consuming rule keep that rule.

**Whole-place and path moves.** The v1 checker accepts whole-place moves for
locals, parameters, and whole constructor temporaries. It also tracks
owner-consuming direct and nested paths through struct fields, tuple elements,
and fixed-array literal indexes, so moving one tracked path does not move its
siblings. Moving a tracked path marks the root partially moved; later
whole-root owner moves are rejected until every moved path for that root is
reinitialized. `array-set!` to a supported fixed-array path with an integer
literal index reinitializes only that exact path after the receiver, index,
and value have been checked. Reinitializing one element does not clear sibling
moved paths; if it clears the final moved path for the root, the partial-root
marker is removed. Dynamic-array elements, non-literal indexes, implicit moves
through `box-get`, and unsupported path forms do not clear moved state. Struct
field-place assignment reinitializes the selected tracked path when the
receiver path is supported; local dotted field sugar follows the same rule.
Box-place assignment updates boxed storage but does not reinitialize a moved
box handle; explicit `box-take` moves the whole box handle instead.
`struct-get`, `tuple-ref`, and `array-ref` may copy out only copyable fields
or elements, and may move out move-only fields/elements only where this
tracked-path policy accepts the path. A consuming `match` is the enum
exception: it moves the whole scrutinee first, then binds payload values owned
by the selected arm.

**Diagnostics.** Move checking must produce source-located diagnostics for:

- Use after move, naming the moved local or path and the move site when known.
- Moving from an uninitialized or already-moved slot.
- Assigning over an initialized move-only slot.
- Moving out of an unsupported path such as a compatibility dynamic-array
  element, non-literal fixed-array index, box projection, or unsupported
  aggregate path.
- Storing, capturing, or returning a move-only value where the destination
  would outlive the owner scope.

Move-while-borrowed and assignment-while-borrowed diagnostics are produced by
the borrow checker (section 3.10), not by move checking. `str` borrowing and
the owned/borrowed text distinction are specified in section 3.11.

```lisp test=check name=move-copyable-scalar-reuse
(define (copyable-scalar [x : i64]) : i64
  (let [y x]
    (+ x y)))
```

```lisp test=ignore name=move-reject-aggregate-reuse reason="negative move-only aggregate example"
(import stdlib.string)

(define (bad-string-reuse [s : String]) : i64
  (let [taken s]
    (string.string-length s)))
```

The `let` binding moves `s` into `taken`; the later `string.string-length`
inspection is a use-after-move even though the helper itself is
non-consuming.

```lisp test=ignore name=move-reject-consumed-function-arg reason="negative move-only call argument example"
(import stdlib.string)

(define (take-string [s : String (:consume)]) : i64
  (string.string-length s))

(define (bad-call-reuse [s : String]) : i64
  (begin
    (take-string s)
    (string.string-length s)))
```

The call to `take-string` consumes `s` because its parameter opts into
consumption; the later read is rejected.

```lisp test=check name=move-copyable-struct-field-projection
(defstruct Counter
  (label String)
  (count i64))

(define (counter-count [c : Counter]) : i64
  (struct-get c count))
```

Reading the `i64` field is non-consuming because the projected field is
copyable. Moving the `String` field out directly is not allowed:

```lisp test=ignore name=move-reject-struct-field-move reason="negative path-move example"
(defstruct Counter
  (label String)
  (count i64))

(define (bad-counter-label [c : Counter]) : String
  (struct-get c label))
```

```lisp test=check name=move-match-payload-consumes-scrutinee
(import stdlib.string)

(defenum MaybeName
  (NoName)
  (SomeName String))

(define (name-score [s : String]) : i64
  (string.string-length s))

(define (score [m : MaybeName]) : i64
  (match m
    [(SomeName s) (name-score s)]
    [NoName 0]))
```

The `match` consumes `m`; the `SomeName` arm owns `s` and can pass it to
`name-score`.

```lisp test=ignore name=move-reject-match-scrutinee-reuse reason="negative match move example"
(import stdlib.string)

(defenum MaybeName
  (NoName)
  (SomeName String))

(define (bad-match-reuse [m : MaybeName]) : i64
  (begin
    (match m
      [(SomeName s) (string.string-length s)]
      [NoName 0])
    (match m
      [(SomeName s) (string.string-length s)]
      [NoName 0])))
```

The first `match` moves `m`, so the second `match` is rejected as a
use-after-move.

```lisp test=check name=borrowed-enum-match-non-consuming
(import stdlib.string)

(defenum MaybeName
  (NoName)
  (SomeName String))

(define (borrowed-name-score [s : (& m str)]) : i64
  (string.string-length s))

(define (borrowed-score [m : MaybeName]) : i64
  (match (& m)
    [(SomeName s) (borrowed-name-score s)]
    [NoName 0]))
```

The borrowed `match` inspects `m` without moving it. Payload bindings are
references tied to the borrowed scrutinee lifetime; the `String` payload above
binds `s` as `(& m str)`.

#### 4.7.3 Recursive aggregate layout and boxed recursion

Ordinary TypeLisp structs and enums have a default inline layout contract.
Recursive-by-value aggregate cycles are therefore infinite source layouts and
must use explicit indirection through `(Box T)`, a raw pointer, or a reference
edge.

The finite-layout rule is structural:

- A field or enum payload may directly contain scalar, pointer, reference,
  function, and other finite-size values according to the ordinary type rules.
- A field or enum payload may contain `(Box T)` even when `T` is the aggregate
  currently being defined, because the field stores only the owning box
  handle.
- A field or enum payload that reaches the same inline aggregate type again
  without crossing a box, raw pointer, or reference edge is an infinite layout
  and must be rejected.
- Mutually recursive inline aggregates are checked the same way: every cycle
  in the aggregate layout graph must cross an explicit indirection edge.

Every default aggregate declaration is checked against this rule.

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

```lisp test=ignore name=box-reject-arena-escape reason="negative Box region escape example"
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
- `set!` mutates storage bindings in scope (locals, parameters, and globals).
- Variables are looked up in order: local bindings → function parameters →
  globals.

### 5.3 Function calls

```lisp test=ignore name=call-placeholder reason=placeholder
(func arg1 arg2 ...)
```

- Direct calls: the callee is a known function name.
- Indirect calls: the callee is a variable or parameter of function type,
  including a named top-level function passed as a function value.
- Arguments are evaluated left-to-right.
- Arguments are passed per the platform calling convention (§11); arguments
  beyond register capacity are passed on the stack.

### 5.4 Arithmetic and logical operators

All operators are prefix functions (or special forms):

| Operator | Signature | Description |
|----------|-----------|-------------|
| `+` | integer integer [integer ...] → integer | Addition |
| `-` | integer integer → integer | Subtraction |
| `*` | integer integer [integer ...] → integer | Multiplication |
| `neg` | integer → integer | Unary negation |
| `/` | integer integer → integer | Signed division |
| `%` | integer integer → integer | Remainder |
| `bit-and` | integer integer [integer ...] → integer | Bitwise AND |
| `bit-or` | integer integer [integer ...] → integer | Bitwise OR |
| `bit-xor` | integer integer [integer ...] → integer | Bitwise XOR |
| `shl` | integer integer → integer | Left shift |
| `shr` | integer integer → integer | Right shift (arithmetic for signed, logical for unsigned) |

- Integer arithmetic operators require matching operand types and return that
  type.
- Integer `+` and `*` accept two or more operands and are left-associated.
- Integer `+`, `-`, `*`, and `neg` wrap modulo 2^N, where N is the result type
  width. Signed integer results use two's-complement interpretation of those
  wrapped bits.
- Boolean `and` and `or` are short-circuiting macros provided by the implicit
  core macro prelude; they accept any arity of two or more operands.
- Bitwise and shift operators accept integer operands and return the left-hand
  operand type. `bit-and`, `bit-or`, and `bit-xor` accept two or more operands
  and are left-associated. Shift operators accept exactly two operands.
- `+`, `-`, `*`, `/` also operate on `f64` and `f32`; floating-point `+` and
  `*` accept two or more matching operands and are left-associated. `%` is not
  defined on floating-point values and is rejected.
- Integer `/` and `%` trap at runtime when the divisor is zero, or when a
  signed dividend is the minimum value for its width and the divisor is `-1`
  (since the mathematical result is not representable). Both cases abort the
  process with a diagnostic written to stderr and exit status 135.
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
expressions, so each test must type-check as `bool` and all branch result
types must merge using the normal `if` rules. At least one `[test expr]` arm
and a final `[else fallback]` arm are required, and `else` may appear only in
the final arm. Qualified calls such as `core.cond` use the same bracket-arm
shape. The flat `(cond test expr ... fallback)` shape is rejected.

```lisp test=ignore name=cond-expression reason=fragment
(cond
  [(= x 0) 10]
  [(= x 1) 20]
  [else 30])
```

`(when cond body...)` and `(unless cond body...)` are unit-valued guard
macros. `when` evaluates its body only when `cond` is true; `unless` evaluates
its body only when `cond` is false. Each form requires at least one body
expression, each body expression must be unit-valued, and multiple body
expressions are evaluated as an implicit `begin`. The whole form has type
`unit`, which makes these forms suitable for side effects and early-return
guards.

```lisp test=ignore name=when-unless-guards reason=fragment
(when (< x 0) (return 0))
(unless (< x 100) (print-string "large\n"))
```

### 5.7 `(let [name [: type] init] ... body...)` — local bindings

- Declares zero or more local variables.
- Bindings are the leading bracket forms after `let`; the first non-bracket
  form starts the body expression sequence.
- Variables are in scope for the body and for subsequent bindings in the same
  `let` (sequential, not parallel).
- Type annotation is optional. If omitted, the initializer type is inferred.
- The body is one or more expressions. Multiple body expressions are evaluated
  as an implicit `begin`; the last expression provides the `let` result.
- The empty binding wrapper `(let [] body...)` is a no-op body sequence, but a
  missing body is rejected.

### 5.8 `(begin expr ... last_expr)` — sequence

- Evaluates expressions in order.
- Returns the value of `last_expr`.
- `begin` is the explicit grouping form for positions that do not already
  accept expression sequences.

### 5.9 `(while cond body...)` — loop

- Evaluates the body while `cond` is `true`.
- The body is one or more expressions. Multiple body expressions are evaluated
  as an implicit `begin`; each body expression must be unit-valued.
- Returns `unit`.
- `(break)` exits the nearest enclosing scalar `while`; `(continue)` jumps to
  that loop's next condition check. Both forms take no operands, have the
  compiler-internal bottom type, and run active resource cleanups and
  `with-arena` resets for scopes they leave.
- `break` and `continue` do not cross lambda/function boundaries, have no
  labels, and cannot carry values. `while` is always unit-valued.

### 5.10 `(set! var expr)` — mutation

- Mutates an existing local, parameter, or global storage binding.
- The type of `expr` must match `var`'s type. Assignment is subject to the
  same move, borrow, and region/lifetime rules as other writes.
- Returns `unit`.
- Field mutation uses the field-place forms
  `(set! (struct-get place field) value)` and, when the receiver's leading
  segment is a local binding, the equivalent dotted sugar
  `(set! place.field value)`. Dotted `place.field` reads are likewise sugar
  for `(struct-get place field)`.
- Aggregate mutation through place forms follows the receiver's ownership
  mode: `array-set!` and field assignment require an owned place or a mutable
  reference receiver; immutable references are rejected.
- `ByteBuf`/`bytes` mutation follows the same rule: byte writes require an
  owned `ByteBuf` place, a mutable reference to a `ByteBuf`, or an exclusive
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
enum initializes through a real variant constructor, and a default-layout
struct initializes by recursively initializing its fields.

There are two source forms:

- `(init : T)` is the explicit form. It carries the target type in the source.
- `(init)` is contextual. It is accepted only where an expected type is known,
  such as an annotated `define`, annotated `let`, declared function return,
  function argument, struct/enum constructor field, fixed or dynamic array
  literal element, `array-set!`, or `array-push!` position. Ambiguous `(init)`
  is rejected with a diagnostic asking for `(init : T)` or an annotation.

`init` is compatible with ordinary functions named `init`: `(init)` and
`(init : T)` are parser-owned special forms, while `(init arg...)` is parsed
as an ordinary call unless the first argument is `:`.

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
| `(Array T)` | valid empty compatibility dynamic array; `make-array` uses the same element rules for live elements |
| `(Tuple T0 T1 ...)` | tuple of recursively initialized elements |
| `(Array T N)` | fixed array of `N` recursively initialized elements; `N` must be non-negative |
| Default-layout `defstruct` without cleanup | constructor with every field recursively initialized |
| `defenum` without cleanup | first declared variant, with payload fields recursively initialized |
| `(Box T)` | `box` containing recursively initialized `T` |

Unsupported or ambiguous cases are rejected rather than producing invalid
values. Rejected cases include function/closure values, references, `never`,
`Expr`/`ExprList`, `(:repr c)` structs, cleanup-owning structs/enums, empty
enums, negative fixed-array lengths, unsupported compatibility dynamic-array
element types, and recursive aggregate layouts that fail finite-layout
analysis.

Cleanup-owning aggregates are not initialized by `init`: constructing one
would also commit to cleanup execution and failure behavior, so they require
explicit constructors.

```lisp test=ignore name=init-expression-examples reason="illustrates source surface"
(defstruct Point (x i64) (y i64))
(defenum MaybeI64 (None) (Some i64))

(define zero : i64 (init))

(define (main) : i64
  (let
    [p : Point (init)]                 ; (Point 0 0)
    [m : MaybeI64 (init : MaybeI64)]   ; first variant, None
    [xs : (Array i64 4) (init)]        ; four zero elements
    (+ zero (+ (struct-get p x) (array-ref xs 0)))))
```

### 5.13 `(match scrutinee [pattern expr] ...)` — pattern matching

- Enum scrutinees support variant patterns such as `Red`, `Color.Red`,
  `(Some value)`, and `(Option.Some value)`. Payload positions accept nested
  patterns recursively: bindings, literals, `_`, and further variant patterns.
- Struct scrutinees support constructor-shaped patterns such as `(Point x y)`
  and `(geometry.Point x y)`. Fields are matched by declaration order,
  mirroring constructor calls. Field subpatterns are field bindings, `_`, and
  nested irrefutable struct patterns; refutable field subpatterns such as
  literals or enum variants are rejected.
- Borrowed enum scrutinees written as `(& place)` or `(& lifetime place)` use
  the same variant, wildcard, literal payload, and nested variant pattern
  forms, but inspect the enum without moving the owner. Payload bindings are
  immutable references tied to the borrowed scrutinee lifetime; `String`
  payloads bind as borrowed `str` references.
- Owned `(Box T)` scrutinees and owned enum payloads of type `(Box T)` support
  the explicit `(box inner-pattern)` pattern. The form takes exactly one inner
  pattern, reads the boxed `T`, and checks/binds the inner pattern against
  `T`. Inner patterns are irrefutable: bindings, `_`, and nested `(box ...)`
  patterns. Borrowed box patterns and refutable inner patterns are rejected
  with focused diagnostics. In enum contexts, `(box ...)` resolves as an enum
  variant pattern when the expected enum has such a variant.
- Scalar scrutinees support literal patterns plus `_`.
- String literal patterns compare string contents, not pointer identity.
- Bindings in enum and struct patterns introduce variables for payload fields
  or struct fields.
- A bare identifier at the top level of an enum `match` arm resolves as a
  nullary variant name. It is not a fresh catch-all binding; use `_` for that.
- The `_` wildcard matches any remaining value (used for exhaustiveness).
- All arms must return the same type.
- Enum values are heap-allocated on return from functions (see §3.5.1).

### 5.14 `(lambda ([param : type] ...) [: ret_type] body...)` — anonymous function

- A lambda expression evaluates to a function value with the declared
  parameter and return types.
- The body is one or more expressions. Multiple body expressions are evaluated
  as an implicit `begin`; the last expression provides the lambda result.
- Non-capturing lambdas lower to deterministic synthetic top-level functions
  and evaluate to static closure descriptor values.
- Capturing lambdas snapshot their captures by value into heap-allocated
  closure environments. Capturable values are integer widths, `bool`, `char`,
  `f64`, function values, `String`, compatibility dynamic arrays,
  tuples/structs/enums (including ones with nested aggregate fields), and a
  directly-captured fixed `(Array T N)` of scalar elements.
- `String` and compatibility dynamic-array captures snapshot their fat
  `{ ptr, len }` value onto the heap so the environment can outlive the frame
  that created the handle without dangling; the underlying buffer (`.rodata`
  for string literals, `tl_alloc` for compatibility dynamic arrays) is shared,
  matching aggregate-handle reference semantics. A tuple/struct/enum capture
  shallow-copies its inline storage onto the heap and then recursively
  re-snapshots any nested aggregate fields/payloads so they cannot dangle. A
  scalar fixed-array capture shallow-copies its inline element storage and
  reconstructs the array view on capture-load.
- A fixed array of aggregate elements, and a fixed array reached through an
  aggregate field, are rejected as captures: array elements live inline
  rather than as pointer-sized handles, so a by-value snapshot would require
  per-element deep copies that the capture model does not perform.
- Lambda literals can return the same value categories as named function
  returns, including `String`, enums, structs, compatibility dynamic arrays,
  tuples, and fixed arrays.
- `set!` to captured names is rejected by design. A lambda may assign its own
  parameters and locals, including a local that shadows an outer name, but it
  may not assign a lexical binding captured from an enclosing scope. Captures
  are by-value snapshots, so implicit rebinding would either mutate a hidden
  environment copy or require capture-by-reference semantics that the
  function type does not expose.
- Captured-name assignment is distinct from mutation through explicit storage
  reached by a captured value: `array-set!` on a captured dynamic array handle
  is legal when the receiver is otherwise mutable, and `Box` and
  mutable-reference APIs define their own explicit storage mutation rules.
- Immutable reference captures follow §3.10.2: a local, non-escaping closure
  may capture immutable references; escaping closures reject reference-typed
  captures.

```lisp test=ignore name=lambda-lift-immediate reason="integration tests cover executable lambda lifting"
((lambda ([x : i64]) : i64 (+ x 1)) 41)
```

### 5.15 SPMD `foreach`

SPMD (single program, multiple data) execution is data parallelism inside one
task. `foreach` and the companion forms below describe a gang of logical
program instances; an implementation may execute them one at a time or group
them into SIMD lanes. The scalar reference lowering defines the observable
semantics of every SPMD form, and SIMD backend modes must preserve those
semantics for all safe programs; which shapes each backend mode vectorizes,
scalarizes, or rejects is a support matrix specified in section 8, not here.
SPMD creates no independently scheduled OS threads, transfers no ownership
between thread-local arenas, and is separate from the safe task-threading
APIs specified in section 6.5.

Syntax:

```lisp test=ignore name=spmd-foreach-map reason="illustrative function; integration tests cover executable foreach programs"
(import stdlib.array)

(define (add-arrays [a : (Array i64)]
                    [b : (Array i64)]
                    [out : (Array i64)]
                    [n : i64]) : unit
  (foreach ([i : i64 0 n])
    (array-set! out i (+ (array-ref a i) (array-ref b i)))))
```

Semantics:

- `(foreach ([i : i64 start end]) body)` executes one logical program instance
  for each integer `i` in the half-open range `[start, end)`. `start` and
  `end` are uniform `i64` expressions evaluated once before the loop; if
  `end <= start`, the loop has zero logical iterations.
- `body` must have type `unit`; the `foreach` expression has type `unit`.
- Early exits are not part of the SPMD surface: `(return expr)`, recoverable
  `(try expr)` propagation, `(break)`, and `(continue)` are rejected inside
  `foreach` bodies. Per-lane early exit is expressed with varying `while`
  (below), whose loop-carried mask retires each lane independently.
- Programs that do not evaluate lane identity forms must produce the same
  observable result as an ordinary scalar loop over the same range; they must
  not depend on lane width or on an ordering between distinct logical
  iterations. Programs that evaluate `(program-index)` or `(program-count)`
  explicitly observe the selected backend gang shape (see lane identity).
- Compatibility dynamic-buffer bounds checks apply inside `foreach`: indexing
  past an array's length traps through the same bounds-check abort path as
  `array-ref`/`array-set!`.

Array access. The core patterns are contiguous map and zip-style kernels over
runtime-sized buffers, reading through `array-ref` and writing through
`array-set!`:

- Reads may use any SPMD-safe varying `i64` index expression, including
  gather-only reads through an index array such as `xs[ix[i]]`. Each read
  performs the ordinary bounds check for the logical iteration performing it.
- Non-atomic `array-set!` destination indexes must be the loop index or a
  simple uniform offset from it, such as `i` or `(+ base i)`. This makes
  ordinary writes race-free by construction: no two logical instances write
  the same element. Scatter writes through arbitrary varying indexes are
  rejected; the only overlap-tolerant scatter surface is the explicit atomic
  integer helper API below.
- The scalar lane element types are `i8`, `u8`, `i16`, `u16`, `i32`, `u32`,
  `i64`, `u64`, `f32`, `f64`, and `bool`. Bool array storage stays
  byte-compatible (`0` or `1` per element); lowering converts between byte
  arrays and internal masks privately. Varying integer arithmetic keeps the
  modulo wrapping semantics of scalar integer arithmetic.
- Straight-line contiguous numeric maps vectorize `+` and `-` for every
  numeric lane type; `bit-and`, `bit-or`, and `bit-xor` for every integer lane
  type; and `*` for every numeric lane type except `i8`/`u8`. Direct `shl` and
  `shr` maps vectorize `i32`, `u32`, `i64`, and `u64`, preserving the section
  5.4 invalid-count trap on active lanes only, including partial tails.
  Narrow direct shifts and byte multiplication are rejected with
  operator/type-specific diagnostics rather than silently scalarizing.
  Numeric `=`, `!=`, `<`, `<=`, `>`, and `>=` maps produce private masks that
  are stored through `bool` array lanes.

Runtime-sized SPMD inputs and outputs need not be spelled as unsized
`(Array T)` parameters: vector/slice-style sources and mutable destinations
borrow storage instead of copying collections. Generated vector
`slots`/`slots-mut` accessors and generated full-slice `slots` fields may be
borrowed into inferred local bindings before a `foreach` body; callers do not
name either the compatibility `(Array T)` spelling or the compiler-private
dynamic backing type. The body then uses ordinary `array-ref`/`array-set!`
over those borrowed buffers.

Uniform and varying rules:

- Values are uniform by default. The `foreach` index binding is varying: each
  logical program instance has its own `i`.
- Arithmetic and comparisons involving a varying value produce varying
  values. `array-ref` with a varying index produces a varying element value;
  `array-set!` with a varying index or value performs one write per active
  logical program instance.
- There is no public `(varying T)`, vector, or mask type. Those spellings are
  reserved and rejected; varying information is inferred inside `foreach`,
  and vector/mask values are internal to lowering.
- `let` bindings inside the body may be uniform or varying by inference.
  `set!` to a binding declared outside the `foreach` is rejected; reductions
  must use `spmd-reduce`.
- Direct calls to source-known TypeLisp helpers follow the SPMD helper call
  rules below.
- `if`, `match`, and `while` admit varying conditions and scrutinees under
  the masked control flow rules below; all other control-flow inputs must be
  uniform.

Lane identity forms:

- The public source names are the no-argument forms `(program-index)` and
  `(program-count)`. They are deliberately not general variables or
  first-class functions.
- Both forms are valid only in SPMD scope: inside a `foreach` body or the
  `value` expression of `spmd-reduce`. They are invalid in ordinary
  expressions outside SPMD, in `foreach` and `spmd-reduce` start/end/init
  expressions, and in type positions. If nested SPMD is specified later, they
  refer to the innermost SPMD region.
- `(program-index)` has type `i64` and SPMD class varying: the zero-based
  lane slot within the current gang, not the logical loop index. Use the
  index binding for the logical iteration value. `(program-count)` has type
  `i64` and SPMD class uniform: the current backend gang width.
- Scalar backend modes execute one active program instance at a time:
  `(program-index)` is `0` and `(program-count)` is `1`.
- SIMD backend modes group consecutive logical iterations into gangs of
  `(program-count)` lanes. For a gang with logical base index `g`, active
  lane slot `k` executes logical index `(+ g k)` when `(< (+ g k) end)` and
  observes `(program-index) = k` and the shared `(program-count)`.
- `(program-count)` may differ by backend mode, target, and lane element
  type. Programs that evaluate lane identity forms are intentionally
  backend-mode-observable; the compiler need not preserve scalar-equivalent
  exit status, output, or memory contents for them. Safe SPMD programs that
  do not evaluate these forms retain scalar equivalence.
- In `spmd-reduce`, lane identity forms are allowed only in the `value`
  expression. Such a value is pure but backend-mode-observable, so the
  reduced result may differ between scalar and SIMD backend modes.

```lisp test=check name=spmd-program-index-foreach
(import stdlib.array)

(define (write-lane-ids [idxs : (Array i64)]
                        [counts : (Array i64)]
                        [n : i64]) : unit
  (foreach ([i : i64 0 n])
    (begin
      (array-set! idxs i (program-index))
      (array-set! counts i (program-count)))))
```

In scalar backend modes, `write-lane-ids` stores `0` in every `idxs` element
and `1` in every `counts` element. In a SIMD backend mode with gang width `W`,
each full gang stores indexes `0` through `W - 1` and count `W`; a
non-divisible tail stores only the active prefix of those lane indexes.

```lisp test=check name=spmd-program-index-empty-range
(import stdlib.array)

(define (empty-lane-ids [out : (Array i64)]) : unit
  (foreach ([i : i64 0 0])
    (array-set! out i (+ (program-index) (program-count)))))
```

```lisp test=check name=spmd-program-index-tail
(import stdlib.array)

(define (write-tail-lane-ids [out : (Array i64)]) : unit
  (foreach ([i : i64 0 13])
    (array-set! out i (+ (* (program-count) 100) (program-index)))))
```

```lisp test=check name=spmd-program-index-reduce
(define (sum-lane-slots [n : i64]) : i64
  (spmd-reduce sum ([i : i64 0 n]) 0 (program-index)))
```

Tail behavior:

- The range has exactly `max(end - start, 0)` logical iterations; scalar
  lowering executes them one at a time. SIMD lowering must use an internal
  active-lane mask for tails so lengths `0`, less than the lane width,
  exactly one lane width, and not divisible by the lane width all produce
  the same observable result.
- Inactive lanes — tail lanes and lanes disabled by masked control flow —
  execute no source expressions and perform no source-visible effects: no
  bounds checks, loads, stores, atomics, traps, or calls. Their lane identity
  values are not observable.

SPMD helper calls:

- A direct call to a source-known, non-dispatch, non-extern TypeLisp helper
  whose body is available in the same whole-program compile is valid SPMD
  source when its varying arguments and result are scalar lane values and its
  body fits the same SPMD-safe expression surface as the containing `foreach`
  or masked branch. The compiler may inline the helper or compile it out of
  line through a compiler-private masked call ABI; observable behavior
  matches the scalar reference semantics either way.
- The private ABI introduces no public `(varying T)`, vector, or mask source
  types and no user-denotable helper symbols; helpers keep their ordinary
  scalar signature outside SPMD contexts. Hidden helper variants receive the
  current active mask (tail, enclosing region, and masked-branch condition
  masks), and inactive lanes inside a helper obey the inactive-lane rule
  above.
- Uniform arguments use the ordinary scalar value representation; varying
  arguments are scalar lane values. Results may be `unit`, a uniform scalar,
  or a varying scalar lane value; aggregate, string, array, and function
  returns are rejected.
- Function values and indirect calls, ordinary extern calls, `defdispatch`
  logical calls, and recursion through SPMD helpers are deferred by design;
  they are rejected with diagnostics naming the specific boundary rather than
  silently scalarizing.
- Metadata schema v2 in section 5.17.1 can describe compiler-private
  specializations stored in a package runtime archive. A direct imported
  package call may select such a specialization only when the canonical helper
  name and ordinary signature match and the consumer supports its `abi`,
  backend, lane count, positional argument classes, result class, and
  `index-param`. The call uses the record's exact hidden archive symbol.
  Missing metadata, signature mismatches, unsupported ABIs, and absent requested
  specializations are diagnostics rather than scalar fallbacks.

Masked varying control flow:

- An `if` condition inside `foreach` may be varying when it has type `bool`.
  A varying `if` creates two masked regions: the then region is active for
  lanes where the parent active mask and the condition are both true; the
  else region for lanes where the parent mask is true and the condition is
  false. Nested varying `if` composes masks by intersection with the
  enclosing active mask; exiting a branch restores the parent mask.
- Tail masks are part of the parent active mask; inactive lanes obey the
  inactive-lane rule above.
- The scalar reference semantics is normative: execute the range in
  increasing `i`, evaluate the condition for that logical iteration, and
  evaluate exactly the selected branch. SIMD lowering must produce the same
  observable result for every safe program.
- Both branches must have the same type: `unit` or a scalar lane value
  (`i8`, `u8`, `i16`, `u16`, `i32`, `u32`, `i64`, `u64`, `f32`, `f64`, or
  `bool`). Aggregate, string, function, array, and vector/mask results are
  deferred by design.
- Branch bodies may use local `let`, `begin`, nested varying `if`, varying
  `match` over scalar lane values, supported arithmetic/comparison/boolean
  operators, contiguous `array-ref`/`array-set!` over lane element types, and
  accepted SPMD helper calls. Array indexes must still be the `foreach` index
  or a simple uniform offset from it. `array-set!` in a masked branch writes
  only active lanes; `array-ref` reads and checks bounds only for active
  lanes.
- Integer masked value lanes support `bit-and`, `bit-or`, and `bit-xor` for
  every contiguous integer array lane type (`i8`/`u8` through `i64`/`u64`).
  Leading integer literals are contextually typed from the other operand.
  These operators do not accept `f32` or `f64` lanes.
- Masked `shl` and `shr` value lanes support `i32`, `u32`, `i64`, and `u64`
  in AVX2 and AVX-512 modes. Signed `shr` is arithmetic and unsigned `shr` is
  logical. The section 5.4 shift-count rule remains normative: an invalid
  count traps only when its lane is active after intersecting the current
  branch and tail masks. Unsupported `i8`, `u8`, `i16`, and `u16` masked
  shifts are rejected with an operator-, lane-type-, and backend-specific
  diagnostic; they do not silently use a scalar loop.
- Side effects other than supported contiguous `array-set!` and explicit
  `stdlib/atomic.tl` integer element operations are rejected in masked
  branches. This includes `set!` to bindings declared outside the `foreach`,
  `print*`, file/process I/O, `panic`/`error`, allocation whose result
  escapes the branch, nested `foreach`/`spmd-reduce`, and calls outside the
  accepted SPMD helper surface.
- `match` on a varying scalar lane or enum scrutinee supports literal
  patterns, enum tag arms, wildcard arms, and catch-all or enum payload
  bindings whose bound type is a scalar lane value. A varying `match` creates
  one masked arm region per arm; each logical lane evaluates exactly the
  first matching arm, and arm bodies follow the masked branch restrictions.
  Other pattern bindings (aggregate, string, borrowed, function, array) are
  deferred by design.
- A `while` condition inside `foreach` may be varying when it has type
  `bool`. Each loop carries an internal active mask: the first condition
  evaluation uses the parent active mask, and each later evaluation uses only
  lanes whose previous condition was true. The body executes under the
  intersection of the parent, tail, loop-carried, and current-condition
  masks. A lane exits the loop permanently once its condition is false — the
  SPMD form of per-lane early exit — and the whole loop exits once no lane
  remains active.
- Varying `while` bodies follow the masked branch restrictions, including
  nested varying `if`/`match`/`while`. Uniform `while` inside masked
  branches, early exits, gather/scatter through index arrays inside masked
  branches, overlapping ordinary writes, and general atomics are rejected.
- Unsupported constructs in masked branches are rejected at
  type-check/lowering time with diagnostics naming the SPMD
  masked-control-flow restriction. Scalar backend modes do not accept a
  broader masked source surface than SIMD backend modes, and a SIMD backend
  mode that does not implement a masked construct rejects it with a
  diagnostic rather than silently scalarizing (support matrix in section 8).

Explicit SPMD atomic scatter:

- `(import stdlib.atomic)` provides sequentially consistent atomic
  helpers for owned `AtomicI32Buffer` and `AtomicI64Buffer` elements:
  `atomic-i32-load`, `atomic-i32-store!`, `atomic-i32-add!`,
  `atomic-i32-fetch-add!`, and the corresponding `i64` helpers.
- `i32-buffer` and `i64-buffer` allocate zero-initialized owned storage. Atomic
  operations borrow the matching buffer, take an `i64` index, and use the
  element type for add or store values. The private backing storage uses the
  compatibility representation, but no public atomic operation accepts an
  unsized array. There is no public memory-order parameter; all helpers are
  sequentially consistent.
- Inside `foreach`, the helper index and value arguments may be varying. This
  is the only overlap-tolerant scatter update in the source surface; ordinary
  `array-set!` with a varying non-contiguous index remains rejected.
- Atomic helpers synchronize only the exact element they operate on. They do
  not make surrounding non-atomic data race-free and do not permit
  unsynchronized mutation of other fields or array elements.
- Scalar lowering is the reference order: logical iterations execute
  left-to-right. SIMD backend modes may scalarize atomic scatter bodies.
  Masked branches and tails execute an atomic operation only for active
  logical instances; inactive lanes obey the inactive-lane rule above.
- `spmd-reduce` value expressions remain pure: atomic helper calls are
  rejected there along with other function calls and side effects.

```lisp test=check name=spmd-masked-if-scalar-fallback
(import stdlib.array)

(define (clamp-positive [xs : (Array i64)] [out : (Array i64)] [n : i64]) : unit
  (foreach ([i : i64 0 n])
    (if (< (array-ref xs i) 0)
        (array-set! out i 0)
        (array-set! out i (array-ref xs i)))))
```

```lisp test=check name=spmd-masked-if-tail
(import stdlib.array)

(define (copy-even-tail [xs : (Array i64)] [out : (Array i64)] [n : i64]) : unit
  (foreach ([i : i64 0 n])
    (if (= (% i 2) 0)
        (array-set! out i (array-ref xs i))
        (array-set! out i 0))))
```

```lisp test=check name=spmd-masked-if-nested
(import stdlib.array)

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

Reductions and scans are explicit expression forms.

```lisp test=check name=spmd-reduce-sum-i64
(import stdlib.array)

(define (sum-i64 [xs : (Array i64)] [n : i64]) : i64
  (spmd-reduce sum ([i : i64 0 n]) 0 (array-ref xs i)))
```

```lisp test=check name=spmd-reduce-any-bool
(import stdlib.array)

(define (contains-zero [xs : (Array i64)] [n : i64]) : bool
  (spmd-reduce any ([i : i64 0 n]) false (= (array-ref xs i) 0)))
```

```lisp test=check name=spmd-reduce-max-seeded
(import stdlib.array)

(define (max-i64-seeded [xs : (Array i64)] [n : i64] [seed : i64]) : i64
  (spmd-reduce max ([i : i64 0 n]) seed (array-ref xs i)))
```

```lisp test=check name=spmd-scan-sum-i64
(import stdlib.array)

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
- `(spmd-scan op ([i : i64 start end] [prefix : T init]) value body)`
  evaluates a range-wide inclusive scan and has type `unit`. `prefix` is
  visible only in `body`.
- `(spmd-broadcast value lane)` evaluates `value` for the selected source
  lane in the current SPMD gang and makes that scalar value available to
  every active lane in the gang.
- `(spmd-shuffle value lane)` evaluates `value` in the current SPMD gang and,
  for each active destination lane, returns the value from the selected
  active source lane in that same gang.
- `op` is a fixed operator symbol, not an expression: `sum`, `min`, `max`,
  `all`, or `any`. The range clause has the same half-open `[start, end)`
  meaning as `foreach`.

Evaluation and empty ranges:

- `start`, `end`, and `init` are uniform expressions evaluated once before
  any logical iteration. `init` is the accumulator seed and the empty-range
  result.
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
- Integer `sum` uses the modulo-wrapping integer `+` semantics.
- `f32` and `f64` `sum` use the ordered scalar `+` semantics of an explicit
  loop in scalar backend modes. SIMD backend modes may use deterministic
  horizontal lane grouping for eligible contiguous array folds; strict
  bit-for-bit scalar floating-point accumulation order is reserved for future
  FP policy controls. No fast-math reassociation is enabled. NaN payload/sign
  propagation and rounding therefore follow the documented scalar order or
  the backend mode's fixed horizontal tree.

Type rules:

- `sum` supports `i32`, `i64`, `f32`, and `f64`. `min` and `max` support
  `i32` and `i64`. `all` and `any` support `bool`.
- `init` and `value` must have the same supported type for the chosen `op`,
  and the `spmd-reduce` result type is that same type.
- `spmd-scan` uses the same operators but supports only `i32`/`i64` for
  `sum`/`min`/`max` and `bool` for `all`/`any`. `f32`/`f64` scans are
  rejected with a diagnostic noting that floating-point scan ordering is
  deferred by design. `prefix` has the same type as `init` and `value`.
- Narrow integer widths, unsigned integer widths, `char`, `String`, structs,
  enums, tuples, arrays, function values, and vector/mask values are rejected
  as reduction types. `f32` remains rejected for `min`/`max`, as does `f64`.

Backend coverage: scalar lowering covers every supported operator/type
combination above. SIMD backend modes vectorize eligible contiguous array
folds and checked gather-only folds through either an i64 index array or
`i + offsets[program-index]`, and otherwise keep scalar semantics rather than
changing source behavior. AVX2 and AVX-512 also vectorize a canonical
range-wide `spmd-scan` whose value is `input[i]` and whose body directly stores
`prefix` to `output[i]`: full gangs use an inclusive carry-seeded vector prefix
and an in-order scalar tail resumes from the final gang prefix. Other scan
shapes retain the scalar reference lowering. Per-backend matrices are specified
in section 8. Eligible `spmd-shuffle` expressions over the numeric types above
use native AVX2/AVX-512 permutations in `foreach` maps and reduction value
plans.

Purity and varying rules:

- The `value` expression may use the varying index, `(program-index)`,
  `(program-count)`, compatibility dynamic-array reads (including pure
  gather-only reads such as `values[indexes[i]]` and
  `values[i + offsets[program-index]]`),
  arithmetic/comparison/boolean operators over supported types,
  `spmd-broadcast`, `spmd-shuffle`, and local `let` bindings whose values
  satisfy the same rules.
- `value` must not perform writes or other side effects. In particular,
  `set!`, `array-set!`, `print*`, file I/O, `panic`/`error`, nested
  `foreach`/`spmd-reduce`/`spmd-scan`, and user-defined calls with varying
  arguments are rejected.
- `spmd-scan` applies the same purity and index restrictions to `value`.
  `body` must have type `unit` and follows the same side-effect rules as
  `foreach` bodies; nested public SPMD constructs are rejected.
- Reductions by mutating an outer variable inside `foreach` are rejected. Use
  `spmd-reduce` so scalar and SIMD lowering share one explicit accumulator
  contract.

Cross-lane operations:

- `spmd-reduce`, `spmd-scan`, `spmd-broadcast`, and `spmd-shuffle` are the
  public cross-lane source operations.
- `spmd-broadcast` and `spmd-shuffle` are valid only inside a `foreach` body,
  the `value` expression of `spmd-reduce`, or a `spmd-scan` body. They are
  invalid in ordinary expressions, type positions, `foreach` bounds,
  `spmd-reduce` start/end/init expressions, and `spmd-scan`
  start/end/init/value expressions.
- Both support `i32`, `u32`, `i64`, `u64`, `f32`, and `f64` values, and both
  have the value's type as their result type.
- `spmd-broadcast`: `lane` must be a uniform `i64` source-lane slot. If
  `value` is varying, the result is varying; if uniform, it stays uniform.
- `spmd-shuffle`: `lane` has type `i64` and may be uniform or varying. The
  result SPMD class follows `value`; a varying selector does not make a
  uniform `value` varying.
- In scalar backend modes the current gang has one active lane: source lane
  `0` returns `value`, and any other source lane traps through the standard
  out-of-bounds abort path.
- In SIMD backend modes the source lane must be active in the current gang:
  full gangs accept `0 <= lane < gang-width`; tail gangs accept only active
  source lanes. Inactive source lanes trap through the standard out-of-bounds
  abort path. Active destination selectors are validated in increasing logical
  lane order. Inactive tail destination lanes do not evaluate either shuffle
  operand, perform memory effects, or participate in fault selection.
- IR and backend work may add private horizontal-reduction primitives as
  needed to implement `spmd-reduce`; those primitives are not user-denotable
  source operations.

Runtime-dispatched SIMD variants:

Runtime dispatch is declared with a top-level `defdispatch` item. The logical
name is the callable API; each variant names an ordinary top-level function
compiled for one backend mode.

```lisp test=ignore name=simd-dispatch-declaration reason="illustrative dispatch declaration; integration tests cover executable dispatch programs"
(import stdlib.array)

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
  `avx512`. `scalar` is required and is the fallback on every target; `avx2`
  and `avx512` are optional; unknown ISA names are rejected. The `avx512`
  dispatch path requires AVX-512 Foundation, AVX-512BW, AVX-512DQ, and the OS
  ZMM/opmask state needed to execute it, because `avx512` variants may emit
  byte-lane BW instructions and DQ `vpmullq` for `i64`/`u64` multiplication.
- Variant item order is not semantic. The resolver always prefers the best
  runnable listed variant in this order: `avx512`, then `avx2`, then
  `scalar`.
- All variants must be top-level functions with identical parameter and
  return types; the logical dispatch name has that same function type.
- The scalar variant is compiled in scalar mode. ISA variants are compiled
  with their declared backend mode; unsupported body shapes produce
  backend-mode diagnostics rather than silently changing semantics.
- A call to the logical name type-checks like a call to the shared signature.
  Lowering may emit a small wrapper, an indirect call through a cached
  function pointer, or equivalent target code, but the selected body must
  produce the same observable result as the scalar body for all safe programs
  that do not evaluate lane identity forms. A variant that evaluates
  `(program-index)` or `(program-count)` exposes the selected backend mode by
  construction; libraries should only put such functions behind a dispatch
  API when that observation is intended.
- Feature detection happens on the first call to each logical dispatch
  function and the selected target is cached for the life of the process. An
  implementation may instead resolve at program startup if that has the same
  observable behavior.
- Selection may use the same CPUID/XGETBV capability checks exposed by
  `stdlib/cpu.tl` (`runs-avx2?`, `runs-avx512?`), but user code does not
  need to import `stdlib/cpu.tl` to use a dispatched function. Variant
  selection runs no user variant body and performs no user-visible I/O; it
  may read CPU/OS capability state and update hidden dispatch-cache storage.
- A dispatch declaration creates a value-namespace binding for the logical
  name and conflicts with an existing value declaration of that name. Variant
  functions remain ordinary declarations; imported modules call the logical
  name through the normal qualified or selected import rules, and the variant
  functions are ordinary values reachable the same way.
- Diagnostics must cover missing scalar fallback, duplicate variants for the
  same ISA, unsupported ISA names, unknown variant function names, mismatched
  signatures, using the logical dispatch name as one of its own variants, and
  using another dispatch declaration as a variant. The last two rules exclude
  recursive dispatch declarations, whose resolver cycles have no specified
  model.

Reserved and deferred surface:

- Public SIMD vector types, public mask types, and `(varying T)` spellings.
- Non-atomic scatter writes and non-contiguous memory operations beyond
  gather-only reads.
- Lane extraction/insertion, floating-point scans, and general atomics beyond
  the explicit integer element helpers.
- Out-of-line SPMD calls to function values/indirect callees, ordinary extern
  callees, `defdispatch` logical names, and recursive helpers.
- `String`, struct, enum, tuple, function, and nested array lane values.
- Nested public SPMD constructs, task parallelism, multicore scheduling, and
  public AVX-specific intrinsics.

Negative examples:

```lisp test=ignore name=spmd-reject-uniform-masked-while reason="uniform while inside masked branches is rejected"
(import stdlib.array)

(define (clear-prefix [xs : (Array i64)] [out : (Array i64)] [n : i64]) : unit
  (foreach ([i : i64 0 n])
    (if (< (array-ref xs i) 0)
      (while (> n 0)
        (array-set! out i 0))
      unit)))
```

```lisp test=ignore name=spmd-reject-non-atomic-scatter reason="non-atomic scatter writes are rejected"
(import stdlib.array)

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
(import stdlib.array)

(define (sum-array [xs : (Array i64)] [n : i64]) : i64
  (let
    [sum : i64 0]
    (begin
      (foreach ([i : i64 0 n])
        (set! sum (+ sum (array-ref xs i))))
      sum)))
```

```lisp test=ignore name=spmd-reject-f64-min reason="covered by tests/safety/spmd_reduce_f64_min_reject.tl"
(import stdlib.array)

(define (min-f64 [xs : (Array f64)] [n : i64] [seed : f64]) : f64
  (spmd-reduce min ([i : i64 0 n]) seed (array-ref xs i)))
```

```lisp test=ignore name=spmd-reject-shuffle reason="rejected by the parser; the spec example harness only asserts positive check/compile/run"
(import stdlib.array)

(define (bad-cross-lane [xs : (Array i64)] [n : i64]) : i64
  (spmd-reduce shuffle ([i : i64 0 n]) 0 (array-ref xs i)))
```

```lisp test=ignore name=spmd-reject-indirect-varying-call reason="covered by tests/safety/spmd_varying_call_reject.tl"
(import stdlib.array)

(define (inc [x : i64]) : i64 (+ x 1))

(define (map-inc [xs : (Array i64)] [out : (Array i64)] [n : i64]) : unit
  (let
    [f : (-> i64 i64) inc]
    (foreach ([i : i64 0 n])
      (array-set! out i (f (array-ref xs i))))))
```

---

### 5.16 `(with-arena ident body ...)` — scoped region

Introduces a temporary allocation region named `ident` whose lifetime is
the lexical scope of the form's body. The body is a non-empty expression
sequence; the last expression is the result. Subregions are expressed by
nesting `with-arena` forms.

```lisp test=check name=with-arena-basic
(import stdlib.string)

(define (main) : i64
  (with-arena r
    (let
      [s : String (string.int->string 42)]
      (string.string-length s))))
```

**Static escape checking:** Values allocated inside a region are typed as
`(in r T)` (see §3.9). The typechecker rejects any attempt to let a
region-tagged value escape its scope:

- As the result of the `with-arena` form after importing `stdlib.array`
  (`(with-arena r (array.make-array i64 5))`).
- Stored into an outer `let`, `set!`, or global binding.
- Captured by a lambda whose closure outlives the region.
- Returned from an enclosing function.
- Passed to a function call (function parameters carry no region tag).

**Nested regions:** Inner and outer regions are distinct. A value allocated in
an inner region may not escape to the outer region, and a value from an outer
region may be used inside an inner region (it does not gain the inner tag).

**Lowering contract:** Each `with-arena` lowers to a `tl_region_mark` at
entry, the body with all region-allocating operations implicitly targeting the
active region, and a `tl_region_reset` at exit that restores the mark. Because
the body result must be region-free, the reset is safe: no live handle refers
to storage allocated after the mark. A native target must provide the
`tl_region_mark` / `tl_region_reset` runtime helpers before enabling
`with-arena` execution, or document a target-specific limitation.

**First-class arena escape:** `(with-escape arena-expr body ...)` is a
separate scoped form for first-class scratch arenas. `arena-expr` must
typecheck as `arena.Arena` from `stdlib.arena`, such as a handle created by
`arena.make` or `arena.make-atomic`; it is not a lexical region binder and does
not conflict with `with-arena`. A raw `i64` does not satisfy this requirement.

The body is a non-empty expression sequence evaluated with that arena as the
active allocation target. On exit, the result is cloned into the enclosing
active arena when needed, the scratch arena is rewound to its entry mark, and
the active arena is restored. The result surface follows `clone` lowering:
copyable values are returned as-is, `String` values are copied, and cloneable
tuples, fixed arrays, compatibility dynamic arrays, boxes, and named aggregates
are cloned recursively when their elements or fields are clone-supported.
Unsupported result shapes such as function values are rejected. Typechecking
returns the body result type with source-region tags stripped, matching the
clone semantics of moving the result back to the enclosing arena.

**One-shot scratch escape:** `(with-scratch body ...)` is the explicit one-shot
variant of `with-escape`. It creates a fresh first-class scratch arena,
evaluates the non-empty body sequence with that arena active, switches back to
the enclosing active arena, clones the body result when the type requires it,
destroys the scratch arena head, restores the enclosing active arena, and
returns the cloned result. The result surface and source-region stripping match
`with-escape`. `with-arena` continues to reject region-tagged escapes;
clone-out is explicit through `with-escape` for reusable first-class scratch
arenas and `with-scratch` for one-shot scratch work.

**First-class arena target:** `(in-arena arena-expr body ...)` is the safe
dynamic allocation-target form for first-class arena handles. `arena-expr` must
typecheck as `arena.Arena` from `stdlib.arena`. The body is a non-empty
expression sequence evaluated with that arena as the active allocation target;
the previous active arena is restored on normal exit and function-local early
exit. The form does not mark, rewind, destroy, or clone. Its result type is the
body result type unchanged, so owned values allocated in the target arena
remain owned by that arena. When `arena-expr` is a direct local binding
initialized by `arena.make` or `arena.make-atomic`, owner-carrying aggregate
results are checker-tagged with that first-class arena owner identity.
Ordinary `arena.make` owners do not prove thread-spanning lifetime; only
`arena.make-atomic` owner tags can satisfy the task-thread transfer/share owner
proof in section 6.5.

**Arena phase tokens:** `stdlib.arena` exposes `arena.ArenaPhase`,
`arena.phase`, `arena.rewind-safe!`, and `arena.destroy-safe!` as the safe
non-lexical invalidation surface for direct first-class arena owners. The
checker recognizes these calls only for direct local owners initialized by
`arena.make` or `arena.make-atomic`. `arena.phase` records the runtime mark and
advances the checker's generation for later `(in-arena owner ...)` allocations.
`arena.rewind-safe!` consumes a direct local phase token and is accepted only
when no live value, reference, borrow, closure capture, or container slot can
reach an allocation from the token's generation. For atomic owners, the checker
also requires every checker-visible thread user of the owner to have been joined
or otherwise moved through an accepted release point before the rewind.
`arena.destroy-safe!` consumes the direct local owner and is accepted only when
no live value can reach any generation owned by that arena; atomic owners require
the same joined-user proof. Both calls are rejected while executing inside the
same owner through `in-arena`, because the active allocation target would be
invalidated by the operation.

### 5.17 Comptime type reflection

Type reflection is the compile-time-only surface that lets generators inspect
TypeLisp types and emit concrete declarations instead of using source-level
generics or traits. Reflection is a comptime metadata API, not a runtime
type-object API.

The comptime execution model is fixed. The public macro/comptime surface is
the stdlib-owned `Expr` and reflection types. Comptime code is ordinary pure
safe TypeLisp: no `unsafe`, no `extern`, no host I/O, bounded by a
deterministic fuel budget. Source-stdlib CTFE and embedded compiled comptime
code must produce byte-identical expansions for the same input. Every package
emits a `.tlci` compile-time interface (section 5.17.1).

Except for `expr-type`, reflection primitives take `type-expr` operands that
must evaluate at compile time to a type value, usually `(type T)` or a
`[comptime T : type]` parameter. `expr-type` takes an `Expr` captured by a macro
and returns the expression's produced type as the same compile-time type value.
Reflection primitives are valid only in compile-time-required contexts: explicit
`(comptime ...)` folds, comptime parameter evaluation, macro transformer
evaluation, and generated declaration evaluation. Any direct runtime use is
rejected before lowering. A generator that wants a runtime literal derived from
reflection must emit that literal into generated source; the reflection metadata
itself never becomes a runtime value.

Reflection returns CTFE metadata values. `i64` metadata is an integer in the
comptime evaluator. `type` metadata is a type value. `String` metadata is a
compiler-owned comptime string. These strings may be compared and used to build
generated identifiers in comptime code, but they must not be lowered as heap
`String` values. Reflection exposes no list metadata values; the indexed
primitives below are used instead.

The stdlib-owned `TypeInfo` surface in section 3.7.1.2 is the value-level form
of this same reflection contract. The indexed primitives below are the scalar
query API, and the compiled-comptime host ABI exposes the same names as
callbacks. Primitive results and `TypeInfo` values must agree on kind strings,
nominal identity, key generation, and diagnostics.

Primitive names and signatures are fixed as follows:

| Primitive | Result | Notes |
| --- | --- | --- |
| `(expr-type expr)` | `type` | Produced type of a macro-captured `Expr`; does not evaluate the runtime expression. |
| `(type-kind type-expr)` | `String` | One of the fixed kind strings below. |
| `(type-key type-expr)` | `String` | Opaque deterministic key for generated declarations. |
| `(type-cleanup-owning? type-expr)` | `bool` | True exactly for a struct or enum with type-level cleanup metadata. |
| `(type-cleanup-function type-expr)` | `String` | Canonical cleanup-function identity for a cleanup-owning struct or enum; other types reject. |
| `(type-nominal-module type-expr)` | `String` | Canonical module identity for a struct/enum type. |
| `(type-nominal-name type-expr)` | `String` | Unqualified nominal type name for a struct/enum type. |
| `(struct-field-count type-expr)` | `i64` | Requires a struct type. |
| `(struct-field-name type-expr index-expr)` | `String` | Zero-based field name. |
| `(struct-field-type type-expr index-expr)` | `type` | Zero-based field type. |
| `(enum-variant-count type-expr)` | `i64` | Requires an enum type. |
| `(enum-variant-name type-expr index-expr)` | `String` | Zero-based variant constructor name. |
| `(enum-variant-payload-count type-expr index-expr)` | `i64` | Number of payload fields for that variant. |
| `(enum-variant-payload-type type-expr variant-index-expr payload-index-expr)` | `type` | Zero-based payload type. |
| `(array-element-type type-expr)` | `type` | Requires fixed or compatibility dynamic array. |
| `(box-element-type type-expr)` | `type` | Requires `Box`; returns its element type. |
| `(reference-element-type type-expr)` | `type` | Requires `(& region T)` or `(&mut region T)`; returns `T` with the operand's resolved lifetime substitutions. |
| `(array-length type-expr)` | `i64` | Requires fixed array. Compatibility dynamic arrays reject this. |
| `(array-dynamic? type-expr)` | `bool` | True for `(Array T)`, false for `(Array T n)`. |
| `(tuple-element-count type-expr)` | `i64` | Requires tuple type. |
| `(tuple-element-type type-expr index-expr)` | `type` | Zero-based tuple element type. |
| `(function-param-count type-expr)` | `i64` | Requires function type. |
| `(function-param-type type-expr index-expr)` | `type` | Zero-based parameter type. |
| `(function-return-type type-expr)` | `type` | Function return type. |
| `(module-value? module-expr name-expr)` | `bool` | True when the canonically identified module defines the named public value. |
| `(module-value-type module-expr name-expr)` | `type` | Signature type of the named public value; a missing value is a compile-time diagnostic. |

`index-expr`, `variant-index-expr`, and `payload-index-expr` must evaluate to
`i64` in the same comptime context. Out-of-range indices, wrong arity,
non-type operands, and kind mismatches are compile-time diagnostics. The
diagnostic names the primitive and the expected kind, for example
`struct-field-type requires struct type`.

`type-kind` returns one of these lowercase stable strings:

- Builtins: `i64`, `i32`, `i16`, `i8`, `u64`, `u32`, `u16`, `u8`, `f64`,
  `f32`, `bool`, `char`, `string`, `unit`, `never`.
- Shapes: `array`, `dyn-array`, `box`, `function`, `tuple`, `struct`, `enum`.
- Reserved/partial shapes: `str`, `ptr`, `mut-ptr`, `ref`, `mut-ref`,
  `region`, `type-var`.

Reserved/partial shapes are classified by `type-kind` and `type-key`.
`reference-element-type` additionally exposes the referent of shared and mutable
references; it does not expose a runtime reference handle or a separately
inspectable region object. Raw pointer and region detail remains unavailable.
Tuple types can be keyed, classified, and inspected by arity and zero-based
element type; tuple reflection exposes no runtime tuple descriptor.

Module reflection takes compiler-owned comptime `String` values. `module-expr`
is a canonical module identity, such as the result of `module-name` for a
`Module` macro parameter; source import aliases are not module identities.
Lookup observes public value declarations in the current macro environment,
including reachable imported and stdlib modules and declarations emitted by
earlier module/decl macros. Values include functions, globals, externs, and
dispatch declarations. The result is a comptime type value, never a runtime
module or symbol handle. A failed `module-value-type` diagnostic names the
query, module identity, and requested value.

Nominal identity is two-part:

- `type-nominal-module` returns the canonical module identity, not a source
  import spelling.
- `type-nominal-name` returns the declared or generated type name in that
  module's type namespace.

Both primitives reject non-nominal types. Generated nominal declarations use
their generated declaration identity as the nominal name component, so
reflection and generated declaration reuse share the same identity source.

`type-key` is a compiler-owned ASCII string. It is stable across compiler runs
for the same canonical type graph and is suitable as an input to generated
declaration keys; it is not a display format and programs must not parse it.
The key is built from tagged, length-prefixed components so module names, type
names, and recursive subkeys cannot collide. Conceptually, the rules are:

- Builtins key by their stable lowercase kind string.
- Fixed arrays key as `(array length element-key)`.
- Compatibility dynamic arrays key as `(dyn-array element-key)`.
- Functions key as `(function param-count param-key... return-key)`.
- Nominal structs/enums key as `(nominal kind module-identity type-name)`.
- Pointer/reference/region keys include mutability and the referenced/pointee
  type key; reference keys also include the canonical region identity.

The implementation must resolve aliases before keying, preserve nominal
struct/enum identity rather than structuralizing it, and use the same key rules
when composing generated declaration identities. Display names derived from
keys may use a readable mangling, but the key itself remains opaque.

Intended generator uses: concrete collection families key their element type
with `type-key` and emit names such as `Vec_I64` or `Map_String_I64`; concrete
`Option*` / `Result*` families key payload and error types with the same rules
as section 9; serializer, equality, hashing, and debug-print helpers iterate
`struct-field-*` / `enum-variant-*` metadata to emit direct field/variant code
for one nominal type; function adapters inspect `function-param-*` /
`function-return-type` to generate arity-specific wrappers without runtime
type objects.

Exclusions:

- Layout size, alignment, and field offset queries belong to the layout-query
  surface in section 5.18 and are not aliases for reflection primitives.
- Raw pointer and region details beyond kind and key are not exposed. Reference
  reflection exposes only the referent type described above.
- Module reflection does not expose runtime module handles, enumerate module
  contents, or provide feature-specific hook queries.
- Runtime type IDs, runtime reflection, trait/interface lookup, method tables,
  and type-erased dispatch are not part of this surface.
- Reflection metadata strings are not runtime `String` allocation hooks.

#### 5.17.1 TypeLisp comptime image (`.tlci`) v2

A TypeLisp comptime image (`tlci`) is the package compile-time interface. Every
package emits one: a metadata-only image carries signature/layout metadata, and
a package that defines macros additionally carries compiled comptime code. The
runtime archive (`lib<name>.a` / `<name>.lib`) is separate. This section
specifies the v2 container and its independently versioned metadata schemas.

The container is a custom little-endian binary format shared by Linux and
Windows. It is not ELF or COFF. The first 176 bytes are a fixed header:

| Offset | Size | Field |
| ---: | ---: | --- |
| 0 | 8 | Magic bytes `54 4c 43 49 0d 0a 1a 0a` (`TLCI\r\n\x1a\n`) |
| 8 | 8 | Format version (`2`) |
| 16 | 8 | Host architecture enum, `1 = x86_64` |
| 24 | 8 | Callback ABI version (`2`) |
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
| 152 | 8 | Host import section byte offset, or `0` when empty |
| 160 | 8 | Host import record count |
| 168 | 8 | Total file size in bytes |

The compiler build hash payload is the producer-compiler identity. Producers
encode the full 40-byte lowercase Git object name of the checked-in compiler
revision that encoded compiler-internal data. The identity excludes host OS,
build date, checkout path, and temporary build location, so equivalent Linux
and Windows compiler builds carry identical bytes. A consumer may use native
callback catalogs when their host ABI/schema checks succeed, but it must not
hydrate compiler-internal frontend surfaces unless this identity exactly
matches the running compiler. Missing, legacy, malformed, and stale identities
take the source rebuild path.

All integer fields are unsigned logical values encoded in little-endian 64-bit
slots; values that do not fit the `i64` range are rejected. The metadata
section starts on an 8-byte boundary. Rodata and code sections are page-aligned
at 4096-byte offsets so a loader can map them directly. Fixup, entry, and
symbol, and import sections are 8-byte aligned. Empty sections must use offset
`0` and count/length `0`.

The content hash is a deterministic integrity check over the full file with the
8-byte hash field treated as zero. It is the rolling hash
`hash = (hash * 131 + byte) mod 2147483647` with seed `1`. This is an
integrity/versioning guard, not a cryptographic authenticity mechanism. A
loader must reject hash mismatches before trusting offsets or metadata.

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

Table bytes are opaque beyond count/size validation until consumed; a loader
must validate referenced name ranges and code offsets before use.

The host import section is the mirror of an export table. A non-empty section
starts with an 8-byte record count equal to the header field, followed by
24-byte records and a packed UTF-8 name blob:

| Record offset | Size | Field |
| ---: | ---: | --- |
| 0 | 8 | Image-base-relative address of one writable 8-byte GOT slot |
| 8 | 8 | Name byte offset relative to the import section |
| 16 | 8 | Name byte length |

Names are non-empty and their ranges must follow the complete record array and
stay inside the import section. Slot addresses must be 8-byte aligned and lie
inside a mapped rodata or code section. Normal-backend images place the slots
in their code-region GOT. The mapping is writable while loading; after
load-base fixups and import binding, the loader seals rodata read-only and code
read/execute, so import slots are not mutable during execution.

Before any image entry or comptime macro can run, the loader resolves every
name in the compiler's static host callback registry and writes the callback's
raw address into the corresponding slot. An unresolved name rejects the image
and the diagnostic includes the package identity and missing import name.
Duplicate or empty registry names and null registry addresses reject the host
table before mapping. No OS dynamic-symbol lookup participates in this step.

##### 5.17.1.1 Auxiliary rodata sections

The rodata section may carry an independently versioned, package-agnostic
auxiliary-section envelope. This is an additive encoding inside rodata, not a
metadata-schema version. Existing package-specific rodata is the base payload.
Auxiliary payloads follow it at 8-byte-aligned offsets, followed by an ordered
directory and a fixed 48-byte trailer.

Each 40-byte directory record contains five little-endian u64 fields: positive
section kind, positive section schema version, payload offset, payload byte
length, and the v1 rolling hash of that payload. Kinds are strictly increasing,
payloads do not overlap the base payload, directory, or each other, and every
payload offset is 8-byte aligned. V1 assigns kinds `1 = package identity`,
`2 = frontend AST`, `3 = frontend types`, and `4 = frontend facts`.

The trailer contains six little-endian u64 fields: magic `TLCIAUX1`, auxiliary
format version (`1`), base-rodata byte length, directory offset, record count,
and total rodata byte length. A missing trailer means that the image has no
auxiliary sections. A recognized trailer with an unsupported version, invalid
range/order/alignment, length mismatch, or payload-hash mismatch is malformed
and must not be partially consumed. Unknown positive kinds may be ignored.

Frontend surface deployments key their identity section by package name,
canonical module set, source-closure hash, producer compiler build, and target
configuration. Each payload schema is independently versioned. Consumers must
validate the complete key against independently trusted package/source/build
inputs before hydrating any AST, type, intern identity, or checked fact.

##### 5.17.1.2 Host ABI handshake

The tlci header field at byte offset 24 is callback ABI version `2`. This is a
hard cutover: a loader rejects a code-bearing image whose callback ABI is not
`2`, and it validates the host callback table as version `2` before mapping
the image. There is no numeric-dispatch or callback-ABI-v1 compatibility path.

A code-bearing image exports one native entry point named `tlci_image_entry`.
The host calls it with the host platform's ordinary C integer calling
convention. A tlci image always executes on the host architecture named in the
header; code for the consumer program's runtime target remains separate
runtime output:

| Position | Type | Meaning |
| ---: | --- | --- |
| 0 | pointer-sized integer | Address of the read-only host callback table |
| 1 | pointer-sized integer | Address of a writable image registration record |
| return | `i64` status | `0` on successful registration; nonzero values are reserved diagnostics |

The callback table's image-visible prefix remains 64 bytes. ABI v2 retires the
old `invoke` slot and reserves it as zero:

| Offset | Size | Field |
| ---: | ---: | --- |
| 0 | 8 | Magic little-endian u64 for ASCII `TLCIHOST` |
| 8 | 8 | Host callback ABI version (`2`) |
| 16 | 8 | Callback table byte size; must be at least `64` |
| 24 | 8 | Opaque host context pointer, or `0` |
| 32 | 8 | Reserved, must be `0` |
| 40 | 8 | Reserved, must be `0` |
| 48 | 8 | Reserved, must be `0` (the removed v1 numeric `invoke` slot) |
| 56 | 8 | Required `abort` callback function pointer |

The compiler's in-language host object pairs that raw prefix with a loader-only
registry of UTF-8 callback names and raw function addresses. The registry is
not copied into the image-visible prefix. Its rows are unique and non-empty,
its addresses are nonzero, and its name/address storage covers at least its
declared row count.

Generated comptime code declares one extern value per operation and calls the
loader-patched GOT slot directly. A named callback uses the host C ABI:

| Position | Type | Meaning |
| ---: | --- | --- |
| 0 | pointer-sized integer | Opaque host context carried by the macro entry |
| 1 | pointer-sized integer | Opaque expansion/session context |
| 2 | `i64` | Callback-specific argument A |
| 3 | `i64` | Callback-specific argument B |
| 4 | `i64` | Callback-specific argument C |
| return | `i64` | Callback-specific status or scalar data result |

Each named function owns its return contract. Status-returning callbacks latch
the first nonzero session status and later callbacks return it without
mutation. Data-returning probes return their nonnegative scalar answer
directly and use a negative malformed-request sentinel; a nonzero data answer
is not a session failure. There is no separate operation-id argument, central
numeric catalog, or hand-maintained data-operation exception list.

The `abort` callback is for native image failures that cannot be represented
as a normal macro diagnostic. Its fixed host-C-ABI signature is:

| Position | Type | Meaning |
| ---: | --- | --- |
| 0 | pointer-sized integer | Opaque host context from the table |
| 1 | pointer-sized integer | Opaque expansion/session context, or `0` before macro dispatch |
| 2 | `i64` | Abort reason/status code |
| 3 | pointer-sized integer | Optional message byte pointer |
| 4 | `i64` | Message byte length |
| 5 | `i64` | Optional tlci symbol-table id/offset for symbolized native failures, or `0` |
| return | `i64` status | `0` when the host recorded the abort |

Callback status values are fixed:

| Value | Meaning |
| ---: | --- |
| 0 | Success |
| 1 | Macro diagnostic was reported |
| 2 | Macro fuel exhausted |
| 3 | Native macro panic/abort |
| 4 | Bad callback request or malformed arguments |

Macro diagnostics call the named `diagnostic` callback and return status
`1`. `fuel-check` returns status `2` when the expansion has exhausted its
fuel. Native traps and explicit aborts use status `3`. Malformed arguments,
bad handles, and invalid scratch requests return status `4`. Adding an
operation requires a distinct callback function, one unique registry row, and
the same name at its producer emit site; there is no number to allocate or
renumber.

The image fills the writable registration record before returning success. The
v2 registration record keeps the 48-byte header shape and appends the macro
entry table:

| Offset | Size | Field |
| ---: | ---: | --- |
| 0 | 8 | Magic little-endian u64 for ASCII `TLCIIMAG` |
| 8 | 8 | Host callback ABI version used by the image (`2`) |
| 16 | 8 | Registration record byte size; must be at least `64` |
| 24 | 8 | Opaque image context pointer for later dispatch, or `0` |
| 32 | 8 | Reserved, must be `0` |
| 40 | 8 | Reserved, must be `0` |
| 48 | 8 | Macro entry table pointer, or `0` when the image registers no macros |
| 56 | 8 | Macro entry record count; must be `0` when the table pointer is `0` |

Each macro entry record is 32 bytes and is owned by the image for the lifetime
of the mapping:

| Offset | Size | Field |
| ---: | ---: | --- |
| 0 | 8 | Macro name byte pointer |
| 8 | 8 | Macro name byte length |
| 16 | 8 | Macro entry function pointer |
| 24 | 8 | Reserved, must be `0` |

A macro entry function uses the host C ABI:

| Position | Type | Meaning |
| ---: | --- | --- |
| 0 | pointer-sized integer | Opaque image context from registration |
| 1 | pointer-sized integer | Opaque host context from the callback table |
| 2 | pointer-sized integer | Opaque expansion/session context |
| 3 | pointer-sized integer | Address of an array of operand handles |
| 4 | `i64` | Operand count |
| 5 | pointer-sized integer | Address of one writable result-handle slot |
| return | `i64` status | Same status values as the host callbacks |

Macro operands, generated `Expr` values, reflected metadata, and strings cross
this boundary only as host-owned handles or scalar values. Native macro code
constructs public values through named callbacks and must not mutate compiler
AST/typechecker structures directly. The host creates a fresh session for one
macro invocation. On diagnostic, fuel exhaustion, abort, or any other nonzero
status, it discards that session state; only recorded diagnostics survive.
Successful expansion commits exactly one result handle.

Native-comptime helpers carry image context, host context, and session context
through their call graph. A status-returning helper immediately unwinds a
nonzero result without committing its public result slot. This is the
deterministic fuel-check insertion boundary for calls and loop backedges.

ABI v2 accepts larger raw callback and registration records when their magic,
exact ABI version, minimum byte size, required pointers, table/count
consistency, and reserved-zero fields are valid; unknown tails are ignored.
Format, callback-ABI, and registration version mismatches are diagnostics.
Stale v1 images are rejected rather than rebound. The embedded stdlib tier and
package images use this same named-import linker and callback registry.

The metadata section is UTF-8/ASCII S-expression text with stable field order:

```lisp test=ignore name=tlci-metadata-schema reason="tlci metadata S-expression, not TypeLisp source"
(typelisp-tlci-metadata
  (version "v1")
  (package (name "pkg-name") (version "0.1.0")))
```

`version` gates the schema. `package` gives the package identity as it appears
in `typelisp.pkg`. Unknown fields, unsupported versions, malformed
S-expressions, empty required sections, bad magic/version/arch/ABI/hash, and
truncated section ranges are diagnostics.

Metadata schema v2 keeps the container format version and callback ABI version
at `2`. It retains the v1 fields and may append `spmd-callables` after
`package`:

```lisp test=ignore name=tlci-metadata-schema-v2 reason="tlci metadata S-expression, not TypeLisp source"
(typelisp-tlci-metadata
  (version "v2")
  (package (name "pkg-name") (version "0.1.0"))
  (spmd-callables
    (helper
      (name "module.helper")
      (signature "(-> i64 i64)")
      (specialization
        (abi "spmd-call-v1")
        (backend "avx512")
        (lanes 8)
        (args "v")
        (result "v")
        (index-param -1)
        (symbol "__tl_spmd_pkg_module_helper_v8")))))
```

Each helper `name` is its canonical module-qualified source name and
`signature` is its canonical resolved ordinary source signature. A helper has
one or more specialization records. Records are ordered by helper name,
signature, backend, lanes, args, result, index-param, and symbol; duplicate or
out-of-order records are invalid. `abi` independently versions the private
active-mask call convention. Unknown nonempty ABI strings are preserved so
ordinary importers can still read the helper signature; selecting such a
specialization is an unsupported-capability diagnostic.

For `spmd-call-v1`, `backend` is `scalar` or `avx512` (AVX2 has no v1 record),
`lanes` is positive and is `1` for scalar, and `args` is a comma-free positional
string of `u`/`v` classes whose length equals the ordinary parameter count.
`result` is `unit`, `u`, or `v`. `index-param` is `-1` or a zero-based varying
source parameter that supplies the logical `foreach` index and accounts for the
hidden uniform index-base ABI operand. `symbol` is the exact nonempty,
target-independent TypeLisp linker symbol in the package runtime archive.
Helper names and signatures are nonempty. Metadata v1 images continue to parse
and emit without this field and remain byte-layout compatible.

Metadata-only tlci files are valid: rodata, code, fixups, entries, symbols, and
imports are all empty. Emission is deterministic: an image's layout and
content hash round-trip byte-identically.

`typelisp inspect <file.tlci>` parses a tlci image with the same validation
path as loaders and prints a stable human-readable header, section table, and
package metadata. Malformed images surface the tlci parse diagnostic.

### 5.18 Layout queries

Three comptime-only query forms expose type layout:

```lisp test=ignore name=default-layout-query-syntax reason="illustrative layout query example; not a standalone program"
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

The `(with ...)` form provides explicit scoped cleanup of non-memory resources
such as file descriptors, process handles, temporary files, locks, and mapped
files. It is separate from `(with-arena ...)`: `with` calls cleanup functions
for resource values, while `with-arena` resets arena allocation for memory
owned by a lexical region.

Each binding has the form `[name init-expr cleanup-fn]`.

- `init-expr` is evaluated and bound to `name`.
- `cleanup-fn` must name or evaluate to a function of type `(-> T unit)`, where
  `T` is the type of `name`. If it is an expression, it is evaluated after
  `init-expr` succeeds and before the next binding begins.
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

In the example above `inner` is closed before `outer`. Nested `with` forms
compose in the same way: the inner scope cleans up before execution continues
in the outer scope.

Cleanup runs when the body exits normally, and before a recoverable early
return (`try` propagation) leaves the scope: a body such as
`(with ([h (open-handle) close-handle]) (try (read-handle h)))` closes `h`
before the propagated failure leaves the `with` scope. Already-initialized
earlier bindings are cleaned up when a later initializer propagates a
recoverable failure. Panic/abort remains terminal and does not guarantee
cleanup unless a future unwinding model explicitly says so.

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
For cleanup-owning aggregate types (section 4.7.1), the explicit cleanup
function must be the aggregate type's declared cleanup function. The field
cleanup plan is then run by that aggregate cleanup function; `with` itself still
only owns the bound value and invokes one cleanup function per binding.

---

### 5.20 `(unsafe body ...)` and raw pointer operations

`unsafe` is the source marker for operations whose safety cannot be proven by
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
function and extern declarations use the `(unsafe declaration)` wrapper
described in section 4.3.1; there is no module-wide unsafe mode.

The unsafe operation set:

| Form | Safe? | Type rule | Notes |
|------|-------|-----------|-------|
| `(ptr-null : (Ptr T))` / `(ptr-null : (MutPtr T))` | Yes | returns the requested raw pointer type | Constructs a typed null pointer. |
| `(ptr-null? p)` | Yes | raw pointer -> `bool` | Does not dereference `p`. |
| `(ptr-read p)` | Unsafe | `(Ptr T)` or `(MutPtr T)` -> `T` | Reads `sizeof(T)` bytes at `p`; alignment, validity, initialization, and lifetime are caller obligations. |
| `(ptr-write! p value)` | Unsafe | `(MutPtr T)` and `T` -> `unit` | Writes `sizeof(T)` bytes; writing through `(Ptr T)` is rejected. |
| `(ptr-offset p n)` | Unsafe | raw pointer and integer -> same raw pointer type | Adds `n * sizeof(T)` bytes. Negative offsets are allowed but unsafe. |
| `(ptr-cast p : (Ptr T))` / `(ptr-cast p : (MutPtr T))` | Unsafe | raw pointer -> requested raw pointer type | Includes const/mutable pointer casts; there is no implicit `MutPtr` to `Ptr` coercion. |
| `(ptr-addr-of place)` | Unsafe | addressable storage place of type `T` -> `(MutPtr T)` for owned local/parameter roots | Produces a raw pointer to compiler-known storage without creating a checked borrow or lifetime pin. |
| `(ptr->int p)` | Unsafe | raw pointer -> `u64` | Exposes the target address representation. |
| `(int->ptr n : (Ptr T))` / `(int->ptr n : (MutPtr T))` | Unsafe | integer -> requested raw pointer type | Address validity is entirely outside the typechecker. |
| `(atomic-load p)`, `(atomic-store! p v)`, `(atomic-add! p d)`, `(atomic-fetch-add! p d)`, `(atomic-cas! p expected new)` | Unsafe | raw pointer atomics for `T` in `i32`, `i64`, `u32`, or `u64`; update forms require `(MutPtr T)` and matching values | Sequentially consistent x86-64 memory operations. Load returns `T`; store/add return `unit`; fetch-add and CAS return the previous value observed at `p`. |
| `(volatile-load p)`, `(volatile-store! p v)` | Unsafe | raw pointer volatile access for `T` in `i32`, `i64`, `u32`, or `u64`; stores require `(MutPtr T)` and matching values | Emits exactly one load or store memory access for each source operation and prevents elision, reordering, common-subexpression elimination, loop-invariant hoisting, and folding of that operation. Volatile does not provide inter-thread memory ordering; use atomics for synchronization. |
| `(syscall number arg0 ... arg5)` | Unsafe | integer operands -> `i64` | Issues a raw Linux x86_64 host syscall. The number plus up to six arguments are passed directly to the kernel ABI; argument validity, pointer lifetimes, platform availability, and side effects are caller obligations. |

`stdlib.ffi` provides caller-owned C string marshalling helpers on top of
this raw-pointer surface. `ffi-c-bytes-required-bytes` computes
`bytes-length + 1`, `ffi-c-bytes-interior-nul?` rejects byte slices that cannot
be passed to ordinary NUL-terminated C APIs, and `ffi-c-bytes-copy!` copies into
a caller-provided `(MutPtr u8)` with an explicit capacity before writing the
trailing NUL byte. The helper returns a structured result for success,
interior-NUL input, or too-small buffers; it does not allocate, does not create
implicit `String -> Ptr` or `bytes -> Ptr` coercions, and does not extend the
input slice's lifetime. The `ffi-c-string-*` compatibility wrappers borrow their
`String` input as `(& r bytes)` and delegate to the byte-slice implementation.

`ptr-addr-of` addressable places are:

- A whole local or parameter storage slot, including scalar and aggregate
  locals/parameters.
- A struct field path rooted in an addressable local or parameter, written as
  `(struct-get place field)` or equivalent local dotted-field sugar.
- A fixed-array element path rooted in addressable storage, written as
  `(array-ref place index)`. The root must have fixed-array type
  `(Array T N)` at that projection; compatibility dynamic `(Array T)` element
  sugar is not addressable in v1. The element index is checked with the same
  bounds policy as fixed-array element access before the pointer is returned.

The operation's result type is `(MutPtr T)` for the selected owned storage of
type `T`. V1 does not define reference-rooted address-of. A later design may
allow reference roots, in which case immutable roots should produce `(Ptr T)`
and mutable roots `(MutPtr T)`.

The checker only verifies that the form appears in an unsafe context and that
the operand is a storage-backed addressable place. Taking a raw address does
not mark the place borrowed, does not keep it live, and does not prevent later
owner moves, assignment, arena reset/destroy, or aliasing through other unsafe
operations. Escaping, storing, or using the pointer after the owner becomes
invalid is entirely the caller's responsibility.

The lowerer must derive field and element addresses from the original storage
root, not by first loading or copying the aggregate value. The expected shape
is address-of the root storage slot followed by target-layout field offsets or
element-size address derivation.

Outside the raw-pointer surface: address-of globals, temporaries, enum payload
projection, tuple projection, box projection, compatibility dynamic-array
element sugar, slice views, provenance tracking, pointer
comparisons beyond `ptr-null?`, pointer-to-function casts, and any
borrow-checked reference surface. Pointer-to-aggregate-field or
pointer-to-array-element support does not imply by-value aggregate extern ABI
support; C ABI aggregate argument and return classification remains a separate
backend concern.

---

## 6. Built-in functions and runtime

### 6.1 Core builtins

The compiler owns a small core builtin surface: element operations over
fixed-size arrays, a small set of string indexing/slicing primitives, and
the CPU instruction intrinsics. Everything else — including printing,
`panic` / `error`, and all richer I/O — is ordinary standard-library code
imported with dotted imports: I/O in `stdlib.io` and `stdlib.fs`, process
arguments and environment in `stdlib.env`, CPU capability checks in
`stdlib.cpu`, string inspection and parsing in `stdlib.string`, and string
building in `stdlib.str_cat` / `stdlib.text_buf`. Unimported uses of stdlib
names are unbound source names. The backend may emit private runtime symbols
used by the stdlib extern wrappers; user code must not call private names
directly.

**Printing and failure.** `print`, `print-bool`, `print-newline`,
`print-string`, `print-error`, `panic`, and `error` are ordinary `stdlib.io`
definitions; unimported uses are unbound source names. `panic` and `error`
report a failure and terminate the process; `error` is an alias for `panic`,
and both have return type `never` (section 9).

An unbound compatibility name that is known to come from the standard library
has a structured help diagnostic naming its provider and the import to add.
Other unbound names receive a `did you mean NAME?` help diagnostic when a
deterministic best candidate is within the checker's bounded spelling distance
among names visible at that source location.

**CPU intrinsics.** The low-level CPU instruction forms `cpuid-eax`,
`cpuid-ebx`, `cpuid-ecx`, `cpuid-edx`, and `xgetbv` are compiler intrinsics.
Public CPU capability checks use `stdlib.cpu`. The private polymorphic
`__tl_float_sqrt` intrinsic accepts exactly one `f64` or `f32` and lowers to
SSE2 `sqrtsd` or `sqrtss`. Results follow the active MXCSR rounding mode and
the instruction's IEEE-754 special-value behavior. The private polymorphic
`__tl_float_to_bits` and `__tl_float_from_bits` intrinsics reinterpret
`f64`/`u64` or `f32`/`u32` values without conversion. They lower to the
existing register bitcast operation and never allocate or call a runtime
symbol. Public `stdlib.math.f64-sqrt` and `stdlib.math.f32-sqrt` wrappers expose
typed square root, and `stdlib.math.sqrt` evaluates one `f64` or `f32`
expression once while preserving its type. They emit the matching scalar SSE2
instruction without allocation, runtime calls, libm, or CRT dependencies.
Under the default MXCSR round-to-nearest, ties-to-even mode, positive finite
normal and subnormal inputs are correctly rounded, signed zeros retain their
sign, positive infinity is unchanged, and negative inputs produce NaN. NaN
results follow the hardware contract; signaling-NaN payload, quieting, and
exception details are not promised. Other public typed wrappers,
classification/sign helpers, exact special values, and `scalbn`-style
power-of-two scaling live in `stdlib.math`.
Float bit reinterpretation preserves every bit, including signed zero and NaN
payloads. The scaling helpers follow IEEE-754 arithmetic under the active
rounding environment; the default environment is round-to-nearest, ties to
even. Private float intrinsics are runtime-only; CTFE continues to reject
non-finite construction and unsupported float operations.

`stdlib.math` also provides freestanding `f64-sin`, `f64-cos`, `f64-tan` and
binary32 counterparts. They share a full-finite-range `pi/2` reducer and use
precision-specific polynomial kernels without allocation, extern calls, x87
transcendentals, or an FMA requirement. In the default round-to-nearest mode,
their maximum error is below 1.5 ULP. Sine and tangent preserve signed zero,
cosine of either zero is exactly one, infinities produce NaN, and NaN inputs
remain NaN. Floating exception flags and signaling-NaN payload behavior are
not part of this initial contract.

`stdlib.math.f64-exp` and `stdlib.math.f32-exp` provide natural exponential
functions through deterministic table reduction and polynomial evaluation.
`stdlib.math.exp` preserves an `f64` or `f32` operand type and evaluates its
expression once. Under the default round-to-nearest, ties-to-even mode, finite
results are within one ULP; overflow returns positive infinity and underflow
is gradual through subnormals. Both signed zeros map to one, negative infinity
maps to zero, positive infinity is unchanged, and NaNs remain NaN. The
implementations allocate no storage and reference no runtime, libc, libm, CRT,
x87 transcendental, or FMA facility.

`stdlib.math.f64-log` and `stdlib.math.f32-log` provide natural logarithms
through deterministic bit decomposition, table reduction, and polynomial
evaluation; binary64 uses the non-FMA compensated reduction. `stdlib.math.log`
preserves an `f64` or `f32` operand type and evaluates its expression once.
Under default round-to-nearest, ties-to-even mode, finite results are within
one ULP. Either signed zero maps to negative infinity, negative finite values
and negative infinity produce NaN, one maps to positive zero, positive infinity
is unchanged, and NaN inputs remain NaN. Floating exception flags and
signaling-NaN payload behavior are outside the initial contract. The
implementations allocate no storage and reference no runtime, libc, libm, CRT,
x87 transcendental, or FMA facility.

**Fixed-array element operations.** The public `Array` type is the fixed
`(Array T N)` form. The core element operations are:

| Builtin | Signature | Description |
|---------|-----------|-------------|
| `length` | `(Array T N) → i64` / `String → i64` | Fixed-array element count; string byte length |
| `array-length` | `(Array T N) → i64` | Alias for array `length` |
| `array-ref` | `(Array T N) i64 → T` | Bounds-checked read through an owned array or an immutable or mutable reference receiver |
| `array-set!` | `(Array T N) i64 T → unit` | Bounds-checked write through an owned array or mutable reference receiver |

**Core string primitives.** The following string operations are
compiler-owned:

| Builtin | Signature | Description |
|---------|-----------|-------------|
| `string-copy` | `(& r str) → String` | Fresh active-arena copy of borrowed text |
| `substring` / `string-slice` | `(& r str) i64 i64 → String` | Fresh string of `len` bytes at byte offset `start` (a `[start, start+len)` slice); bounds checked |
| `substring-view` / `string-slice-view` | `(& r str) i64 i64 → (& r str)` | Borrowed view of the same range; bounds checked; copies no bytes |
| `int->string` | `i64 → String` | Format integer as decimal string |

Owned `String` arguments place an auto-borrow at typed call sites. Per the
section 3.11 contract, non-consuming text inputs take `(& lifetime str)`
while allocating operations return owned `String`.

**Bounds checks and traps.** `array-ref`, `array-set!`, the imported
`string-ref`, and `substring` / `string-slice` / `substring-view` perform
runtime bounds checks. An out-of-bounds access calls the `tl_oob_abort`
runtime trap, which writes to stderr and exits with code 134. Slice ranges
are checked with unsigned arithmetic, so a negative `start` / `len` wraps to
a huge value and traps.

**String inspection (`stdlib.string`).** Public string inspection and
parsing helpers are stdlib definitions, unbound until the module is
imported:

| Helper | Signature | Description |
|--------|-----------|-------------|
| `string-length` | `String → i64` / `(& r str) → i64` | String byte length |
| `string-ref` / `char-at` | `(& r str) i64 → char` | Read byte from string (bounds checked) |
| `string-eq` / `string=?` | `(& l str) (& r str) → bool` | Byte-wise string comparison |
| `string->int` | `(& r str) → i64` | Decimal parse; legacy decimal parser rules |

These helpers lower through private compiler-owned intrinsics
(`__tl_string_length`, `__tl_string_ref`, `__tl_string_eq`,
`__tl_string_to_int`). Owned `String` arguments auto-borrow at typed call
sites.

**String building.** Fixed-arity string concatenation is the stdlib macro
`stdlib.str_cat`'s `(str_cat.str-cat ...)`; incremental builders use
`stdlib.text_buf`. `str-cat` uses direct one-allocation `stdlib.string`
helpers for two to five operands and expands longer calls to an internal
`string.concat-all` call over a packed `(Array String)`, so long calls
allocate no chunk intermediates. The deprecated `string-append` and
`string-concat` names remain staged lint targets for old source, while
`tl_string_concat*` remains a runtime-plan compatibility ABI documented below.

**Byte buffers.** `ByteBuf` and `bytes` are specified in section 3.11 as
stdlib/language surface, not implicit compiler builtins. There is no
implicit conversion from text, arrays, or raw pointers to byte buffers;
binary APIs use explicit borrow/copy helpers.

**Internal array compatibility.** Unsized `(Array T)` and the `make-array`,
`array-push!`, and `array-data` forms are an internal compatibility surface,
not a public growable-collection API. Public growable collections route
through `stdlib.vector`, take `&` / `&mut` receivers where possible, and
mutate storage in place. The compatibility forms keep their runtime
contracts:

- `make-array` checks the runtime length before allocation: a negative
  length or `length * sizeof(type)` overflow calls the same `tl_oob_abort`
  trap used by bounds checks. For positive lengths every live element is
  initialized per the `init` eligibility rules in section 5.12.1; bulk
  zero/fill helpers are implementation details, and safe code observes
  initialized source values.
- `array-data` returns a raw `(MutPtr T)` to element storage, requires an
  enclosing `(unsafe ...)` expression, and exists only for runtime, FFI, and
  internal compatibility code that must pass raw storage pointers.

### 6.2 Runtime functions (emitted by the backend)

The compiler emits helper routines into the generated assembly when needed.
They are not implemented by a separate C runtime.

Stdlib APIs that are thin wrappers over platform facilities are not backend
runtime helpers: `stdlib.io`, `stdlib.env`, `stdlib.fs`, and `stdlib.cpu`
bind platform symbols directly with `extern` and select target-specific
implementations with `cfg`, and `stdlib.msvc` owns Windows MSVC/link.exe and
SDK discovery through stdlib environment, filesystem, and process helpers.
Low-level language forms expose entry `argc`/`argv`/`envp`, raw string/array
storage, and CPU instructions where ordinary FFI cannot. The backend-owned
core runtime subset is limited to helpers that cannot be expressed as
allocation-free, import-free TypeLisp with equivalent codegen:

| Symbol(s) | Disposition |
|-----------|-------------|
| `tl_alloc`, `tl_region_mark`, `tl_region_reset`, `tl_arena_make`, `tl_arena_make_atomic`, `tl_arena_current`, `tl_arena_set`, `tl_arena_destroy`, `tl_arena_poison_enable`, `tl_thread_init`, `tl_thread_entry_ptr` | Core allocator/arena/TLS substrate. Current-arena TLS reads/writes can be expressed from TypeLisp with the `tls-current-arena` intrinsics below; page ownership, region reset, arena creation/destruction, thread entry, and public raw helper compatibility remain backend-owned. |
| `tl_memcpy`, `tl_memchr`, `tl_tlci_call_image_entry` | Core primitives: `tl_memcpy` is the overlap-safe bulk-copy primitive used by source code and lowering; `tl_memchr` is the allocation-free borrowed byte search; `tl_tlci_call_image_entry` is the raw C-ABI bridge used by the tlci loader to call a mapped `tlci_image_entry` address with the host callback table and writable image registration record. |
| `__chkstk` | Windows/MSVC ABI helper required for large stack frames. |
| `tl_setup_argv`, `_tl_start` | Windows freestanding entry bootstrap: build argv from `GetCommandLineA`, clear the current-arena TEB slot, call `main`, exit through `ExitProcess`. |
| `tl_profile_alloc_total`, `tl_profile_alloc_live`, `tl_profile_alloc_peak`, `tl_profile_alloc_reset_peak` | Stdlib profile accessors backed by counters maintained inside the allocator core. |
| `tl_substring`, `tl_str_view`, `tl_string_concat`, `tl_string_concat3`, `tl_string_concat4`, `tl_string_concat5`, `tl_int_to_string` | Runtime-plan compatibility names; implementations are TypeLisp exports. |
| `tl_atomic_i64_load_ptr`, `tl_atomic_i64_store_ptr`, `tl_atomic_i64_add_ptr`, `tl_atomic_i64_fetch_add_ptr`, `tl_atomic_i64_cas_ptr`, `tl_atomic_i32_load_ptr`, `tl_atomic_i32_store_ptr`, `tl_atomic_i32_add_ptr`, `tl_atomic_i32_fetch_add_ptr`, `tl_atomic_i32_cas_ptr` | Compatibility names; implementations are TypeLisp exports over the atomic memory-operation intrinsics. |
| `tl_oob_abort`, `tl_div_abort`, `tl_shift_abort`, general panic/OOM aborts, file/IO/process/fs helpers, env lookup, random seed, profile time, and CPU feature helpers | Not backend-owned; these are TypeLisp runtime-prelude exports, stdlib implementations, or direct platform bindings. |

Allocator/arena page acquisition and release are backend-owned core runtime:
Linux emits `mmap`/`munmap` in `tl_alloc`, `tl_arena_make`,
`tl_arena_make_atomic`, `tl_arena_destroy`, and `tl_region_reset(0)` (plus
the `tl_arena_make` fatal-exit syscall); Windows emits kernel32
`VirtualAlloc`/`VirtualFree` for the same page paths. Nonzero
`tl_region_reset(mark)` restores the bump cursor and retires overflow chunks
on the arena root, so stale scratch pointers cannot observe later unrelated
allocations at reused virtual addresses; retained chunks are released by
full reset or arena destroy. `tl_region_mark`, `tl_arena_current`,
`tl_arena_set`, `tl_arena_poison_enable`, and the thread entry helpers only
read or update backend runtime state. Current-arena state is thread-local:
Linux uses local-exec TLS, with the FS base installed by the freestanding
entry before global initializers run; Windows x64 uses the TEB
arbitrary-user slot (`GS:0x28`). Raw thread spawn initializes a fresh zero
current-arena slot before user code runs, so a worker's first allocation
creates an independent default arena chain.

The compiler provides two allocation-free current-arena TLS intrinsics for
runtime-prelude code: `(tls-current-arena)` returns the current arena handle
as `i64`; `(tls-current-arena-set! arena)` writes it and requires an
`unsafe` context. Both lower directly to the platform TLS access used by the
backend helpers (`%fs:tl_current_arena@tpoff` on Linux, `GS:0x28` on
Windows), emit no calls, and require no imports, so they are valid in
`stdlib.runtime` before ordinary allocation is available. They name only the
current-arena slot; arbitrary TLS slots are out of scope pending a separate
source-level design.

`tl_arena_make` creates an ordinary first-class arena with a single-threaded
bump cursor. `tl_arena_make_atomic` creates a handle with the same
source-level ABI but marks the arena header as an atomic owner so `tl_alloc`
uses the concurrent allocation path when that arena is current. Neither
helper installs the new arena; callers select an allocation target through
`tl_arena_set` or the source wrappers in section 7.3.

For an atomic current arena, the allocation fast path reserves space from
the current chunk with one atomic bump. On chunk exhaustion the slow path is
serialized: one thread links or acquires the next chunk and publishes it as
the arena's current chunk while contending threads retry against the
published state. Ordinary arenas keep the non-atomic bump fast path. The
retained-chunk reset behavior above is a correctness requirement for the
atomic slow path: a reset must not make overflow chunks reusable while stale
arena-owned values can still exist.

Atomic allocation serializes allocation only. It does not protect array
writes, struct/enum mutation, raw pointer access, or user data from data
races; those remain governed by the borrow, mutation, unsafe, and
thread-safety rules.

### 6.3 Builtin operator aliases

Each alias expands to its base name and resolves wherever that name is bound
(core builtin or imported stdlib definition):

| Alias | Expands to |
|-------|------------|
| `string=?` | `string-eq` |
| `string-slice` | `substring` |
| `char-at` | `string-ref` |
| `print-str` | `print-string` |

### 6.4 Stdlib file I/O handles

This section specifies the v1 source-level file-handle API for `stdlib.io`.
The handle API reuses the existing `IoError` model in `stdlib.io` (§9
catalogs the variants); it does not introduce a new error vocabulary.

**Handle type.** A file handle is an opaque `FileHandle` value: programs
obtain it from `file-open`, pass it to read/write/close helpers, and never
inspect its representation. Internally it carries an id into a
stdlib-managed table storing the host descriptor, open mode, and open/closed
state; those fields are not part of the public contract and may change. A
handle is an aggregate value under the move-only contract in section 4.7.2:
each successful `FileHandle` is a single owner that is closed exactly once.
There is no implicit close; scoped `(with ...)` cleanup (section 5.19) is
the supported pattern.

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
| `file-open` | `String OpenMode → ResultIoFile` | `OkIoFile FileHandle` on success; `ErrIoFile IoError` for empty paths (`IoInvalidPath`), missing files in read mode (`IoNotFound`), permission failures (`IoPermissionDenied`), and other host status codes mapped through `error-from-status`. |
| `file-close` | `FileHandle → ResultIoUnit` | `OkIoUnit` on the first close. Closing an already-closed handle returns `ErrIoUnit (IoUnsupported ...)` rather than panicking. |

`ResultIoFile` is a monomorphic result enum mirroring the existing pattern:
`(OkIoFile FileHandle)` / `(ErrIoFile IoError)`.

**Close / lifetime semantics (v1).** v1 requires explicit `file-close`.
There is no destructor, drop glue, or implicit close — an unclosed handle
leaks its host descriptor for the life of the process, matching TypeLisp's
no-reclamation memory direction (§7.3). Use-after-close (any read or write
on a closed handle) and double-close return a structured `IoUnsupported`
error for stale handles that reach the stdlib implementation; they never
panic and never touch a host descriptor. Ordinary source-level double close
through the same variable is rejected earlier as use-after-move.

**Streaming reads.** `file-read-chunk` reads up to a requested byte count
from a read-mode handle:

| Helper | Signature | Behavior |
|--------|-----------|----------|
| `file-read-chunk` | `FileHandle i64 → ResultIoRead` | Read up to `count` bytes; `OkIoRead FileRead` carries the bytes read plus a sticky EOF flag. |

`FileRead` mirrors the shape of `StdinRead`: an active-arena `ByteBuf`
payload plus a sticky `eof` flag:

```
(defstruct FileRead
  (bytes ByteBuf)
  (eof bool))
```

- A read returns up to `count` bytes. A chunk shorter than `count` does not
  by itself indicate EOF — a short read may be a partial read. EOF is
  reported only through the `eof` flag, which becomes true once the host
  read reaches end-of-file.
- A zero-length read (`count` = 0) performs no host read and returns an
  empty `ByteBuf` with the current EOF state, deterministically. A read at EOF
  returns an empty `ByteBuf` with `eof` = true.
- A negative `count` returns `ErrIoRead (IoInvalidPath ...)` (an argument
  error) without performing a host read.
- Reading a write-only (`OpenWriteTruncate` / `OpenWriteAppend`), closed, or
  otherwise invalid handle returns `ErrIoRead (IoUnsupported ...)`.
- Interrupted host reads map through `error-from-status` to `IoInterrupted`;
  other host failures map to their `IoError` variant or `IoSystemCode`.

`ResultIoRead` is a monomorphic result enum: `(OkIoRead FileRead)` /
`(ErrIoRead IoError)`.

**Text vs. binary.** `FileRead`, `StdinRead`, whole-file reads, and recoverable
read results carry `ByteBuf`. Non-consuming whole-file, stream, and handle
writes take `(& r bytes)`. Text consumers cross this boundary explicitly with
`byte_buf.to-string`; text producers borrow their bytes with
`byte_buf.str-as-bytes`. Embedded NULs and bytes that are not valid UTF-8
therefore remain ordinary payload bytes.

**Streaming writes / append.** Streaming writes reuse `ResultIoUnit`:

| Helper | Signature | Behavior |
|--------|-----------|----------|
| `file-write` | `FileHandle (& r bytes) → ResultIoUnit` | Write the complete borrowed byte payload to a write-mode handle. |
| `file-flush` | `FileHandle → ResultIoUnit` | Flush pending writes for a write-mode handle. |

- `file-write` on an empty byte view succeeds without issuing a host write.
- The runtime retries host short writes until all bytes are accepted. A host
  error maps through `error-from-status`; a zero-byte host write before all
  bytes are written maps to `IoSystemCode 5` / the common I/O error status.
- Writing to or flushing an `OpenRead`, closed, invalid, or unsupported
  handle returns `ErrIoUnit (IoUnsupported ...)`; host flush failures map
  through `error-from-status`.
- `OpenWriteTruncate` starts from an empty file and writes advance the
  handle's file offset. `OpenWriteAppend` defines append semantics:
  create-if-missing, never truncate, and — where the host supports an append
  open mode (Linux `O_APPEND`) — each write lands at the current end of
  file. This matches the whole-file `try-append-file` helper, which uses the
  recoverable `append-file-status` runtime primitive instead of
  read-modify-write.

**Platform policy.** Linux is the reference target and implements all three
modes plus streaming reads and writes. On Windows, each mode or operation
either works through the equivalent Win32 file calls or returns a structured
`IoUnsupported` result. No operation panics for an unsupported platform;
callers always receive an `IoError`.

### 6.5 Task threading and structural thread safety

This section specifies the safe task-threading model for the stdlib surface.
`stdlib.thread` also retains a raw unsafe substrate — `thread.spawn` over a
`(-> i64 i64)` entry with one `i64` context and `thread.join` returning
`i64` — whose callers, if they smuggle addresses through those integers, are
responsible for their own synchronization in unsafe code. The safe surface
is closure-based and checker-visible; it adds no `Send`/`Sync` traits or
source-level trait system.

The core rule is structural: a value may cross a task-thread boundary only
when its type shape is accepted by the transfer/share classifier and every
reachable owned allocation is owned by an arena whose lifetime spans all
participating threads. Arena lifetime proves only that storage remains live
— not mutation race freedom, uniqueness, initialization, pointer provenance,
or foreign ABI invariants.

Task threading is distinct from SPMD `foreach` (section 5.15), a single-task
data-parallel lowering whose race freedom is checked by the SPMD
uniform/varying and reduction rules. The APIs below create independently
scheduled tasks/threads with their own default arenas and explicit ownership
crossing points.

#### Arena-owner crossing rules

The structural classifier consults both the source type and the owner of
every reachable heap allocation:

| Owner class | Safe cross-thread role |
|-------------|------------------------|
| Static data and program-lifetime owner | May be transferred or shared when the type classifier accepts the value, including read-only string literal storage and values allocated in a program-lifetime allocation home. |
| Per-thread default arena | Does not cross thread boundaries. A worker may use its own default-arena values freely but may not return, send, or share them with another thread unless an accepted API first clones or moves them into a spanning owner. |
| Lexical `with-arena` scoped region | Does not cross task-thread boundaries in v1: its reset is tied to the creating lexical scope, and the region checker proves same-thread escape safety only. Safe spawn/channel/mutex APIs reject scoped-region values; a future scoped-task API may add a join-before-reset proof. |
| Ordinary first-class arena from `arena.make` | Not a spanning owner: it proves neither cross-thread lifetime nor concurrent allocation safety. Safe code may use it for single-thread scratch workflows such as `with-escape`. |
| Atomic first-class arena from `arena.make-atomic` | May be a spanning owner when the handle outlives every thread that can hold its values; multiple threads may allocate into it under the section 7.3 allocation-target rules. Reset or destroy still requires proof that all users have joined or otherwise released the values. |
| Raw pointers, raw integer addresses, and foreign handles | Establish no ownership or lifetime. A value does not become transferable/shareable by carrying an address in `i64`, `Ptr`, `MutPtr`, or an opaque host handle; crossing requires an explicitly unsafe API or a safe wrapper with its own synchronization contract. |

The process-lifetime implementation detail of the allocator is not a
permission to transfer thread-default allocations. In the v1 source model
every thread has its own default arena, and only program/static or atomic
spanning owners are accepted for general cross-thread aggregate storage.

#### Structural transferability

Transferability is one-way ownership movement from one thread to another.
After a safe send, spawn capture, or return transfer, the source thread may
not use the moved value except through the ordinary post-move rules.
Copyable scalar values may be copied instead of moved.

A value is transferable when all of the following hold:

- Its source type is structurally transferable.
- Every reachable owned allocation has a spanning owner from the table
  above.
- The operation can prove exclusive ownership of mutable reachable storage,
  or the reachable storage is immutable.
- No reachable value is a guard, reference, raw-pointer ownership claim, or
  other non-transferable synchronization token.

The baseline structural rules are:

- `unit`, `bool`, numeric scalars, `char`, and function symbols with no
  captured state are transferable by copy.
- Tuples, fixed arrays, structs, and enum values are transferable when every
  field, element, or payload is transferable and any reachable allocation
  owner spans the participating threads.
- `String` is transferable when its bytes are static/program-owned or owned
  by a spanning atomic arena; it is immutable, so transfer creates no
  mutation race.
- Compatibility dynamic arrays and `(Box T)` values are transferable only by
  exclusive move, only when their element/referent type is transferable, and
  only when their backing storage owner spans the participating threads.
- Closure values are transferable only when their environment record and
  every captured value are transferable. Captured references, scoped-region
  handles, ordinary-arena values, raw-pointer-derived ownership claims,
  mutable aliases, and guard values are rejected with targeted diagnostics.
- Raw pointers, mutable raw pointers, integer addresses, and foreign handles
  are not transferable in safe code unless a specific safe wrapper gives
  them a synchronization and lifetime contract.

#### Structural shareability

Shareability permits more than one thread to hold access to the same value
at the same time. A value is shareable only when all reachable storage has a
spanning owner and the source type exposes no unsynchronized safe mutation
path, or when all mutation is mediated by an accepted synchronization
primitive.

Immutable data in a spanning owner is shareable: copyable scalars, immutable
strings, and aggregates that recursively contain only shareable immutable
fields. Mutable data is not made shareable by living in an atomic arena:
atomic arena allocation protects allocator metadata only, not array
elements, struct fields, enum payloads, raw pointer targets, or foreign
resources.

Ordinary `(& r T)` and `(&mut r T)` reference values do not cross threads in
v1, even when their referent is program-owned: the lifetime syntax cannot
quantify a reference over a worker's dynamic lifetime, and mutable
references require single-thread exclusive access. Cross-thread read sharing
is expressed by copying or moving an owned immutable handle, not by sending
a borrowed reference. Cross-thread mutation is expressed through mutex
guards, channels, explicit safe atomics, or unsafe code.

#### Safe spawn and typed join

The accepted safe spawn shape is closure based:

- `thread.spawn` accepts a closure whose captured environment is
  structurally transferable; the closure itself is moved into the worker.
  The checker rejects captured stack references, borrowed `str` views,
  `(& r T)` / `(&mut r T)` values, scoped-region values, ordinary
  first-class arena values, raw pointer-derived ownership claims, mutable
  aliases still live in the parent, and lock/channel guard values.
- A worker starts with its own per-thread default arena. It may allocate
  temporary data there, but aggregate results that leave the worker through
  join must already live in a spanning owner or be explicitly cloned/moved
  into one by an accepted API.
- `thread.join` consumes the thread handle, waits for completion, and
  returns a result typed by the closure return type. Double join and
  use-after-join are ordinary use-after-move errors.
- Joining a worker is also the proof that the worker no longer allocates
  into, mutates through, or holds values from any atomic arena whose
  lifetime depended on that worker. Resetting or destroying such an arena
  before all users have joined remains unsafe or rejected.

Typed join does not launder ownership: returning a `String`, compatibility
dynamic array, `Box`, tuple, struct, or enum from a worker is accepted only
when its reachable storage is already in a spanning owner or when the join
API performs an explicit, specified clone/move into a caller-selected
spanning owner. Returning a value allocated in the worker's default arena is
rejected.

`thread.spawn-i64-vec` and `thread.join-i64-vec` provide the concrete owned
growable-integer result path. The spawn task returns a generated
`(vector i64)` value. Before publishing the result, the runtime copies its
live prefix exactly once into a fresh spanning atomic arena; this explicit
copy prevents a task from laundering backing storage owned by a non-spanning
owner. Private runtime cells may use compiler-private dynamic-array storage,
but the public API does not expose `(Array i64)`.

#### Mutexes and guards

The safe mutex surface protects shared mutable state through a lexical
guard. The required source contract is:

- A mutex shared across threads must itself be owned by a spanning owner.
- Locking a mutex yields a guard tied to both the mutex and the lexical
  cleanup scope, normally through
  `(with ([g (mutex.lock m) mutex.unlock]) ...)`.
- The guard grants the only safe mutable access path to the protected value
  for the guard scope. Ordinary mutable-reference exclusivity rules apply
  while the guard is live.
- Guard values are move-only and non-transferable: they cannot be returned,
  stored in longer-lived aggregates, captured by spawned closures, sent
  through channels, or held past the cleanup scope.
- Unlocking releases the guard's exclusive access. It does not change the
  arena owner of the protected value and does not make non-spanning data
  transferable.

#### Channels

Channels transfer ownership between threads. The channel object and any
queued storage it uses must be owned by a spanning owner or by runtime state
whose safe wrapper proves lifetime and synchronization.

`channel.send` consumes its message: the sender may not use the moved value
after a successful send, and a buffered channel owns queued messages until a
receiver takes them. `channel.recv` produces an owned value for the
receiving thread. A message type is accepted only when it is structurally
transferable and its reachable storage either already has a spanning owner
or is cloned/moved into the channel's spanning storage by a specified API.
Sending references, guard values, raw-pointer ownership claims,
scoped-region values, or ordinary thread-default aggregate values is
rejected.

Closing, cancellation, and blocking policy are stdlib API details, but they
must preserve the same ownership rule: no safe channel operation may create
two unsynchronized mutable owners for the same reachable storage or let a
message outlive its arena owner.

#### Atomics

Safe atomic operations exist only where the language or stdlib explicitly
accepts an atomic type/helper with a specified width, alignment, ownership,
and memory-ordering contract. Outside those helpers, raw CPU atomics,
volatile raw pointer operations, and FFI atomic intrinsics remain
unsafe-only escape hatches.

The minimal v1 policy is conservative: safe atomics are synchronization
operations for the specific atomic location they operate on, not a blanket
permission to share surrounding non-atomic data. Atomic allocation in an
atomic arena is allocator synchronization only. Programs that need shared
mutable ordinary data must use mutex guards, channel ownership transfer, an
accepted atomic helper for that exact field, or `(unsafe ...)`.

`stdlib.atomic` is the first accepted safe atomic helper surface. It is
limited to one indexed compatibility dynamic-array element of type `i32` or
`i64` and exposes only load, store, add, and fetch-add operations with
sequentially consistent ordering; it has no public relaxed/acquire/release
ordering parameter and does not protect unrelated non-atomic locations.

---

## 7. Memory model

TypeLisp has no garbage collector, no implicit destructors, and no general
per-object `free`. Heap storage is organized around arenas: a per-thread
default arena that lives for the whole program, lexically scoped regions, and
first-class arena values whose invalidation requires checker-enforced safety
proofs. Reference types (`(& arena T)`, `(&mut arena T)`) and borrow
expressions (`(& place)`, `(& arena place)`) follow the borrowed `str`
contract in section 3.11 and the lifetime-owner model below.
Aggregate handles are move-only source values under section 4.7.2. The
`(with ...)` form (§5.19) is explicit cleanup for non-memory resources, not a
destructor or heap reclamation mechanism. Raw pointers (section 7.4) are the
explicit low-level exception and carry no safety guarantees.

### 7.1 Stack

- Function parameters and local variables are allocated in RBP-relative stack
  slots.
- Stack grows downward. Frame size is computed at compile time.
- Stack is aligned to 16 bytes at every call site (System V ABI requirement).

### 7.2 Heap

- `ByteBuf` backing stores, dynamic-buffer element storage, and escaping
  returned aggregates (enums, structs, strings, dynamic-buffer fat values)
  are heap-allocated.
- Non-escaping aggregate fat/inline storage is usually kept in the current
  stack frame.
- Allocation goes through `tl_alloc`, a backend-emitted bump allocator.
- Fatal page-allocation failures terminate with status 134 without allocating
  while reporting the failure. On Windows, `VirtualAlloc` failures include the
  ordinary/atomic arena kind, reserve/initial-commit/growth-commit operation,
  unsigned-decimal attempted/reserved/committed byte counts, and the
  immediately captured numeric `GetLastError` value. Arithmetic overflow
  guards retain the generic allocation-failure diagnostic because no OS
  allocation was attempted.
- There is **no garbage collector** and no general `free`.
- Each thread has its own default arena. Default-arena allocations remain
  live until the program exits unless an explicit same-thread region reset
  discards them; thread exit does not reclaim that thread's default arena.

### 7.3 Reclamation

The per-thread default arena is program-lifetime: simple, deterministic, and
correct for one-shot programs. It covers every heap allocation kind within
the allocating thread — fresh string storage, dynamic-buffer element storage
and fat values, returned enum and struct storage, `ByteBuf` backing storage,
closures, and data structures built from those primitives.

Per-object `free` is deliberately absent: aggregate handles are
pointer-shaped runtime values and dynamic buffers are shared mutable storage,
so an unchecked `free` would make double-free and use-after-free errors
expressible. A tracing garbage collector is also absent: it would require
object metadata, root discovery or stack maps, a runtime scanning policy, and
coverage of every aggregate allocation shape, and it would sacrifice the
determinism that region reclamation provides.

Reclamation is therefore explicit region invalidation at program-chosen phase
boundaries. The standard workflows are:

- **Temporary scratch only:** use `(with-arena scratch ...)` for phase-local
  allocation and return only scalars or values allocated outside the scoped
  arena. This is the default safe choice.
- **Clone one result out:** allocate a reusable first-class scratch arena
  with `arena.make`, then wrap each transient build in
  `(with-escape scratch ...)`. The result is cloned into the enclosing active
  arena before the scratch arena is rewound.
- **One-shot clone-out:** use `(with-scratch body ...)` when a supported
  result should be cloned out of a fresh scratch arena that is destroyed
  after the clone.
- **Keep results in a first-class arena:** wrap the build in
  `(in-arena arena ...)`; the saved active arena is restored afterward and
  the returned owned value remains in the target arena.
- **Safe ordinary arena invalidation:** for a direct local `arena.make`
  owner, record a phase token with `arena.phase`, allocate phase-local values
  through `(in-arena owner ...)`, then call `arena.rewind-safe!` when the
  checker can prove every value from that phase is dead. Call
  `arena.destroy-safe!` only when all values from the ordinary owner are
  dead.
- **Safe atomic arena invalidation:** for a direct local `arena.make-atomic`
  owner, use the same phase/destroy surface, but only after every
  checker-visible task, channel, mutex, or other user of that owner has been
  joined or otherwise released. Concurrent allocation safety is not reset
  safety.
- **Manual unsafe arena:** use `arena.set!`, `arena.rewind`, or
  `arena.destroy` only inside `(unsafe ...)` when the caller can prove all
  invalidated heap handles are dead.

Game-style frame/level/global lifetime layouts choose the surface by the
shape of the lifetime. Strictly nested global/level/frame data uses the
default program arena for global state plus nested lexical
`(with-arena level ...)` / `(with-arena frame ...)` scopes that return only
scalars or outer-owned values. Reusable scratch builders use `with-escape`;
one-shot builders use `with-scratch`; both clone one supported result into
the enclosing active arena. First-class level/frame arenas use
`(in-arena owner ...)` when the result should stay owned by that arena; a
direct local ordinary owner can be double-buffered by taking an `arena.phase`
before a frame fill and calling `arena.rewind-safe!` once every value from
the old frame phase is dead. Event-driven unload uses `arena.destroy-safe!`
on a direct local owner only after all owner-tagged values, borrows, closure
captures, container slots, and users are dead or released; for atomic owners
a message still queued in a channel blocks unload. A runnable cookbook of
these lifetime shapes is `examples/arena_lifetimes.tl`.

#### Scoped regions — `with-arena`

The `(with-arena ident body ...)` form (§5.16) gives programs a lexically
scoped, type-safe region. The typechecker ensures no region-tagged value
escapes the body, so the lowering can safely insert `tl_region_mark` at entry
and `tl_region_reset` at exit without risk of use-after-free. It is the
preferred surface for deterministic, safe reclamation between phases.

```lisp test=check name=with-arena-example
(import stdlib.string)

(define (process-phase [input : String]) : i64
  (with-arena phase
    (string.string-length (string.int->string 42))))
```

Allocation sites inside a `with-arena` scope target the active region:

- String operations that create fresh storage (`substring`, `str-cat`,
  low-level concat primitives, `read-file`, `int->string`, `arg`), buffer and
  collection constructors (`make-array`, `box`), `ByteBuf`
  construction/growth/copy-result helpers, and returned aggregate storage
  from calls inside the region.
- The body result must be region-free (scalars, or aggregates allocated
  *before* the `with-arena`).

The arena-model terminology calls the default allocation target the
program-lifetime arena and calls each nested `with-arena` body a scoped
arena. Unless a function explicitly says otherwise, allocation always uses
the active arena: the innermost scoped arena, or the default
program-lifetime arena when no scoped arena is active.

#### Lifetime owners and the outlives model

The checker treats a written lifetime name as the name of a visible owner,
not as an independently quantified region. The owner classes are:

- **Stack/frame owners:** function parameters and lexical bindings in the
  current frame. A reference type such as `(& x T)` names the stack slot or
  aggregate handle bound as `x`.
- **Lexical arena/region owners:** the implicit default program-lifetime
  arena and lexical `with-arena` binders. A scoped arena binder `phase` is
  named in `(& phase T)` reference types and in `(in phase T)` region-tagged
  handles. Untagged aggregate handles allocated outside any scoped arena are
  owned by the default program-lifetime arena; borrow inference uses the
  reserved lifetime name `program` for that storage, but there is no source
  binder to introduce.
- **Ordinary first-class arena owners:** handles returned by `arena.make`
  name single-thread allocation homes. They are not lexical binders, and
  source code cannot write a lifetime name for them directly. Safe code may
  use them through `with-escape` and `in-arena`, but concurrent allocation
  into one ordinary arena is not defined.
- **Atomic first-class arena owners:** handles returned by the
  `arena.make-atomic` wrapper over `tl_arena_make_atomic` name allocation
  homes whose lifetime may span multiple threads. Multiple threads may make
  the same atomic arena current and allocate into it concurrently, subject
  to the selection and lifetime rules below.

The outlives relation is lexical. An owner outlives itself. An owner
introduced by an outer parameter, `let` binding, or `with-arena` outlives
owners introduced in nested scopes. A nested stack slot or scoped arena does
not outlive its enclosing owner, so references and region-tagged handles tied
to the nested owner cannot be returned, stored into longer-lived bindings or
aggregates, or captured by closures that may escape. The checker applies
non-lexical lifetime shortening across expression sequences and branches and
uses conservative loop-body summaries.

`with-escape` is not a lexical lifetime binder and does not introduce a
written lifetime name. Its scratch arena is a first-class arena handle, and
the only supported escape from it is the form's clone step: the result leaves
the form cloned into the saved enclosing arena, without the scratch region
tag.

Atomic arenas are shareable allocation owners, not synchronization primitives
for the values allocated inside them. A value owned by an atomic arena may
cross threads only when the atomic arena owner outlives both the sending and
receiving threads and the structural transfer/share classifier in section 6.5
accepts the value. The arena owner proves storage lifetime only; mutation,
aliasing, raw pointer access, and interior synchronization remain separate
obligations.

#### Standard library and builtin allocation policy

Unless a function's signature attaches explicit lifetime information, the
checker conservatively treats aggregate results from calls inside a scoped
arena as tagged with that arena. This is stricter than necessary for
functions that return caller-owned data, but it prevents active-arena values
from escaping.

| Category | Members | Arena behavior |
|----------|---------|----------------|
| Non-allocating inspection | `length`/`array-length`; `stdlib.string` helpers `string-length`, `string-ref`/`char-at`, `string-eq`/`string=?`, `string->int`, and string predicates such as `string-contains` | Reads caller-provided handles and returns scalars. |
| Returns active-arena owned data | `make-array`, `box`, `arg`, `read-file`, `file-read-chunk`, `read-stdin-line`, `read-stdin-bytes`, `str-cat`/low-level concat primitives, `substring`/`string-slice`, `int->string`, `ByteBuf` construction/growth/copy-result helpers, stdlib trimming/replacement helpers when they build a new string | Fresh storage is allocated in the active arena and cannot escape a scoped arena. |
| Returns caller-provided data | `stdlib.string` `string-replace` when no match is found; `stdlib.io` `read-file-or` when the path is missing | Returns the caller-provided aggregate unchanged. Reference-typed signatures express the caller-owned result; without lifetime information in the signature, the conservative arena-tagging rule above applies inside a scoped arena. |
| Mutates caller-provided storage | `array-set!`, `byte-buf-set!`/`bytes-set!` mutation helpers | Mutates storage named by the caller; it does not allocate unless an owned-buffer growth operation is explicitly requested. Region checks reject storing shorter-lived aggregate handles into longer-lived containers, and borrowed `bytes` mutation requires an exclusive mutable view. |
| Host/runtime IO | `print*`, `panic`/`error`, `flush-stdout`, `write-file`, `file-exists?`, stdlib IO helpers | Performs target IO. Binary writes borrow `bytes` directly; text helpers may allocate active-arena strings only where their own contract says so. |

The owned `String` / borrowed `str` source contract, together with the
`ByteBuf` / borrowed `bytes` binary-storage contract, is specified in section
3.11. Except for the explicit `stdlib.arena` manual-control surface, no
stdlib function resets arenas; safe scoped cleanup is owned by `with-arena`.
Manual arena control goes through the `stdlib.arena` first-class helpers,
with `arena.set!`, `arena.destroy`, and `arena.rewind` gated by
`(unsafe ...)`.

Nested `with-arena` forms create independent subregions: inner-region values
cannot escape to the outer region, while outer-region values can be used
inside the inner region without restriction (they carry the outer tag).

Native targets implement `with-arena` reclamation through `tl_region_mark` /
`tl_region_reset`; repeated scoped allocations restore the saved arena mark.

#### First-class scratch arena escape — `with-escape`

Long-running tools may allocate a first-class scratch arena with
`arena.make`, switch to it for transient work, and keep only a deep-cloned
result. The safe source form for this pattern is:

```lisp test=check name=with-escape-example
(import stdlib.arena)
(import stdlib.string)

(define (build-message) : String
  (let
    [scratch : arena.Arena (arena.make)]
    (with-escape scratch
      (string.int->string 42))))
```

`with-escape` evaluates the arena expression in the current arena, records
the enclosing active arena, switches to the scratch arena, marks it,
evaluates the body, switches back to the enclosing arena, clones the body
result when the type requires it, rewinds the scratch arena to the entry
mark, and restores the enclosing active arena. The form is intended for
first-class scratch arenas; it is not a lexical lifetime binder, and lexical
region cleanup remains the job of `with-arena`.

#### One-shot scratch arena escape — `with-scratch`

Use `(with-scratch body ...)` when the scratch arena is only needed for one
transient build:

```lisp test=check name=with-scratch-example
(import stdlib.string)

(define (build-message) : String
  (with-scratch
    (string.int->string 42)))
```

`with-scratch` creates a fresh first-class scratch arena, evaluates the
non-empty body sequence with that arena active, clones the body result into
the enclosing arena when the type requires it, destroys the scratch arena
head, restores the enclosing active arena, and returns the cloned result. It
uses the same clone-supported result rules and source-region stripping as
`with-escape`, and rejects unsupported result shapes with a `with-scratch`
diagnostic.

#### First-class arena allocation target — `in-arena`

Use `(in-arena arena-expr body ...)` when a result should stay owned by a
first-class arena rather than being cloned back to the caller's active arena:

```lisp test=check name=in-arena-example
(import stdlib.arena)
(import stdlib.string)

(define (build-in-level [level : arena.Arena]) : String
  (in-arena level (string.int->string 42)))
```

`in-arena` evaluates `arena-expr` in the current arena, records the enclosing
active arena, switches to the target, evaluates the non-empty body sequence,
and restores the saved arena on normal completion, `(return ...)`, or
recoverable `try` propagation. It does not call `arena.mark`,
`arena.rewind`, or `arena.destroy`, and it does not clone the body result.
The body result type is returned unchanged. Nested lexical `with-arena`
escape rules still apply:
`(in-arena scratch (with-arena inner (int->string 1)))` is rejected because
the inner scoped region would escape.

#### Ordinary arena phase tokens

Use `arena.phase` and `arena.rewind-safe!` when a reusable ordinary arena
needs safe non-lexical reclamation:

```lisp test=check name=arena-phase-safe-example
(import stdlib.arena)
(import stdlib.string)

(define (main) : i64
  (let
    [scratch : arena.Arena (arena.make)]
    [kept : String (in-arena scratch (string.append "kept" ""))]
    [phase : arena.ArenaPhase (arena.phase scratch)]
    [temp : String (in-arena scratch (string.append "temp" ""))]
    [n : i64 (string.string-length temp)]
    (begin
      (arena.rewind-safe! phase)
      (+ n (string.string-length kept)))))
```

The recognized safe surface is deliberately narrow: the owner argument to
`arena.phase` and `arena.destroy-safe!` must be a direct local binding
initialized by `arena.make` or `arena.make-atomic`, and the argument to
`arena.rewind-safe!` must be a direct local `arena.ArenaPhase` returned by
`arena.phase`. Creating a phase token stores the current runtime mark and
records a checker generation for subsequent `in-arena` allocations through
that owner. Rewinding consumes the token and causes values allocated in that
phase generation to be treated as moved. Using the token again, using a phase
value after rewind, using the owner after safe destroy, or using any value
owned by a destroyed arena is rejected.

The safe phase-token proof does not make an ordinary arena a spanning
task-thread owner. Atomic arenas remain spanning owners only for values
accepted by the section 6.5 transfer/share classifier; safe reset or destroy
requires all checker-visible users to be joined or released first. Values
moved into synchronization state whose release cannot be proven, such as an
owner-tagged channel message, do not satisfy the proof. `arena.rewind-safe!`
and `arena.destroy-safe!` are also rejected while the same owner is the
active allocation target through `in-arena`; a program must leave the dynamic
allocation extent before invalidating it.

#### Atomic arena allocation target

The source wrapper for `tl_arena_make_atomic` is:

```lisp test=check name=arena_make_atomic_specified
(import stdlib.arena)

(define (main) : i64
  (let
    [shared : arena.Arena (arena.make-atomic)]
    (arena.raw-handle shared)))
```

`arena.make-atomic` returns a typed first-class `arena.Arena` handle and does
not make that arena current. A thread allocates into an atomic arena by
making it the active allocation target for a dynamic extent; the safe
spelling is `in-arena`, with the save/restore semantics given above. The
current arena is thread-local, so selecting an atomic arena in one thread
does not change another thread's default arena. The lower-level `arena.set!`
helper remains an unsafe manual operation for code that cannot express its
dynamic allocation extent with `in-arena`; callers must prove that the
selected arena is valid for the current thread and that later reset/destroy
operations cannot invalidate live handles.

Values allocated while an atomic arena is current are owned by that atomic
arena for thread-safety reasoning, even though the runtime representation is
an ordinary aggregate handle. The checker rejects safe cross-thread transfer
unless the atomic arena's lifetime spans every thread that can hold the value
and the section 6.5 structural classifier accepts the type shape. The
ordinary arena returned by `arena.make` has no spanning-owner property and
must not be used as a concurrent allocation target.

Resetting or destroying an atomic arena while any worker can still allocate
into it or hold a value it owns is rejected in safe code. The required proof
shape is "join all users before reset/destroy": `arena.rewind-safe!` and
`arena.destroy-safe!` accept direct atomic owners only after every
checker-visible thread user carrying that owner has been consumed by join or
an equivalent release point, and no live owner-tagged value or borrow
remains usable after invalidation. The lower-level `arena.rewind` and
`arena.destroy` helpers remain unsafe-only manual operations. The runtime
does not make use-after-reset deterministic for unsafe misuse; the no-UB
guarantee is enforced by rejecting the safe program before lowering.

#### Scoped non-memory resources — `with`

The `(with ([name init cleanup] ...) body ...)` form (§5.19) is the source
surface for deterministic cleanup of non-memory resources. It does not select
an allocation arena and does not reset heap storage. Cleanup is explicit in
the binding and must return `unit`; TypeLisp has no implicit destructors or
automatic `drop`.

This keeps resource lifetime policy independent from arena lifetime policy:
files, process handles, locks, mapped files, and temporary paths use `with`;
heap reclamation uses `with-arena` or the explicit arena operations above.
Cleanup-owning aggregates (section 4.7.1) use the same `with` owner scope
plus a declared aggregate cleanup function for the field cleanup plan.

#### Manual arena helpers

Programs that need manual control use the `stdlib.arena` first-class
helpers:

```lisp test=check name=arena-manual-helpers
(import stdlib.arena)

(define (main) : unit
  (let
    [home : arena.Arena (arena.current)]
    [scratch : arena.Arena (arena.make)]
    (unsafe
      (begin
        (arena.set! scratch)
        (arena.rewind (arena.mark))
        (arena.set! home)
        (arena.destroy scratch)))))
```

`arena.Arena`, `arena.ArenaMark`, and `arena.ArenaPhase` are nominal public
wrappers over the raw runtime handles. `arena.make`, `arena.make-atomic`, and
`arena.current` safely create or read an `arena.Arena`; `arena.mark` safely
records an `arena.ArenaMark` for the active arena; `arena.phase`,
`arena.rewind-safe!`, and `arena.destroy-safe!` are safe only under the
direct-owner checker proofs above. Raw `i64` values do not satisfy the public
arena helper signatures, and an `arena.Arena` cannot be passed where an
`arena.ArenaMark` or `arena.ArenaPhase` is required. By themselves these
values do not switch the active arena, free arena chains, rewind allocation,
or invalidate live safe handles.

Programs may opt into poison-on-reclaim mode with:

```lisp test=check name=arena-poison-enable-extern
(extern (tl_arena_poison_enable) : unit)
```

After `tl_arena_poison_enable` is called, Linux `tl_region_reset` and
`tl_arena_destroy` fill reclaimed or retired arena bytes with `0xA5`
immediately before a rewind, retirement, or unmap. The mode is off unless the
program enables it, and it is a debugging aid rather than a safety boundary.
Windows targets do not implement poison-on-reclaim.

A region reset mark invalidates every heap handle allocated after that mark,
so it is only valid when the caller can prove those values are dead, such as
after a tool iteration has discarded all phase-local results. It is not a
safe arbitrary source-level `free` replacement. Direct calls to these raw
reset helpers require an unsafe context; the safe `with-arena` surface
remains preferred.

### 7.4 Raw pointers and unsafe memory access

Raw pointers are address values. They do not own allocation, keep regions
alive, or prove that pointed-to storage is initialized, aligned, in-bounds,
mutable, or valid for the requested type.

- `(Ptr T)` and `(MutPtr T)` are both 8-byte pointer-sized values on
  supported targets.
- Raw pointers are nullable and copyable. `ptr-null` creates a typed null
  pointer, and `ptr-null?` checks for null without dereferencing.
- Pointer equality, ordering, provenance, and bounds are otherwise
  unspecified. Only null testing is part of the safe surface.
- `ptr-read`, `ptr-write!`, `ptr-offset`, `ptr-cast`, `ptr->int`,
  `int->ptr`, raw pointer atomics, and volatile raw pointer access require
  `(unsafe ...)` because the typechecker cannot prove their memory or ABI
  preconditions.
- A raw pointer into memory reclaimed by `with-arena`/`tl_region_reset`
  becomes invalid when that region is reset. The typechecker does not track
  this for raw pointers.
- Extern functions may return or accept raw pointers. The ABI contract is
  explicit in the signature but still unsafe: a `(Ptr T)` return may be null,
  dangling, misaligned, or point to fewer than `sizeof(T)` bytes unless the
  foreign API says otherwise.

Raw pointers are for FFI and carefully isolated low-level runtime code. They
are not the safe reference/borrow model, not a replacement for `with-arena`,
and not a general manual memory management feature.

### 7.5 Globals

- Stored in the `.data` or `.rodata` section.
- Mutable globals use `.data` with an initializer.
- String literal bytes are stored in `.rodata`; a `String` value points to
  inline `{ptr,len}` storage whose `ptr` field points into `.rodata`.

### 7.6 Aggregate handles, moves, and aliasing

- The IR/ABI may represent `String`, dynamic-buffer, tuple, struct, enum, and
  closure values as pointer-sized handles. Bit-copying such a handle aliases
  the same backing storage, but the source language treats aggregate by-value
  use as a move under section 4.7.2 rather than as a user-visible copy
  operation.
- Non-consuming inspection builtins read an aggregate handle without moving
  it. A function parameter marked `(:consume)` transfers a move-only argument;
  unmarked parameters preserve compatibility behavior, while reference-typed
  parameters provide checked borrowed access (sections 3.3 and 3.11).
- `String` values are immutable at the source level. String literals may
  share `.rodata`; `substring`, `string-slice`, `str-cat`, low-level concat
  primitives, `read-file`, `arg`, and `int->string` return fresh
  heap-allocated string storage. There is no source operation that mutates a
  string's bytes.
- Dynamic buffers are mutable heap storage. `array-set!` mutates the buffer
  named by the live owner handle under the mutation rules in section 4.7.2.
  Explicit shared mutable aliases require reference/borrow semantics rather
  than copying the buffer handle. Unsized `(Array T)` is an internal
  compatibility representation, not a public collection surface; the public
  `Array` form is fixed-size `(Array T N)`.
- Struct and enum values are pointer-sized aggregate handles internally.
  Struct field-place assignment mutates selected fields in place through
  owned storage places or mutable references. Enum payloads are consumed by a
  by-value `match`; borrowing a scrutinee for non-consuming pattern
  inspection is governed by the borrow rules.
- Returning an aggregate may heap-promote storage that would otherwise be
  frame-local. This is storage placement for safety; ownership transfer is
  still governed by the source-level move rules.
- `(clone value)` is the explicit deep-copy operation for values that must
  not share aggregate backing storage with the source. Cloneable types are
  scalars, `unit`, `never`, `String`, and tuples, fixed arrays, dynamic
  buffers, and named structs/enums whose elements, fields, or payloads are
  cloneable. Scalars return the same value; aggregate clones allocate fresh
  storage in the current active arena and recursively clone nested cloneable
  elements. Named structs/enums use `clone$Type` helpers. `clone` and
  `with-escape` remain compiler-checked semantic forms: the compiler owns
  cloneability, reachable-root discovery, diagnostics, and active-arena
  behavior. After the clone-generator migration, helper declarations are
  owned by a declared stdlib `: Decls` macro rather than by a second language
  semantic form.
- The clone handoff runs only after typechecking has resolved and deduplicated
  the reachable named-aggregate closure. `stdlib.clone` is part of the implicit
  macro prelude and routes every reachable named struct or enum through
  `stdlib.clone/synthesize-helpers`; the compiler has no compatibility AST
  producer. Each root has exactly one producer: the stdlib result is
  typechecked, lowered, and retained. An existing or conflicting `clone$Type`
  declaration is an error. Struct helpers reconstruct all fields, ordinary
  enum helpers reconstruct all variants and payloads, and two-variant
  list-shaped enums use tail-recursive accumulator/reverse helpers so cloning
  does not consume one native stack frame per element.
  The helper name is `clone$<unqualified-nominal-name>` in the nominal type's
  canonical module. The deterministic request/generated-origin key is
  prefixed by `decls:stdlib.clone:stdlib.clone/synthesize-helpers(` and encodes
  the ordered module-name/type-literal request pairs; repeated identical root
  closures reuse that identity and may not emit a second helper. Diagnostics
  from a generated helper use its generated-decl
  origin and the compiler handoff request location; producer conflicts name
  the conflicting helper explicitly.
- `clone` rejects unsupported ownership/lifetime forms rather than silently
  bit-copying them. Unsupported clone operands include function values,
  references including borrowed `str`, raw pointers, boxes,
  compile-time-only values, and named aggregate shapes containing
  non-cloneable fields.

---

## 8. Implementation status

This specification describes the language at its decided end state. This
section records where the implementation stands relative to that end state.
The issue tracker is the authoritative live view; this section is refreshed
in documentation passes.

### 8.1 Implemented

- The full pipeline on both targets: lexer, parser, type checker, lowerer,
  optimizer (`--opt-level 0|1|2`, with scalar register allocation and
  inlining at level 2), and x86_64 backends for `linux-x86_64` and
  `windows-x86_64`.
- All scalar types (`i8`–`i64`, `u8`–`u64`, `f32`, `f64`, `bool`, `char`,
  `unit`), enums with `match`, structs with in-place field mutation, tuples
  by value, fixed arrays, owned `String` with borrowed `str` views,
  `ByteBuf` with borrowed `bytes` views, `(Box T)`, references, and
  lifetime-parameterized aggregates.
- Move-only aggregates with use-after-move, path-move, and
  move-while-borrowed diagnostics; immutable/mutable borrow exclusivity;
  two-phase mutable call borrows; conservative non-lexical last-use
  shortening (straight-line sequences, path-sensitive joins, conservative
  loop facts).
- Opt-in `(:consume)` runtime function parameters, including static function
  type identity, direct/qualified/generated/lambda/function-value calls,
  copyable no-op semantics, and unchanged native ABI.
- Arenas: scoped `(with-arena ...)` with static escape checking,
  `with-escape`, `with-scratch`, `in-arena`, typed first-class `Arena`
  handles, and checker-proven phase-token rewind/destroy. `(with ...)`
  scoped resource cleanup, including cleanup-owning structs and enums.
- Closures with heap-snapshot captures of scalars, function values,
  `String`, aggregates, and fixed arrays (recursively deep-copied); local
  non-escaping immutable reference captures; direct, mutual, and supported
  indirect function-value tail calls emitted as jumps.
- FFI: `extern` with exact-symbol binding, C varargs, unsafe declarations,
  raw pointers with unsafe dereference/write/offset/cast, `ptr-addr-of` for
  whole local/parameter storage, struct-field paths, and fixed-array element
  paths (including coherent register-resident aggregate aliases),
  sequentially consistent 32/64-bit raw-pointer atomics, and 32/64-bit
  volatile raw pointer access.
- Safe task threading with structural transfer/share checking, generated
  thread/mutex/channel modules, and atomic arenas.
- SPMD: scalar reference lowering for `foreach`, `spmd-reduce`,
  `spmd-scan`, `spmd-broadcast`, `spmd-shuffle`, lane identity forms,
  masked varying `if`, varying `while`, and varying `match` (enum tags and
  payload bindings). AVX2/AVX-512 contiguous `foreach` map/zip subsets over
  all scalar integer and float lane types, including straight-line
  multi-destination maps with one shared lane shape, distinct destinations,
  and no destination read by a fused value; eligible vectorized
  `spmd-reduce` folds; canonical contiguous range-wide AVX2/AVX-512
  `spmd-scan` prefixes over i32/i64 and bool lanes; native AVX2/AVX-512
  `spmd-shuffle` permutations for
  i32/u32/i64/u64/f32/f64 maps and reduction values, including active-count
  preserving tails and ordered bounds traps; AVX2/AVX-512 masked varying `if` subsets including
  nested branch-mask composition, value-producing selects, and guarded native
  `i32`/`u32`/`i64`/`u64` direct and masked shifts with active-lane-only
  invalid-count traps;
  AVX2/AVX-512
  scalar-lane varying `match`; AVX2/AVX-512 enum tag/payload varying `match` with
  active-lane-only scalar field loads; AVX2/AVX-512
  standalone bool dynamic-array lanes, including bool copies and numeric
  comparison results stored to bool arrays; AVX2/AVX-512 varying `while` with
  loop-carried active masks and nested masked flow; runtime dispatch via
  `defdispatch` with cached CPUID/XGETBV selection; and native private
  scalar/AVX-512 out-of-line varying helper-call ABIs with active masks.
- Comptime: declaration-emitting typed macros, type reflection, CTFE with
  deterministic fuel, and per-package `tlci` comptime interface images.
- Tooling: package builds with lockfiles and dependency DAGs, inline tests,
  doctests, `fmt`, `lint`, `doc` generation, the published docs site, a
  stdio LSP server with diagnostics, definition, completion, inlay hints,
  formatting, hover, document links, flat top-level document-symbol outlines,
  lexical document highlights, lexical folding ranges for multiline forms and
  comment blocks, a deterministic multi-root workspace source/declaration index
  with open-document overlays and incremental file/root updates, and TypeLisp
  structural-edit/query extensions,
  structured source locations for source-authored semantic diagnostics, plus
  a REPL that evaluates through the real compile/link/run pipeline.

### 8.2 Not yet implemented, in migration, or deferred

| Feature | Status |
|---------|--------|
| Garbage collection / general `free` | Not planned: arenas are the reclamation model. |
| SIMD early exits | Deferred; varying `while` provides per-lane loop exit, while source `return`/`break`/`continue` from SIMD regions remain unsupported. |
| Narrow integer shifts | AVX2/AVX-512 direct-map and masked `i32`/`u32`/`i64`/`u64` shifts are implemented. `i8`/`u8`/`i16`/`u16` widening/packing expansions are deferred and rejected with stable operator/type/backend diagnostics. |
| Public vector/mask/varying source value types | Deferred by design. |
| Out-of-line ABI for non-inlined varying helper calls | Frontend analysis plus private scalar/AVX-512 IR lowering and native emission are implemented; AVX2 native emission is deferred under #5151. |
| Reference captures in escaping closures; mutation of captured names | Rejected by design: closure captures are by-value snapshots. |
| Dotted module imports everywhere | Migration in progress: source/docs use dotted imports as the canonical form; legacy path imports remain accepted only for compatibility fixtures before #2454 removes the syntax. |
| Fixed-size-only public `Array` | Migration in progress: unsized `(Array T)` remains a compatibility surface. |
| Qualified short stdlib names | Migration in progress: module-name-prefixed helpers remain during the rename. |
| Compiled comptime execution from embedded/package `tlci` images | In progress: the embedded image is built, embedded, and validated in every bootstrap, but dispatching through it is opt-in via `--cfg tlci-native-route` and is disabled on Windows regardless of that flag, so shipped builds resolve every stdlib macro through CTFE. When the route is enabled, embedded-stdlib compilation without an explicit stdlib root maps the production image, resolves macro identities through its native registration catalog, and commits results from compiled entries directly, with observable catalog hit/miss, load-failure, native-dispatch, and interpreted-fallback counters. Registration shells and uncataloged identities still execute through CTFE, explicit stdlib roots stay on the source path, and the differential gate requires byte-identical assembly between routes. |
| Package registry, semantic-version solving, workspaces | Deferred by design: deterministic git-pinned dependencies with lockfile replay. |
| Richer LSP/IDE features | The immutable workspace source/declaration index and overlay/event plumbing are implemented. Binding-aware read/write document highlights, hierarchical document symbols (members, variants, locals, and macro-generated declarations), semantic tokens, and references/rename through standard methods remain pending. |

---

## 9. Error handling

TypeLisp separates non-recoverable from recoverable failure: **panic**
terminates the process; recoverable failure uses ordinary concrete enums
together with the `(try expr)` propagation form.

```lisp test=ignore name=panic-expression reason=not-standalone
(panic "message")
```

- `panic` prints the message to stderr through the stdlib platform FFI
  binding, then calls the platform `exit` binding with status `134`.
- Panic is a terminal operation; it never returns normally.
- `error` is an alias for `panic`.

The stdlib declarations give `panic` and `error` the `never` return type.
`never` satisfies any expected type and merges with concrete `if` branch or
`match` arm result types, so no dummy value is needed after a panicking
branch (an explicit trailing dummy value remains valid but unnecessary).

```lisp test=compile name=panic-never-branch
(import stdlib.io)

(define (parse-or-zero [ok : bool]) : i64
  (if ok
    1
    (io.panic "parse failed")))
```

Function-local early exit uses the Lisp-shaped `(return expr)` form, as in
`(when (< x 0) (return 0))`.

- `(return expr)` is valid inside an enclosing function or lambda.
- `expr` is checked against the enclosing function's declared return type.
- The form has the compiler-internal bottom type, so it can appear in one
  branch of an `if` or `match` whose other branch produces the surrounding
  value.
- Active resource `with` cleanup functions and scoped `with-arena` resets run
  before the early exit leaves their scope.
- `(return expr)` is rejected outside a function and inside `foreach`/SPMD
  bodies.
- `(break)` and `(continue)` are valid only inside scalar `while`. They have
  the same compiler-internal bottom type and cleanup behavior as `return`,
  but target the nearest enclosing scalar `while` exit or condition check and
  are rejected inside `foreach`/SPMD bodies.

Recoverable failures are represented with ordinary concrete enums. TypeLisp
does not expose generic `Option<T>` / `Result<T,E>` type syntax, generic
functions, traits, trait objects, vtables, or runtime type-erased dispatch
for recoverable errors. Reuse comes from module-emitting stdlib macros and
hand-written monomorphic concrete enums. The stdlib macros emit nominal enum
types and helper functions for the requested payload/error type keys.

The generated-family identity is a stable key, not a runtime type object:

- Absence-only family key: `stdlib.option.generated.<payload-type-key>`.
- Recoverable-error family key:
  `stdlib.result.generated.<success-type-key>.<error-type-key>`.
- Module-macro generated option/result keys include the macro identity and
  `type-key` arguments, so repeated imports of `(option T)` or `(result T E)`
  reuse the same concrete module and type.
- Display names are deterministic ASCII identifiers derived from those keys.
  Options expose module-relative names such as `option_i64.Option`,
  `option_i64.some`, `option_i64.none`, `option_i64.is-some?`,
  `option_i64.value-or`, and `option_i64.map`; results expose
  `result_i64_string.Result`, `result_i64_string.ok`, `result_i64_string.err`,
  `result_i64_string.is-ok?`, `result_i64_string.value-or`, and
  `result_i64_string.map`.

Where no stdlib module macro is available, hand-written monomorphic enums are
the source equivalent. Use `Maybe*` or `Option*` names for absence-only APIs
and `Result*` names for APIs that distinguish success from an error value.
Matches must be exhaustive; omitted variants are rejected by the type
checker.

```lisp test=compile name=monomorphic-option-result
(import stdlib.str_cat)
(import stdlib.string)

(defenum MaybeI64
  (NoneI64)
  (SomeI64 i64))

(defenum ResultI64
  (OkI64 i64)
  (ErrI64 String))

(define (find-answer [name : String]) : MaybeI64
  (if (string.eq name "answer")
    (SomeI64 42)
    NoneI64))

(define (read-small [text : String]) : ResultI64
  (if (string.eq text "7")
    (OkI64 7)
    (ErrI64 (str_cat.str-cat "bad: " text))))

(define (maybe-score [m : MaybeI64]) : i64
  (match m
    [(SomeI64 value) value]
    [(NoneI64) 0]))

(define (result-score [r : ResultI64]) : i64
  (match r
    [(OkI64 value) value]
    [(ErrI64 message) (string.string-length message)]))

(define (main) : i64
  (+ (maybe-score (find-answer "answer"))
     (result-score (read-small "no"))))
```

Propagation uses the Lisp-shaped `(try expr)` form. It is analogous to Rust
`?` or Zig `try`, but it operates on concrete option/result families rather
than generic traits or implicit conversions. A convention-compatible concrete
family is a concrete enum with exactly one `Ok*` payload variant and one
`Err*` payload variant (result-like), or exactly one `Some*` payload variant
and one `None*` absence variant (option-like).

- For a recoverable-error result, `(try expr)` evaluates `expr` once. On the
  success variant it unwraps and yields the success payload. On the error
  variant it returns from the enclosing function with the compatible error
  variant carrying the same error payload.
- For an absence-only option, `(try expr)` unwraps `Some`/`Some*` and returns
  the enclosing compatible `None`/`None*` on absence.
- Compatibility is exact-family compatibility. There is no trait-like `From`
  conversion, no cross-family conversion, and no implicit option-to-result
  conversion; conversions between families are written as explicit helper
  functions.
- `(try expr)` is valid only inside an enclosing function whose return type
  is a compatible generated family or convention-compatible concrete family.
- `(try expr)` is rejected inside `foreach`/SPMD bodies because its
  error/absence path exits the enclosing function.
- `(try expr)` is rejected when `expr` is not a result/option family, when
  the enclosing function is not result/option-producing, or when the
  error/absence family is incompatible.

```lisp test=ignore name=result-try-success reason="illustrative try-propagation example"
(import stdlib.str_cat)
(import stdlib.string)

(defenum ResultI64
  (OkI64 i64)
  (ErrI64 String))

(define (read-small [text : String]) : ResultI64
  (if (string.eq text "7")
    (OkI64 7)
    (ErrI64 (str_cat.str-cat "bad: " text))))

(define (read-plus-one [text : String]) : ResultI64
  (let [value : i64 (try (read-small text))]
    (OkI64 (+ value 1))))
```

Propagation into an incompatible family is rejected: a function returning a
`ResultBool` with an `ErrBool bool` error variant cannot `(try ...)` a
`ResultI64` whose error variant carries a `String`.

Panic remains separate from recoverable results: it aborts instead of
producing an error variant, and — because of its `never` type — a panicking
branch can still inhabit an `if` or `match` whose other branches produce a
result value.

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
  typelisp run            Compile, link, and run a source file or package
  typelisp test           Run or check inline tests

Global Options:
  --help, -h                     Show root or command help
  --version                      Show the compiler build git hash and date

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
  typelisp compile <file.tl> [-o <file>] [--emit-ir] [--pic]
  typelisp compile --batch <input-output-list>
  typelisp compile --batch <artifact-list> --windows-coff-plan <result-plan> --target windows-x86_64
  typelisp build <file.tl> [-o <exe>]
  typelisp build [--manifest-path <typelisp.pkg>] [--profile dev|release] [--locked|--update-lock]
  typelisp run <file.tl> [--cfg <name>...] [-- <args>...]
  typelisp run [--manifest-path <typelisp.pkg>] [--profile dev|release] [--locked|--update-lock] [-- <args>...]
  typelisp fmt [<file.tl>...] [--check]
  typelisp lint [<file.tl>...] [--check] [--deprecated-string-concat] [--redundant-function-name] [--prefer-dotted-field] [--name-case] [--legacy-path-import]
  typelisp test [<file.tl>] [--check]
  typelisp inspect <file.tlci>
```

`typelisp <command> --help` is the source of truth for command-specific usage
forms. `--version` prints the compiler build git hash and date.

`compile -o <file>` writes assembly or IR to the given path, `--emit-ir`
emits the lowered and optimized IR instead of assembly, `--pic` emits
runtime-free no-entry PIC assembly plus a `<output>.fixups` file, and
`--batch <file>` reads `input|output` pairs and compiles them in one compiler
process.

With `--windows-coff-plan <result-plan>` and
`--target windows-x86_64`, batch input rows instead use
`input|object|assembly[|force-assembly]`. An automatic row writes a COFF object
when object lowering is semantically complete for every source instruction and
the compiler-owned image is serializable and linkable by the freestanding
Windows runtime contract; otherwise it writes assembly. `force-assembly`
bypasses the object attempt and preserves the legacy assembly bytes.

After every row succeeds, the compiler writes deterministic
`source|kind|path|reason` result rows in input order. `kind` is `coff-object` or
`assembly`; an object uses reason `none`, a forced row uses
`forced-assembly`, and automatic fallback uses one of
`unsupported-object-semantics`, `unsupported-coff-image`,
`unsupported-external-relocation`,
`missing-entry-symbol`, `missing-runtime-entry`, or `empty-text-section`.
Compile, type, backend, object-serialization, and file-write errors fail the
batch and do not produce the result plan. Each source is loaded, checked,
lowered, and optimized once; an automatic assembly fallback renders from that
same optimized program.

A compiler built with `--cfg compile-profile` additionally writes
`compile-batch-profile` rows to stderr at stable per-entry boundaries: entry
start, emission complete, owned-pool replacement/release, intern/session
cleanup, lower-arena cleanup, and scratch destruction/steady state. Rows use a
zero-based ordinal rather than a host path and report interval elapsed time,
allocation total, live, and peak-live deltas, followed by absolute live bytes
and drift from entry zero's starting live-byte baseline. The absolute fields
make cross-entry retention visible without reconstructing interval rows.
Normal compiler builds emit no such rows and produce byte-identical assembly.
The measurement harnesses keep the ordinal-to-input mapping separately.

`compile --profile-allocations` emits `compile-allocation-profile` owner rows
without changing generated output. Batch rows name the saved entry scratch
owner before and after state release, the process entry owner before release,
and the surviving `batch-compat-reset` owner at steady state. Post-emission
compatibility globals are rebuilt in that rotating owner: entry N remains live
through entry N+1 preflight, then is destroyed only after every compatibility
surface has been republished. This bounds reset residency to one entry rather
than retaining every manifest entry in the process arena.

`build --profile dev|release` selects the package build profile (default
`release`), `--release` aliases `--profile release`, and
`--manifest-path <file>` uses an explicit package manifest (default: the
nearest `typelisp.pkg` upward). `--locked` requires a matching
`typelisp.lock` and does not rewrite it; `--update-lock` refreshes remote
pins and rewrites `typelisp.lock`. The lock-policy flags are valid only for
package builds. `--opt-level <0|1|2>` selects the optimizer level; for
package builds it overrides the profile default (release `2`, dev `0`).
Source-file `build` and `run` accept `--link-lib <name>` (link a named
native library), `--link-search <dir>` (linker search directory), and
`--link-arg <arg>` (raw linker argument).

`fmt --check` reports files that would change without writing them;
`lint --check` exits non-zero when lint findings are present. Without
explicit files, `fmt` and `lint` default to the nearest `typelisp.pkg`
upward, and package lint discovers sources from that manifest. Dead-code
lint keeps all library top-level declarations as API roots and reports
unreachable binary-package declarations from entry/test/generated roots.
Opt-in rules: `--deprecated-string-concat` (deprecated concat primitives),
`--redundant-function-name` (redundant module-prefix names), and
`--prefer-dotted-field` (simple `struct-get` dotted-field syntax).
`--legacy-path-import` reports compatibility-only string-path imports and
includes the corresponding dotted import spelling in each finding.
`--name-case` enables four independently suppressible rules:
`global-name-case` for kebab-case top-level values,
`function-name-case` for kebab-case functions, dispatch functions, and macros,
`local-name-case` for kebab-case parameters and local binders, and
`type-name-case` for UpperCamelCase struct/enum declarations. Terminal `?`/`!`
and `->` conversion spellings are valid kebab syntax, and numeric segments are
accepted after the initial letter. Macro operands declared as `type` use
descriptive kebab-case; one-letter type variables may instead use conventional
uppercase spellings such as `T`. One leading `_` is accepted for intentionally
unused parameters and locals, including type operands. Symbolic names without
ASCII letters are exempt. Externs, imports/aliases, fields, variants, lifetimes,
tests, and labels are outside this staged rule.

`test` runs inline `(test ...)` declarations. `test --check` type-checks the
generated inline test harnesses without assembling or running them, and
`test --check --batch <inputs.txt>` checks newline-separated input paths in
one process. `test --filter <substring>` selects inline-test names and package
integration paths containing the substring. `test --list` lists the selected
tests without running them. `test` defaults to the host target unless
`--target <target>` is supplied.

`doc` generates markdown documentation for a source file or package.
`doc --test` checks TypeLisp fenced examples in documentation files, with
`--batch <inputs.txt>` reading a newline-separated input list; `doc --html`
renders HTML documentation. `clean` removes build artifacts for a source
file or package; `--dry-run` lists artifacts without deleting them. `new`
and `init` scaffold a package, in a new directory and in the current
directory respectively; `--lib` scaffolds a static library package. `check`
type-checks a source file or package. `lsp` starts the stdio LSP
diagnostics server.

For source-file builds, the default executable path is the source path with
the `.tl` extension removed on Linux and with `.exe` on Windows. Source-file
`build` does not run the executable. The package build form writes the
artifact selected by `typelisp.pkg`'s `kind` field and a metadata-only
`<package-name>.tlci` image for macro-free packages, or a code-bearing host
image with compiled supported transformer entries (templates, literals,
computed ifs, folds) and explicit fallback shells for unsupported bodies in
the same profile directory. `inspect` validates and
renders `.tlci` files without executing or loading contained code.

Linux native build/run uses `as` and `ld`. Windows native build/run uses
`clang --target=x86_64-pc-windows-msvc` and `lld-link`, links against the
CRT, and emits a console `.exe`.

`typelisp repl` supports `.help`, `.type <expr>`, `.load <file>`, and `.exit`.
Top-level declarations are remembered for later commands. `.load` reads a
source file, checks its declarations together with the current session, and
commits them only when the combined session is valid. `.type` parses and
typechecks the expression against the current session and prints the
inferred type without compiling or running native code. Bare expressions are
typechecked against the current session, compiled into a scratch `main`, run
through the source build/run path, and discarded without becoming session
declarations. Scalar results are printed directly. Struct, enum, tuple, and
fixed-array results are evaluated and use the explicit `<value: Type>` fallback
until runtime aggregate reflection is available.

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
- `String` and compatibility dynamic-array source values are handle-sized in
  this layout; their backing storage is larger implementation-owned data.
- An implementation may carry aggregate values through pointer-shaped heap
  handles in positions not covered by layout queries. That carriage is an
  implementation detail and not part of the source layout contract.
- `(:repr c)` is accepted as struct compatibility/ABI-intent metadata and does
  not change default struct field offsets. Backend extern lowering validates
  target C ABI aggregate classes separately.

---

## 12. Examples

### Hello world (factorial)

```lisp test=run name=factorial exit=0 stdout="Hello, TypeLisp!\nfactorial(5) = 120\n"
(import stdlib.io)

(define (factorial [n : i64]) : i64
  (if (= n 0)
      1
      (* n (factorial (- n 1)))))

(define (main) : i64
  (let
    [result : i64 (factorial 5)]
    (begin
      (io.print-string "Hello, TypeLisp!\n")
      (io.print-string "factorial(5) = ")
      (io.print result)
      0)))  ; prints the greeting/result and exits successfully
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

### Fixed-size array

```lisp test=run name=fixed-array exit=30 stdout=""
(import stdlib.array)

(define (main) : i64
  (let
    [arr : (Array i64 2) (init)]
    (begin
      (array-set! arr 0 10)
      (array-set! arr 1 20)
      (+ (array-ref arr 0) (array-ref arr 1)))))  ; returns 30
```

`(Array i64 2)` is a fixed array of two elements; `(init)` produces it with
every element zero-initialized per section 5.12.1, and `array-ref` /
`array-set!` are bounds-checked against the compile-time length.

### String operations

```lisp test=run name=string-length exit=5 stdout=""
(import stdlib.string)

(define (main) : i64
  (let
    [s : String "hello"]
    (string.string-length s)))  ; returns 5
```

```lisp test=run name=print-string exit=0 stdout="hello\n"
(import stdlib.io)

(define (main) : i64
  (begin
    (io.print-string "hello\n")
    0))  ; prints hello + newline, returns 0
```

`io.print-format` and `io.println` are format-backed macros. Their first argument
is a Rust-style literal template using `{}` placeholders and `{{` / `}}`
escapes; `print-format` writes exactly the formatted text and `println` performs
one additional newline write. The explicit compatibility-preserving
`print-format` name leaves the historical newline-writing integer
`(io.print value)` function unchanged. `print-string`, `print-str`,
`print-newline`, `print-error`, `print-bool`, `print-char`, and `print-float`
retain their existing behavior, as do the low-level borrowed `stdout-write` and
`stderr-write` helpers.

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
                | define-func
                | unsafe-decl
                | dispatch-decl
                | defmacro
                | extern-decl
                | module-decl
                | import-decl
                | include-str-decl
                | include-str-comptime-decl
                | include-str-lzss-decl
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
define-var    ::= "(" "define" ident [":" type] expr ")"
include-str-decl ::= "(" "include-str" ident string ")"
include-str-comptime-decl ::= "(" "include-str-comptime" ident string ")"
include-str-lzss-decl ::= "(" "include-str-lzss" ident string ")"
include-bin-decl ::= "(" "include-bin" ident string ")"
define-func   ::= "(" "define" "(" ident param* ")" [":" type] expr+ ")"
unsafe-decl   ::= "(" "unsafe" unsafe-decl-payload ")"
unsafe-decl-payload ::= define-func | extern-decl
dispatch-decl ::= "(" "defdispatch" ident dispatch-variant+ ")"
dispatch-variant ::= "(" dispatch-isa ident ")"
dispatch-isa  ::= "scalar" | "avx2" | "avx512"
defmacro      ::= "(" "defmacro" "(" ident macro-operand* ")" ":" macro-result-type expr+ ")"
macro-operand ::= "[" ident ":" type "]"
                | "[" ident ":" "type" macro-type-constraint "]"
                | "[" ident ":" type "..." "]"      ; final, or non-final ExprBindingClause
macro-type-constraint ::= "(" ":kind" macro-type-kind+ ")"
macro-type-kind ::= "i64" | "i32" | "i16" | "i8"
                  | "u64" | "u32" | "u16" | "u8"
                  | "f64" | "f32" | "bool" | "char"
                  | "string" | "unit" | "never"
                  | "array" | "dyn-array" | "box" | "function" | "tuple"
                  | "struct" | "enum" | "str" | "ptr" | "mut-ptr"
                  | "ref" | "mut-ref" | "region" | "type-var"
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
import-decl   ::= "(" "import" module-ident [item-suffix] [import-alias] ")"
                | "(" "import" macro-call [item-suffix] [import-alias] ")"
item-suffix   ::= ".*" | "." ident
import-alias  ::= "as" ident
defenum       ::= "(" "defenum" ident enum-meta* variant+ ")"
defstruct     ::= "(" "defstruct" ident struct-meta* field+ ")"
struct-meta   ::= "(" ":repr" "c" ")"
                | aggregate-lifetime-meta
                | aggregate-cleanup-meta
enum-meta     ::= aggregate-lifetime-meta
                | aggregate-cleanup-meta
aggregate-lifetime-meta ::= "(" ":lifetimes" ident+ ")"
aggregate-cleanup-meta ::= "(" ":cleanup" ident ")"
test-decl     ::= "(" "test" ident expr+ ")"
module-macro-call ::= macro-call                    ; must resolve to a `: Decls` macro

param         ::= "[" ident ":" type "]"
field         ::= "(" ident type field-meta* ")"
field-meta    ::= "(" ":cleanup" ident ")"
                | "(" ":owned" ")"
variant       ::= "(" ident variant-payload* ")"
variant-payload ::= type field-meta*

expr          ::= literal
                | ident
                | "(" "if" expr expr expr ")"
                | "(" "cond" cond-clause+ cond-else-clause ")"
                | "(" "when" expr expr+ ")"
                | "(" "unless" expr expr+ ")"
                | "(" "let" binding+ expr+ ")"
                | "(" "let" "[]" expr+ ")"
                | "(" "while" expr expr+ ")"
                | "(" "break" ")"
                | "(" "continue" ")"
                | "(" "begin" expr+ ")"
                | "(" "set!" ident expr ")"
                | "(" "ann" expr ":" type ")"
                | "(" "cast" expr ":" type ")"
                | "(" "match" expr match-arm+ ")"
                | "(" "for" for-binding+ expr+ ")"
                | "(" "foreach" foreach-clause expr ")"
                | "(" "cfg" cfg-predicate expr [expr] ")"
                | "(" "spmd-reduce" reduce-op foreach-clause expr expr ")"
                | "(" "spmd-scan" reduce-op scan-clause expr expr ")"
                | "(" "spmd-broadcast" expr expr ")"
                | "(" "spmd-shuffle" expr expr ")"
                | "(" spmd-lane-form ")"
                | "(" "lambda" "(" param* ")" [":" type] expr+ ")"
                | "(" "return" expr ")"
                | "(" "with-arena" ident expr+ ")"
                | "(" "with-escape" expr expr+ ")"
                | "(" "with-scratch" expr+ ")"
                | "(" "in-arena" expr expr+ ")"
                | "(" "with" "(" resource-binding* ")" expr+ ")"
                | borrow-expr
                | "(" "unsafe" expr+ ")"
                | "(" "ptr-null" ":" ptr-type ")"
                | "(" "ptr-null?" expr ")"
                | "(" "ptr-read" expr ")"
                | "(" "ptr-write!" expr expr ")"
                | "(" "ptr-offset" expr expr ")"
                | "(" "ptr-cast" expr ":" ptr-type ")"
                | "(" "ptr-addr-of" addr-of-place ")"
                | "(" "ptr->int" expr ")"
                | "(" "int->ptr" expr ":" ptr-type ")"
                | "(" "comptime" expr ")"
                | "(" "type" type ")"
                | "(" "size-of" expr ")"
                | "(" "align-of" expr ")"
                | "(" "offset-of" expr ident ")"
                | "(" "make-array" type expr ")" ; compatibility allocation
                | "(" "make-array" expr* ")"     ; dynamic-buffer literal
                | "(" expr call-operand* ")"  ; function or macro call

macro-call    ::= "(" qualified-name call-operand* ")"

call-operand  ::= expr
                | "[" expr expr "]"            ; macro-only ExprClause operand
                | "[" ident expr "]"           ; macro-only ExprBindingClause operand
                | "[" ident ":" type expr "]"  ; macro-only ExprBindingClause operand

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

addr-of-place ::= ident
                | "(" "struct-get" addr-of-place ident ")"
                | "(" "array-ref" addr-of-place expr ")"

;; `ptr-addr-of` is unsafe and narrower than `borrow-place`: the root `ident`
;; must resolve to local or parameter storage, `array-ref` projections must be
;; fixed-array elements, and temporaries, globals, tuple/box/enum projections,
;; and compatibility dynamic-array elements are rejected. Local dotted-field
;; sugar follows the same leading-local rule as borrow places.

binding       ::= "[" ident [":" type] expr "]"
resource-binding ::= "[" ident expr expr "]"  ; name init cleanup-fn
for-binding   ::= "[" ident [":" type] expr "]"
foreach-clause ::= "(" "[" ident ":" type expr expr "]" ")"
scan-clause   ::= "(" "[" ident ":" type expr expr "]"
                      "[" ident ":" type expr "]" ")"
reduce-op     ::= "sum" | "min" | "max" | "all" | "any"
spmd-lane-form ::= "program-index" | "program-count"
match-arm     ::= "[" pattern expr "]"
pattern       ::= "_"
                | literal
                | ident
                | "(" ident pattern* ")"

literal       ::= integer | float | bool | char | string | "unit"

type          ::= "i64" | "i32" | "i16" | "i8"
                | "u64" | "u32" | "u16" | "u8"
                | "f64" | "f32" | "bool" | "char" | "unit"
                | "String"
                | "str"                               ; borrowed referent only
                | "Expr" | "ExprList"               ; compile-time-only macro body values
                | "ExprClause" | "ExprClauseList"   ; macro-only bracket operand values
                | "ExprBindingClause" | "ExprBindingClauseList"
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
                  | type "..."                         ; final, or non-final ExprBindingClause

module-ident  ::= ident ("." ident)*
qualified-name ::= ident | module-ident "." ident
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

Import grammar constraints:

- A bare `module-ident` import binds the final-segment default alias and gives
  qualified access only.
- `.*` imports all visible top-level items unqualified and cannot combine with
  `as`.
- `.item` imports that single visible top-level item unqualified and may
  combine with `as` to rename the bound item.
- A whole-module `macro-call` import requires `as alias`; otherwise the import
  must use `.*` or `.item`. Bare `(import (macro args))` is rejected.
- For named modules, item resolution uses the longest module prefix; a single
  remaining segment is the selected visible item. For macro-call imports, the
  parenthesized macro call is the module expression and an optional suffix
  selects items from its generated declarations.
- Multi-segment item paths and multi-item `:only` selected imports are
  reserved and rejected.
