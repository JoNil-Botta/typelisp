# Language guide

This page contains the language overview and examples from the project README.
For the complete language contract, see [SPEC.md](../SPEC.md).

## Example

```lisp
(defstruct Point (x i64) (y i64))

(defenum Shape
  (Circle i64)        ; radius
  (Rect   i64 i64))   ; width height

(define (area [s : Shape]) : i64
  (match s
    [(Circle r)   (* 3 (* r r))]
    [(Rect w h)   (* w h)]))

(define (main) : i64
  (let [p : Point (Point 3 4)]
    (+ (struct-get p x)            ; 3
       (area (Rect 5 6)))))        ; 30  -> main returns 33
```

The entry point is a function named `main` returning `i64` or `unit`. If
`main` is omitted, the compiler synthesizes one that returns 0.

## Language overview

TypeLisp uses S-expressions with explicit type annotations on parameters,
struct/enum fields, and (optionally) `let` bindings.

```lisp
;; Global variable (scalar and aggregate initializers, including runtime
;; initializers, are supported)
(define answer : i64 42)

;; Function (parameters must be typed; return type defaults to unit)
(define (add [a : i64] [b : i64]) : i64 (+ a b))

;; Local bindings (sequential, let* scoping)
(let [x : i64 10]
  [y     (* x 2)]   ; type inferred
  (+ x y))

;; Control flow
(if (< answer 100) "small" "large")
(while (> answer 0) (set! answer (- answer 1)))
(begin (when (< answer 0) (return 0)) answer)

;; Casts and zero/identity initialization
(cast 300 : u8)
(import stdlib.array)
(let [n : i64 (init)]
  [items : (Array i64 4) (init : (Array i64 4))]
  (+ n (array-ref items 0)))
```

`cast` supports the full scalar numeric matrix: integer/char widening,
narrowing, and truncation; `f64` <-> `f32` precision changes; and
integer/char <-> float conversions (float -> integer truncates toward zero).
`(init : T)` constructs a valid initialized value for supported `T`;
contextual `(init)` works where an expected type is known.

### Types

```
i64 i32 i16 i8   u64 u32 u16 u8   f64 f32   bool   char   unit   String
ByteBuf           ; owned mutable byte buffer
(Array t n)       ; fixed-size array (public Array end state)
(Array t)         ; compatibility runtime-sized buffer during migration
(Tuple t1 t2 ...) ; tuple (by-value params/returns supported)
(Box t)           ; arena-owned indirection for recursive aggregates
(& r t)           ; immutable reference tied to lifetime/arena r
(& r str)         ; borrowed string view of an owned String
(& r bytes)       ; immutable borrowed byte slice
(&mut r bytes)    ; exclusive mutable borrowed byte slice
(-> arg... ret)   ; function type
Name              ; a defenum / defstruct nominal type
(Name r...)       ; lifetime-parameterized nominal type use
```

Both `f64` and `f32` support scalar parameters, returns, locals, arithmetic,
comparisons, and casts. Raw pointer types `(Ptr T)` / `(MutPtr T)` and
`(unsafe ...)` are the FFI/runtime escape hatch (see
[SPEC.md](../SPEC.md) sections 3.4, 4.3.1, and 5.20), including sequentially
consistent raw-pointer atomics (`atomic-load`, `atomic-store!`,
`atomic-add!`, `atomic-fetch-add!`, `atomic-cas!`) for 32/64-bit integer
elements.

Function signatures normally elide reference lifetime names: write
`[item : (& Item)]` or `[item : (&mut Item)]`, and an elided reference return
uses the sole input reference lifetime. Use explicit names such as
`(& selected Item)` only when an API intentionally relates multiple reference
inputs; fields, globals, locals, and nominal lifetime arguments remain
explicit. Borrow expressions stay `(& place)` and `(&mut place)`.
At a typed call, an existing `&mut T` argument may be passed to an `&T`
parameter as a tracked shared reborrow; the reverse conversion is never
implicit.

### Abstraction: comptime, not generics

TypeLisp does not plan source-level generics, traits, interfaces, `impl`
blocks, generic `Option<T>`/`Result<T,E>` syntax, or trait-based error
conversion. Library abstraction comes from comptime generation: compile-time
code inspects type values and emits concrete structs, enums, functions, and
implementation bundles through declaration-emitting `defmacro` forms.
Comptime-generated declarations, type reflection, and typed expression
macros are implemented; see [SPEC.md](../SPEC.md) sections 3.7 and 5.17.
Comptime code is
pure safe TypeLisp — no `unsafe`, `extern`, or host I/O — bounded by
deterministic fuel. Write hand-authored monomorphic declarations (such as a
domain-specific `Result*` enum) when a generated family has not been
requested; `(try expr)` is the propagation form over compatible concrete
Result-like enums.

### Top-level forms

`define` (variable / function), `defenum`, `defstruct`, `extern`, `import`,
`module`, and `defmacro`. Every top-level item is exported by default (there
is no `export` form).

```lisp
(defenum Tree (Leaf i64) (Node (Box Tree) (Box Tree)))
(defstruct Pair (fst i64) (snd i64))
(extern (foreign-add [a : i64] [b : i64]) : i64)
(extern (printf [fmt : (Ptr u8)] ...) : i32 (:symbol "printf"))
(extern foreign-add-ptr (:symbol "foreign_add_ptr") : (-> i64 i64))
(import stdlib.string)
```

Structs and enums have stable inline layout by default: struct fields use
declaration order with natural alignment; enums use an 8-byte tag plus
max-aligned payload storage. Comptime layout queries (`size-of`, `align-of`,
`offset-of`) use that layout. Recursive aggregates use explicit `(Box T)`
fields/payloads at the recursive edge.

