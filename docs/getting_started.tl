;# Getting started with TypeLisp.
;#
;# A guided path from `hello.tl` to the four things that actually stop
;# newcomers: move semantics, borrowing, scoped arenas, and comptime instead of
;# generics. The reference material lives in the README and SPEC; this page is
;# the on-ramp.
;#
;# Every example below is compiled by `typelisp doc --test docs/getting_started.tl`,
;# which runs in CI, so nothing here can drift from the language.
;#
;# ## 1. Hello, and what `main` means
;#
;# The entry point is a function named `main` returning `i64` or `unit`. Its
;# return value is the process exit code, which is why the repository's own
;# tests are full of programs that end in `42`.
;#
;# ```typelisp
;# (import stdlib.io)
;#
;# (define (main) : i64
;#   (begin
;#     (io.print-string "Hello, TypeLisp!\n")
;#     0))
;# ```
;#
;# Run it with `typelisp run hello.tl`. `typelisp check` type-checks without
;# producing a binary, which is the fastest loop while you are learning.
;#
;# ## 2. Structs, enums, and match
;#
;# Every parameter and field is explicitly typed. `match` is exhaustive over an
;# enum's variants, so adding a variant turns every incomplete match into a
;# compile error rather than a runtime surprise.
;#
;# ```typelisp
;# (defstruct Point (x i64) (y i64))
;#
;# (defenum Shape
;#   (Circle i64)
;#   (Rect i64 i64))
;#
;# (define (area [s : Shape]) : i64
;#   (match s
;#     [(Circle r) (* 3 (* r r))]
;#     [(Rect w h) (* w h)]))
;#
;# (define (main) : i64
;#   (let
;#     [p : Point (Point 3 4)]
;#     (+ p.x (area (Rect 5 6)))))
;# ```
;#
;# `p.x` is sugar for `(struct-get p x)`. Mutate in place with
;# `(set! p.x 10)` rather than rebuilding the struct.
;#
;# ## 3. Move semantics, and the error you will hit first
;#
;# Scalars, raw pointers and non-capturing function values copy. Everything
;# else -- `String`, arrays, tuples, structs, enums, capturing closures --
;# **moves**.
;#
;# The part that surprises people is when a move actually happens. Writing an
;# aggregate parameter by value is *not* enough: at a typed call site the
;# compiler auto-borrows a borrowable place, so the caller keeps its value. A
;# function that genuinely takes ownership says so with `(:consume)`:
;#
;# ```tl expect-error
;# (import stdlib.string)
;#
;# (define (consume-length [text : String (:consume)]) : i64
;#   (string.string-length text))
;#
;# (define (main) : i64
;#   (let
;#     [text : String "moved"]
;#     (+ (consume-length text) (consume-length text))))
;# ```
;#
;# The second call is the error: `text` was moved by the first. Assigning to a
;# new binding moves too -- `[moved : String text]` ends `text`'s life, and
;# every later use of `text` is rejected.
;#
;# ## 4. Borrowing
;#
;# Dropping `(:consume)` is the fix, and writing `(& T)` says the intent
;# explicitly. Both callers keep their value:
;#
;# ```typelisp
;# (import stdlib.string)
;#
;# (defstruct Label (name String) (width i64))
;#
;# (define (measure [tag : (& Label)]) : i64
;#   (+ (string.string-length tag.name) tag.width))
;#
;# (define (main) : i64
;#   (let
;#     [tag : Label (Label "box" 3)]
;#     (+ (measure tag) (measure tag))))
;# ```
;#
;# Use `(&mut T)` for exclusive mutable access; the checker rejects a mutable
;# borrow that overlaps any other live borrow.
;#
;# ## 5. Scoped arenas, and the escape error
;#
;# There is no garbage collector and no `free`. Allocation goes into the active
;# arena, and `(with-arena r ...)` is a scoped region that is reset on exit. The
;# type checker proves nothing allocated inside escapes, so the reset is safe:
;#
;# ```typelisp
;# (import stdlib.string)
;#
;# (define (digits [n : i64]) : i64
;#   (with-arena scratch
;#     (let
;#       [text : String (string.int->string n)]
;#       (string.string-length text))))
;#
;# (define (main) : i64
;#   (digits 4096))
;# ```
;#
;# Returning a scalar out of the scope is fine. Returning the `String` itself is
;# not, and this is the error the checker exists to give you:
;#
;# ```tl expect-error
;# (import stdlib.string)
;#
;# (define (leak [n : i64]) : String
;#   (with-arena scratch
;#     (string.int->string n)))
;#
;# (define (main) : i64
;#   (string.string-length (leak 7)))
;# ```
;#
;# When one result genuinely must outlive the scratch work, `(with-scratch ...)`
;# clones the supported result back out. `stdlib.arena` documents the
;# first-class arena APIs for the cases that need explicit control.
;#
;# ## 6. Recursive data needs `(Box T)`
;#
;# A struct or enum cannot contain itself directly -- the layout would be
;# infinite. `(Box T)` is a move-only arena-owned indirection that breaks the
;# cycle at the recursive edge:
;#
;# ```typelisp
;# (defenum Tree
;#   (Leaf i64)
;#   (Node (Box Tree) (Box Tree)))
;#
;# (define (total [t : Tree]) : i64
;#   (match t
;#     [(Tree.Leaf value) value]
;#     [(Tree.Node left right)
;#       (+ (total (box-take left)) (total (box-take right)))]))
;#
;# (define (main) : i64
;#   (let
;#     [tree : Tree
;#       (Tree.Node
;#         (box (Tree.Leaf 20))
;#         (box (Tree.Node (box (Tree.Leaf 15)) (box (Tree.Leaf 7)))))]
;#     (total tree)))
;# ```
;#
;# ## 7. Comptime instead of generics
;#
;# TypeLisp has no source-level generics, traits, or `impl` blocks, and is not
;# planning them. Abstraction comes from compile-time code that generates
;# concrete declarations. A generic collection is an ordinary module import with
;# a type argument:
;#
;# ```typelisp
;# (import stdlib.vector)
;# (import (vector.vector i64) as ints)
;#
;# (define (main) : i64
;#   (let
;#     [xs : ints.Vec (ints.with-capacity 4)]
;#     (begin
;#       (ints.push (&mut xs) 40)
;#       (ints.push (&mut xs) 2)
;#       (+ (ints.get (& xs) 0 0) (ints.get (& xs) 1 0)))))
;# ```
;#
;# `(vector.vector i64)` generates a concrete `Vec` of `i64` at compile time.
;# The same shape gives you `stdlib.hashmap`, `stdlib.set`, and the generated
;# thread and channel modules in `stdlib.thread` / `stdlib.sync`.
;#
;# ## Where to go next
;#
;# - The README covers the whole language surface as reference prose.
;# - SPEC.md is the authoritative contract, section by section.
;# - `examples/arena_lifetimes.tl` is a runnable cookbook for the arena
;#   patterns in section 5, and `examples/safe_threading.tl` for task threads.
;# - Editor support: `tools/vs-code-extension` installs a `.vsix` with syntax
;#   highlighting and the language server, which downloads its own compiler.
(module docs.getting_started)