`extern` defaults to the target C ABI with the linker symbol equal to the
local name; `(:symbol "...")` binds an exact foreign symbol (without the
`_tl_` prefix used for ordinary TypeLisp declarations). Function-head externs
are direct external functions; bare-name externs are external data symbols,
and a bare function type is a raw C function pointer called with the C ABI.
C varargs are declared with bare `...` (any C ABI tail) or `[arg : ...T]`
(homogeneous tail).

### Modules and imports

Dotted module imports bind a module alias and keep imported definitions out
of the local unqualified namespace: `(import stdlib.string)` binds `string`,
and `(import stdlib.core_macros as core)` binds `core`. Imported values,
types, constructors, variants, patterns, and macros are referenced with
dotted member access — `(string.eq left right)`, `[p : geometry.Point]`.
Macro imports use the same module identities, with expansion happening
before ordinary typechecking. Legacy string path imports are retained only for
named compatibility fixtures until final removal; new code should use dotted
module identities.

The compile driver prepends the stdlib runtime and the core macro module as
an implicit prelude, so bare `when`, `unless`, `and`, `or`, scalar `for`, and
bracket-arm `cond` resolve without imports. Stdlib modules otherwise resolve
local-first, then from `--stdlib-root <dir>` (or the
`TYPELISP_STDLIB_ROOT` fallback), then from the compiler's embedded copy of
the checked-in stdlib. Prefer
`--stdlib-root` for CI and reproducible scripts; see
[../stdlib/README.md](../stdlib/README.md) for the stdlib layout.

Within each module, type names and value names live in separate namespaces:
enum and struct type names share the type namespace, while functions,
variables, externs, struct constructors, and enum variant constructors share
the value namespace. An enum type may share a name with one of its own
variants. Module identity then qualifies both namespaces, so two modules can
define the same local name without colliding.

### Conditional compilation

`compile`, `run`, and `build` accept repeated `--cfg <name>` flags. Source
can wrap a top-level declaration as `(cfg predicate declaration)` or use the
expression form `(cfg predicate expr [else-expr])`, where `predicate` is a
flag name, `(all ...)`, `(any ...)`, or `(not ...)`. Inactive branches are
read but not parsed as declarations, so they can hide stage- or
platform-specific code. Target OS predicates are enabled automatically:
`linux`/`unix`/`target-linux`/`os-linux` and
`windows`/`target-windows`/`os-windows`.

`check`, `lint`, and `fmt` accept the same `--target` and repeated `--cfg`
selection (the CST formatter still formats every branch). The LSP defaults to
the server host and accepts `target` plus a string-array `cfg` in
`initializationOptions`, either directly or nested below `typelisp`.

### Expression forms

`if`, `when`, `unless`, `let`, scalar `for`, `while` (with unit
`break`/`continue`),
`begin`, `set!`, `match` (nested/recursive enum patterns, constructor-shaped
struct patterns, `_`), `ann`, `cast`, `return`, `try`, `foreach`,
`spmd-reduce`, `spmd-scan`; arithmetic (`+ - * / %`), comparison
(`= != < <= > >=`), boolean (`and` `or`), and bitwise/shift (`bit-and`
`bit-or` `bit-xor` `shl` `shr`) operators. `struct-get` reads a struct
field, and dotted syntax `place.field` is sugar for the same operation;
`(set! place.field value)` writes in place.

Named top-level functions and `lambda` literals are pointer-sized closure
descriptor values. Non-capturing lambdas use static descriptors; capturing
lambdas snapshot supported captures (scalars, function values, `String`,
aggregates, fixed arrays — recursively deep-copied) into heap environments
that outlive the creating frame. Local non-escaping closures may capture
immutable references; escaping closures reject reference captures, and
mutation of captured names is rejected by design. Direct, mutual, and
supported indirect function-value tail calls are optimized to jumps; ABI
shapes that cannot be tail-jumped are conservatively emitted as ordinary
calls.

### Builtins and stdlib

Compiler-owned builtins are a small set: fixed-array element operations
(`array-ref`, `array-set!`, `array-length`/`length`), string
indexing/slicing primitives (`substring`/`string-slice`, `int->string`),
and the CPU instruction intrinsics. Array and string indexing is
bounds-checked at runtime. Everything else lives in stdlib modules imported
with dotted imports: printing and `panic`/`error` in `stdlib.io`, string
inspection/parsing in `stdlib.string`, files and processes in `stdlib.io`
and `stdlib.fs`, string building in `stdlib.str_cat`, `stdlib.format`, and `stdlib.text_buf`,
binary buffers in `stdlib.byte_buf`, arenas in `stdlib.arena`, and threading
in `stdlib.thread` / `stdlib.sync`.

## Current source conventions

Some transitional spellings survive while migrations finish. New code should
use the end-state forms:

- Use dotted module imports with aliases and qualified member access:
  `(import stdlib.string)` and `(string.eq left right)`. Legacy string-path
  imports are compatibility-only.
- Prefer qualified short stdlib names such as `string.append`; flat
  module-prefixed names such as `string-append` are transitional.
- Use the prelude spellings `when`, `unless`, `and`, `or`, scalar `for`, and
  bracket-arm `cond`: `(cond [test expr] ... [else fallback])`.
- Build strings with `str-cat` or `text_buf`; do not add
  `string-append`/`string-concat` chains.
- Use `ByteBuf` and borrowed `bytes` views for mutable binary storage, not
  mutable `str` or `(Array u8)`.
- Use fixed `(Array T N)` values for fixed storage and vector/slice APIs for
  runtime-sized collections. Unsized `(Array T)` remains only as a migration
  compatibility surface.
- Mutate places in place with `set!`, including struct fields and boxed
  storage, instead of copy-on-update helpers.
