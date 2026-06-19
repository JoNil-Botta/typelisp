;# Generated concrete vector family (collections v1, #835/#1989).
;#
;# A growable, owned sequence built on the fixed `(Array T)` primitive: a
;# backing array plus a live-element count (`len`). Capacity is the backing array
;# length; `push` doubles the backing array when it is full, copying the live
;# prefix into the larger array. `I64Vec` keeps the original monomorphic API as
;# the compatibility template, and the generated declarations in this module use
;# stable `vector-family` metadata keyed by element type.
;#
;# Mutating operations thread the vector forward (like `stdlib/hashmap.tl`):
;# `set!` mutates the backing array in place and returns the same vector, while
;# `push`/`pop` may reallocate, so callers must use the returned vector. Reads
;# are bounds-checked and return a caller-supplied fallback rather than
;# panicking, so the module typechecks on every stage0 regardless of the
;# never-type.
;#
;# Generated vector-family metadata is type-agnostic. Struct and enum element
;# instantiations use the same `(Array T)` storage and `array-ref`/`array-set!`
;# move pattern as scalar and `String` families: `push`/`set!` move the element
;# into a live slot, `pop` moves the last live element out with the shrunk
;# vector, and copying/growth/snapshot helpers move the live prefix into fresh
;# arrays. On the current handle representation aggregate elements occupy
;# handle slots; after the inline-aggregate representation flip (#1867/#2357)
;# the same source API stores aggregate elements inline in the backing array.
;#
;# Compiler code should use generated vectors for append-heavy private sequences
;# that are not part of the user-facing AST shape, such as IR instructions,
;# tool discovery buffers, or temporary ordered worklists. Recursive enum lists
;# remain the better fit for parser/AST structures where the cons shape is the
;# language model, pattern matching is the main operation, or preserving a stable
;# checked-in recursive representation matters more than append throughput.
;#
;# Usage: `(import "stdlib/vector.tl")`
;#
;# ```typelisp
;# (import "stdlib/vector.tl")
;# (define (main) : i64
;#   (let
;#     [v : I64Vec (i64-vec-push (i64-vec-push (i64-vec-new) 10) 32)]
;#     (+ (i64-vec-get v 0 0) (i64-vec-get v 1 0))))
;# ```
;#
;# The declaration-emitting `(vector T)` macro is the migration path away from
;# hand-written `comptime-decl` vector families. It splices a local `Vec` type
;# plus `new`, `push`, `len`, `get`, `set`, and `capacity` declarations for the
;# requested element type:
;#
;# ```typelisp
;# (import "stdlib/vector.tl")
;#
;# (vector i64)
;#
;# (define (main) : i64
;#   (let
;#     [v : Vec (push (push (new) 10) 32)]
;#     (+ (get v 0 0) (get v 1 0))))
;# ```
;: Emit a local growable vector family for element type `T`.
;:
;: The generated declarations are intended for one vector instantiation per
;: module while the final module-returning family is still maturing. They define
;: `Vec`, `new`, `push`, `len`, `get`, `set`, and `capacity`; helper names
;: `vec-copy-range` and `vec-grow` are also emitted into the current module.
(defmacro (vector [T : type]) : Decls
  `(begin
    (defstruct Vec
      (slots (Array ,T))
      (len i64))
    (define (new) : Vec
      (Vec (make-array ,T 4) 0))
    (define (len [v : Vec]) : i64
      (struct-get v len))
    (define (capacity [v : Vec]) : i64
      (array-length (struct-get v slots)))
    (define (get [v : Vec] [index : i64] [fallback : ,T]) : ,T
      (if (if (>= index 0)
        (< index (len v))
        false)
        (array-ref (struct-get v slots) index)
        fallback))
    (define (set [v : Vec] [index : i64] [value : ,T]) : Vec
      (begin
        (if (if (>= index 0)
          (< index (len v))
          false)
          (array-set! (struct-get v slots) index value)
          unit)
        v))
    (define (vec-copy-range
      [dst : (Array ,T)]
      [src : (Array ,T)]
      [index : i64]
      [count : i64]) : unit
      (if (>= index count)
        unit
        (begin
          (array-set! dst index (array-ref src index))
          (vec-copy-range dst src (+ index 1) count))))
    (define (vec-grow [v : Vec]) : Vec
      (let
        [n : i64 (len v)]
        [bigger : (Array ,T) (make-array ,T (* (capacity v) 2))]
        (begin
          (vec-copy-range bigger (struct-get v slots) 0 n)
          (set! (struct-get v slots) bigger)
          v)))
    (define (push [v : Vec] [value : ,T]) : Vec
      (if (< (len v) (capacity v))
        (let
          [slots : (Array ,T) (struct-get v slots)]
          [index : i64 (len v)]
          (begin
            (array-set! slots index value)
            (set! (struct-get v len) (+ index 1))
            v))
        (push (vec-grow v) value)))))

(export (macro vector))

;: A growable `i64` sequence: the backing array and the number of live
;: elements stored in its prefix `[0, len)`. Capacity is `(array-length slots)`.
(comptime-decl
  (:generated vector-family I64Vec "i64")
  (defstruct I64Vec
    (slots (Array i64))
    (len i64)))

;: Result of `i64-vec-pop`: the removed last element together with the shrunk
;: vector, or `Empty` when the vector had no elements.
(comptime-decl
  (:generated vector-family I64VecPop "i64")
  (defenum I64VecPop
    (I64VecPopEmpty)
    (I64VecPopOk i64 I64Vec)))

;: The vector's backing array. Only the prefix `[0, len)` holds live elements.
(comptime-decl
  (:generated vector-family i64-vec-slots "i64")
  (define (i64-vec-slots [v : I64Vec]) : (Array i64)
    (struct-get v slots)))

;: Number of live elements.
(comptime-decl
  (:generated vector-family i64-vec-len "i64")
  (define (i64-vec-len [v : I64Vec]) : i64
    (struct-get v len)))

;: Number of slots in the backing array (the current capacity).
(comptime-decl
  (:generated vector-family i64-vec-capacity "i64")
  (define (i64-vec-capacity [v : I64Vec]) : i64
    (array-length (struct-get v slots))))

;: True when the vector holds no live elements.
(comptime-decl
  (:generated vector-family i64-vec-is-empty? "i64")
  (define (i64-vec-is-empty? [v : I64Vec]) : bool
    (<= (i64-vec-len v) 0)))

;: Create an empty vector with backing capacity `capacity`. A non-positive
;: capacity is clamped to 1 so the backing array can always grow by doubling.
(comptime-decl
  (:generated vector-family i64-vec-with-capacity "i64")
  (define (i64-vec-with-capacity [capacity : i64]) : I64Vec
    (let
      [cap : i64
        (if (< capacity 1)
          1
          capacity)]
      (I64Vec (make-array i64 cap) 0))))

;: Create an empty vector with a small default capacity.
(comptime-decl
  (:generated vector-family i64-vec-new "i64")
  (define (i64-vec-new) : I64Vec
    (i64-vec-with-capacity 4)))

;: Read element `index`, returning `fallback` when `index` is out of the live
;: range `[0, len)`.
(comptime-decl
  (:generated vector-family i64-vec-get "i64")
  (define (i64-vec-get [v : I64Vec] [index : i64] [fallback : i64]) : i64
    (if (if (>= index 0)
      (< index (i64-vec-len v))
      false)
      (array-ref (i64-vec-slots v) index)
      fallback)))

;: Read the last live element, or `fallback` when the vector is empty.
(comptime-decl
  (:generated vector-family i64-vec-last "i64")
  (define (i64-vec-last [v : I64Vec] [fallback : i64]) : i64
    (i64-vec-get v (- (i64-vec-len v) 1) fallback)))

;: Overwrite element `index` in place when it is within `[0, len)`; otherwise
;: leave the vector unchanged. Returns the same vector either way.
(comptime-decl
  (:generated vector-family i64-vec-set! "i64")
  (define (i64-vec-set! [v : I64Vec] [index : i64] [value : i64]) : I64Vec
    (begin
      (if (if (>= index 0)
        (< index (i64-vec-len v))
        false)
        (array-set! (i64-vec-slots v) index value)
        unit)
      v)))

;: Copy elements `[index, count)` from `src` into `dst`.
(comptime-decl
  (:generated vector-family i64-vec-copy-range "i64")
  (define (i64-vec-copy-range
    [dst : (Array i64)]
    [src : (Array i64)]
    [index : i64]
    [count : i64]) : unit
    (if (>= index count)
      unit
      (begin
        (array-set! dst index (array-ref src index))
        (i64-vec-copy-range dst src (+ index 1) count)))))

;: Grow `v` to a backing array twice as large, preserving the live prefix.
;: Capacity is always positive (see `i64-vec-with-capacity`), so doubling
;: strictly grows the array.
(comptime-decl
  (:generated vector-family i64-vec-grow "i64")
  (define (i64-vec-grow [v : I64Vec]) : I64Vec
    (let
      [n : i64 (i64-vec-len v)]
      [bigger : (Array i64) (make-array i64 (* (i64-vec-capacity v) 2))]
      (begin
        (i64-vec-copy-range bigger (i64-vec-slots v) 0 n)
        (set! (struct-get v slots) bigger)
        v))))

;: Append `value` to the end, growing the backing array first when it is full.
;: Returns the updated vector, which callers must thread forward because a push
;: that grows reallocates the backing array.
(comptime-decl
  (:generated vector-family i64-vec-push "i64")
  (define (i64-vec-push [v : I64Vec] [value : i64]) : I64Vec
    (if (< (i64-vec-len v) (i64-vec-capacity v))
      (let
        [slots : (Array i64) (i64-vec-slots v)]
        [index : i64 (i64-vec-len v)]
        (begin
          (array-set! slots index value)
          (set! (struct-get v len) (+ index 1))
          v))
      (i64-vec-push (i64-vec-grow v) value))))

;: Remove and return the last element together with the shrunk vector, or
;: `Empty` when the vector has no elements. The backing array is shared with the
;: input vector (only `len` shrinks), so do not keep using the popped vector.
(comptime-decl
  (:generated vector-family i64-vec-pop "i64")
  (define (i64-vec-pop [v : I64Vec]) : I64VecPop
    (if (<= (i64-vec-len v) 0)
      (I64VecPopEmpty)
      (let
        [last-index : i64 (- (i64-vec-len v) 1)]
        [value : i64 (array-ref (i64-vec-slots v) last-index)]
        (begin
          (set! (struct-get v len) last-index)
          (I64VecPopOk value v))))))

;: Build a vector from the live prefix `[0, count)` of `src`, copied into a
;: fresh backing array. A non-positive `count` yields an empty vector; the
;: backing capacity is at least 1 so the result can still grow by pushing.
(comptime-decl
  (:generated vector-family i64-vec-from-array "i64")
  (define (i64-vec-from-array [src : (Array i64)] [count : i64]) : I64Vec
    (let
      [n : i64
        (if (< count 0)
          0
          count)]
      [slots : (Array i64)
        (make-array
          i64
          (if (< n 1)
            1
            n))]
      (begin
        (i64-vec-copy-range slots src 0 n)
        (I64Vec slots n)))))

;: Return a fresh `(Array i64)` holding exactly the `len` live elements — a
;: caller-owned snapshot independent of the vector's backing array.
(comptime-decl
  (:generated vector-family i64-vec-to-array "i64")
  (define (i64-vec-to-array [v : I64Vec]) : (Array i64)
    (let
      [n : i64 (i64-vec-len v)]
      [out : (Array i64) (make-array i64 n)]
      (begin
        (i64-vec-copy-range out (i64-vec-slots v) 0 n)
        out))))

;: Push the first `count` elements of `src`, starting at `index`, onto `v`.
(comptime-decl
  (:generated vector-family i64-vec-extend-from "i64")
  (define (i64-vec-extend-from
    [v : I64Vec]
    [src : (Array i64)]
    [index : i64]
    [count : i64]) : I64Vec
    (if (>= index count)
      v
      (i64-vec-extend-from
        (i64-vec-push v (array-ref src index))
        src
        (+ index 1)
        count))))

;: Append the first `count` elements of `src` to `v` (growing as needed) and
;: return the threaded vector.
(comptime-decl
  (:generated vector-family i64-vec-extend "i64")
  (define (i64-vec-extend [v : I64Vec] [src : (Array i64)] [count : i64]) : I64Vec
    (i64-vec-extend-from v src 0 count)))

;: Swap-reverse the slot range `[lo, hi]` in place.
(comptime-decl
  (:generated vector-family i64-vec-reverse-range! "i64")
  (define (i64-vec-reverse-range! [slots : (Array i64)] [lo : i64] [hi : i64]) : unit
    (if (>= lo hi)
      unit
      (let
        [tmp : i64 (array-ref slots lo)]
        (begin
          (array-set! slots lo (array-ref slots hi))
          (array-set! slots hi tmp)
          (i64-vec-reverse-range! slots (+ lo 1) (- hi 1)))))))

;: Reverse the live prefix `[0, len)` in place; return the same vector.
(comptime-decl
  (:generated vector-family i64-vec-reverse! "i64")
  (define (i64-vec-reverse! [v : I64Vec]) : I64Vec
    (begin
      (i64-vec-reverse-range! (i64-vec-slots v) 0 (- (i64-vec-len v) 1))
      v)))

;: Fold live elements at or after `index`, passing the accumulator and current
;: element to `step` and threading the returned accumulator forward.
(comptime-decl
  (:generated vector-family i64-vec-fold-from "i64")
  (define (i64-vec-fold-from
    [v : I64Vec]
    [index : i64]
    [acc : i64]
    [step : (-> i64 i64 i64)]) : i64
    (if (>= index (i64-vec-len v))
      acc
      (i64-vec-fold-from
        v
        (+ index 1)
        (step acc (array-ref (i64-vec-slots v) index))
        step))))

;: Fold all live elements from left to right.
(comptime-decl
  (:generated vector-family i64-vec-fold "i64")
  (define (i64-vec-fold [v : I64Vec] [acc : i64] [step : (-> i64 i64 i64)]) : i64
    (i64-vec-fold-from v 0 acc step)))

;: Build a mapped vector by pushing mapped elements from `index` onward onto
;: `out`. Kept separate so public map helpers reuse the normal growth path.
(comptime-decl
  (:generated vector-family i64-vec-map-build-from "i64")
  (define (i64-vec-map-build-from
    [v : I64Vec]
    [index : i64]
    [out : I64Vec]
    [mapper : (-> i64 i64)]) : I64Vec
    (if (>= index (i64-vec-len v))
      out
      (i64-vec-map-build-from
        v
        (+ index 1)
        (i64-vec-push out (mapper (array-ref (i64-vec-slots v) index)))
        mapper))))

;: Map live elements at or after `index` into a fresh vector, preserving order.
(comptime-decl
  (:generated vector-family i64-vec-map-from "i64")
  (define (i64-vec-map-from [v : I64Vec] [index : i64] [mapper : (-> i64 i64)]) : I64Vec
    (i64-vec-map-build-from v index (i64-vec-new) mapper)))

;: Map all live elements into a fresh vector, preserving order.
(comptime-decl
  (:generated vector-family i64-vec-map "i64")
  (define (i64-vec-map [v : I64Vec] [mapper : (-> i64 i64)]) : I64Vec
    (i64-vec-map-from v 0 mapper)))

;: Sum of the live elements, accumulated from `index`.
(comptime-decl
  (:generated vector-family i64-vec-sum-from "i64")
  (define (i64-vec-sum-from [v : I64Vec] [index : i64] [acc : i64]) : i64
    (if (>= index (i64-vec-len v))
      acc
      (i64-vec-sum-from
        v
        (+ index 1)
        (+ acc (array-ref (i64-vec-slots v) index))))))

;: Sum of the live elements (0 for an empty vector). A concrete monomorphic
;: convenience reduction retained alongside the higher-order fold helpers.
(comptime-decl
  (:generated vector-family i64-vec-sum "i64")
  (define (i64-vec-sum [v : I64Vec]) : i64
    (i64-vec-sum-from v 0 0)))

;: True when `x` is among the live elements at or after `index`.
(comptime-decl
  (:generated vector-family i64-vec-contains-from? "i64")
  (define (i64-vec-contains-from? [v : I64Vec] [x : i64] [index : i64]) : bool
    (if (>= index (i64-vec-len v))
      false
      (if (= (array-ref (i64-vec-slots v) index) x)
        true
        (i64-vec-contains-from? v x (+ index 1))))))

;: True when `x` is among the live elements.
(comptime-decl
  (:generated vector-family i64-vec-contains? "i64")
  (define (i64-vec-contains? [v : I64Vec] [x : i64]) : bool
    (i64-vec-contains-from? v x 0)))

;: A growable `String` sequence generated from the same vector template as
;: `I64Vec`.
(comptime-decl
  (:generated vector-family StringVec "String")
  (defstruct StringVec
    (slots (Array String))
    (len i64)))

;: Result of `string-vec-pop`: the removed last string together with the shrunk
;: vector, or `Empty` when the vector had no elements.
(comptime-decl
  (:generated vector-family StringVecPop "String")
  (defenum StringVecPop
    (StringVecPopEmpty)
    (StringVecPopOk String StringVec)))

;: The vector's backing array. Only the prefix `[0, len)` holds live strings.
(comptime-decl
  (:generated vector-family string-vec-slots "String")
  (define (string-vec-slots [v : StringVec]) : (Array String)
    (struct-get v slots)))

;: Number of live strings.
(comptime-decl
  (:generated vector-family string-vec-len "String")
  (define (string-vec-len [v : StringVec]) : i64
    (struct-get v len)))

;: Number of slots in the backing array (the current capacity).
(comptime-decl
  (:generated vector-family string-vec-capacity "String")
  (define (string-vec-capacity [v : StringVec]) : i64
    (array-length (struct-get v slots))))

;: True when the vector holds no live strings.
(comptime-decl
  (:generated vector-family string-vec-is-empty? "String")
  (define (string-vec-is-empty? [v : StringVec]) : bool
    (<= (string-vec-len v) 0)))

;: Create an empty string vector with backing capacity `capacity`.
(comptime-decl
  (:generated vector-family string-vec-with-capacity "String")
  (define (string-vec-with-capacity [capacity : i64]) : StringVec
    (let
      [cap : i64
        (if (< capacity 1)
          1
          capacity)]
      (StringVec (make-array String cap) 0))))

;: Create an empty string vector with a small default capacity.
(comptime-decl
  (:generated vector-family string-vec-new "String")
  (define (string-vec-new) : StringVec
    (string-vec-with-capacity 4)))

;: Read element `index`, returning `fallback` when `index` is out of range.
(comptime-decl
  (:generated vector-family string-vec-get "String")
  (define (string-vec-get [v : StringVec] [index : i64] [fallback : String]) : String
    (if (if (>= index 0)
      (< index (string-vec-len v))
      false)
      (array-ref (string-vec-slots v) index)
      fallback)))

;: Read the last live string, or `fallback` when the vector is empty.
(comptime-decl
  (:generated vector-family string-vec-last "String")
  (define (string-vec-last [v : StringVec] [fallback : String]) : String
    (string-vec-get v (- (string-vec-len v) 1) fallback)))

;: Overwrite element `index` in place when it is within `[0, len)`.
(comptime-decl
  (:generated vector-family string-vec-set! "String")
  (define (string-vec-set! [v : StringVec] [index : i64] [value : String]) : StringVec
    (begin
      (if (if (>= index 0)
        (< index (string-vec-len v))
        false)
        (array-set! (string-vec-slots v) index value)
        unit)
      v)))

;: Copy elements `[index, count)` from `src` into `dst`.
(comptime-decl
  (:generated vector-family string-vec-copy-range "String")
  (define (string-vec-copy-range
    [dst : (Array String)]
    [src : (Array String)]
    [index : i64]
    [count : i64]) : unit
    (if (>= index count)
      unit
      (begin
        (array-set! dst index (array-ref src index))
        (string-vec-copy-range dst src (+ index 1) count)))))

;: Grow `v` to a backing array twice as large.
(comptime-decl
  (:generated vector-family string-vec-grow "String")
  (define (string-vec-grow [v : StringVec]) : StringVec
    (let
      [n : i64 (string-vec-len v)]
      [bigger : (Array String)
        (make-array String (* (string-vec-capacity v) 2))]
      (begin
        (string-vec-copy-range bigger (string-vec-slots v) 0 n)
        (set! (struct-get v slots) bigger)
        v))))

;: Append `value` to the end, growing the backing array first when it is full.
(comptime-decl
  (:generated vector-family string-vec-push "String")
  (define (string-vec-push [v : StringVec] [value : String]) : StringVec
    (if (< (string-vec-len v) (string-vec-capacity v))
      (let
        [slots : (Array String) (string-vec-slots v)]
        [index : i64 (string-vec-len v)]
        (begin
          (array-set! slots index value)
          (set! (struct-get v len) (+ index 1))
          v))
      (string-vec-push (string-vec-grow v) value))))

;: Remove and return the last string together with the shrunk vector.
(comptime-decl
  (:generated vector-family string-vec-pop "String")
  (define (string-vec-pop [v : StringVec]) : StringVecPop
    (if (<= (string-vec-len v) 0)
      (StringVecPopEmpty)
      (let
        [last-index : i64 (- (string-vec-len v) 1)]
        [value : String (array-ref (string-vec-slots v) last-index)]
        (begin
          (set! (struct-get v len) last-index)
          (StringVecPopOk value v))))))

;: Build a string vector from the live prefix `[0, count)` of `src`.
(comptime-decl
  (:generated vector-family string-vec-from-array "String")
  (define (string-vec-from-array [src : (Array String)] [count : i64]) : StringVec
    (let
      [n : i64
        (if (< count 0)
          0
          count)]
      [slots : (Array String)
        (make-array
          String
          (if (< n 1)
            1
            n))]
      (begin
        (string-vec-copy-range slots src 0 n)
        (StringVec slots n)))))

;: Return a fresh `(Array String)` snapshot of the live prefix.
(comptime-decl
  (:generated vector-family string-vec-to-array "String")
  (define (string-vec-to-array [v : StringVec]) : (Array String)
    (let
      [n : i64 (string-vec-len v)]
      [out : (Array String) (make-array String n)]
      (begin
        (string-vec-copy-range out (string-vec-slots v) 0 n)
        out))))

;: Push the first `count` elements of `src`, starting at `index`, onto `v`.
(comptime-decl
  (:generated vector-family string-vec-extend-from "String")
  (define (string-vec-extend-from
    [v : StringVec]
    [src : (Array String)]
    [index : i64]
    [count : i64]) : StringVec
    (if (>= index count)
      v
      (string-vec-extend-from
        (string-vec-push v (array-ref src index))
        src
        (+ index 1)
        count))))

;: Append the first `count` elements of `src` to `v`.
(comptime-decl
  (:generated vector-family string-vec-extend "String")
  (define (string-vec-extend
    [v : StringVec]
    [src : (Array String)]
    [count : i64]) : StringVec
    (string-vec-extend-from v src 0 count)))

;: Swap-reverse the slot range `[lo, hi]` in place.
(comptime-decl
  (:generated vector-family string-vec-reverse-range! "String")
  (define (string-vec-reverse-range!
    [slots : (Array String)]
    [lo : i64]
    [hi : i64]) : unit
    (if (>= lo hi)
      unit
      (let
        [tmp : String (array-ref slots lo)]
        (begin
          (array-set! slots lo (array-ref slots hi))
          (array-set! slots hi tmp)
          (string-vec-reverse-range! slots (+ lo 1) (- hi 1)))))))

;: Reverse the live prefix `[0, len)` in place; return the same vector.
(comptime-decl
  (:generated vector-family string-vec-reverse! "String")
  (define (string-vec-reverse! [v : StringVec]) : StringVec
    (begin
      (string-vec-reverse-range!
        (string-vec-slots v)
        0
        (- (string-vec-len v) 1))
      v)))

;: True when `x` is among the live strings at or after `index`.
(comptime-decl
  (:generated vector-family string-vec-contains-from? "String")
  (define (string-vec-contains-from? [v : StringVec] [x : String] [index : i64]) : bool
    (if (>= index (string-vec-len v))
      false
      (if (string-eq (array-ref (string-vec-slots v) index) x)
        true
        (string-vec-contains-from? v x (+ index 1))))))

;: True when `x` is among the live strings.
(comptime-decl
  (:generated vector-family string-vec-contains? "String")
  (define (string-vec-contains? [v : StringVec] [x : String]) : bool
    (string-vec-contains-from? v x 0)))

;; Inline coverage migrated from stdlib/tests/vector_api.tl (#3082).
(cfg test (import "test.tl"))

(cfg
  test
  (define (vector-test-assert-owned-string-eq
    [actual : String]
    [expected : String]
    [message : String]) : unit
    (assert-string-eq (& actual) (& expected) message)))

(cfg
  test
  (define (vector-test-pop-ok? [p : I64VecPop]) : bool
    (match p
      [(I64VecPopOk _ _) true]
      [(I64VecPopEmpty) false])))

(cfg
  test
  (define (vector-test-pop-value-or [p : I64VecPop] [fallback : i64]) : i64
    (match p
      [(I64VecPopOk value _) value]
      [(I64VecPopEmpty) fallback])))

(cfg
  test
  (define (vector-test-pop-vec-or [p : I64VecPop] [fallback : I64Vec]) : I64Vec
    (match p
      [(I64VecPopOk _ rest) rest]
      [(I64VecPopEmpty) fallback])))

(cfg
  test
  (define (vector-test-string-pop-ok? [p : StringVecPop]) : bool
    (match p
      [(StringVecPopOk _ _) true]
      [(StringVecPopEmpty) false])))

(cfg
  test
  (define (vector-test-string-pop-value-or
    [p : StringVecPop]
    [fallback : String]) : String
    (match p
      [(StringVecPopOk value _) value]
      [(StringVecPopEmpty) fallback])))

(cfg
  test
  (define (vector-test-string-pop-vec-or
    [p : StringVecPop]
    [fallback : StringVec]) : StringVec
    (match p
      [(StringVecPopOk _ rest) rest]
      [(StringVecPopEmpty) fallback])))

(cfg
  test
  (defenum VecApiTag
    (VecApiTagA i64)
    (VecApiTagB i64)))

(cfg
  test
  (defstruct VecApiPoint
    (x i64)
    (y i64)))

(cfg
  test
  (define (vec-api-tag-score [tag : VecApiTag]) : i64
    (match tag
      [(VecApiTagA value) value]
      [(VecApiTagB value) (+ value 100)])))

(cfg
  test
  (define (vec-api-point-score [point : VecApiPoint]) : i64
    (+ (struct-get point x) (* (struct-get point y) 10))))

(cfg
  test
  (define (vec-api-fold-decimal [acc : i64] [value : i64]) : i64
    (+ (* acc 10) value)))

(cfg
  test
  (define (vec-api-double [value : i64]) : i64
    (* value 2)))

(cfg
  test
  (comptime-decl
    (:generated vector-family VecApiPointVec "VecApiPoint")
    (defstruct VecApiPointVec
      (slots (Array VecApiPoint))
      (len i64))))

(cfg
  test
  (comptime-decl
    (:generated vector-family VecApiPointVecPop "VecApiPoint")
    (defenum VecApiPointVecPop
      (VecApiPointVecPopEmpty)
      (VecApiPointVecPopOk VecApiPoint VecApiPointVec))))

(cfg
  test
  (comptime-decl
    (:generated vector-family vec-api-point-vec-slots "VecApiPoint")
    (define (vec-api-point-vec-slots [v : VecApiPointVec]) : (Array VecApiPoint)
      (struct-get v slots))))

(cfg
  test
  (comptime-decl
    (:generated vector-family vec-api-point-vec-len "VecApiPoint")
    (define (vec-api-point-vec-len [v : VecApiPointVec]) : i64
      (struct-get v len))))

(cfg
  test
  (comptime-decl
    (:generated vector-family vec-api-point-vec-capacity "VecApiPoint")
    (define (vec-api-point-vec-capacity [v : VecApiPointVec]) : i64
      (array-length (struct-get v slots)))))

(cfg
  test
  (comptime-decl
    (:generated vector-family vec-api-point-vec-with-capacity "VecApiPoint")
    (define (vec-api-point-vec-with-capacity [capacity : i64]) : VecApiPointVec
      (let
        [cap : i64
          (if (< capacity 1)
            1
            capacity)]
        (VecApiPointVec (make-array VecApiPoint cap) 0)))))

(cfg
  test
  (comptime-decl
    (:generated vector-family vec-api-point-vec-get "VecApiPoint")
    (define (vec-api-point-vec-get
      [v : VecApiPointVec]
      [index : i64]
      [fallback : VecApiPoint]) : VecApiPoint
      (if (if (>= index 0)
        (< index (vec-api-point-vec-len v))
        false)
        (array-ref (vec-api-point-vec-slots v) index)
        fallback))))

(cfg
  test
  (comptime-decl
    (:generated vector-family vec-api-point-vec-set! "VecApiPoint")
    (define (vec-api-point-vec-set!
      [v : VecApiPointVec]
      [index : i64]
      [value : VecApiPoint]) : VecApiPointVec
      (begin
        (if (if (>= index 0)
          (< index (vec-api-point-vec-len v))
          false)
          (array-set! (vec-api-point-vec-slots v) index value)
          unit)
        v))))

(cfg
  test
  (comptime-decl
    (:generated vector-family vec-api-point-vec-copy-range "VecApiPoint")
    (define (vec-api-point-vec-copy-range
      [dst : (Array VecApiPoint)]
      [src : (Array VecApiPoint)]
      [index : i64]
      [count : i64]) : unit
      (if (>= index count)
        unit
        (begin
          (array-set! dst index (array-ref src index))
          (vec-api-point-vec-copy-range dst src (+ index 1) count))))))

(cfg
  test
  (comptime-decl
    (:generated vector-family vec-api-point-vec-grow "VecApiPoint")
    (define (vec-api-point-vec-grow [v : VecApiPointVec]) : VecApiPointVec
      (let
        [n : i64 (vec-api-point-vec-len v)]
        [bigger : (Array VecApiPoint)
          (make-array VecApiPoint (* (vec-api-point-vec-capacity v) 2))]
        (begin
          (vec-api-point-vec-copy-range bigger (vec-api-point-vec-slots v) 0 n)
          (set! (struct-get v slots) bigger)
          v)))))

(cfg
  test
  (comptime-decl
    (:generated vector-family vec-api-point-vec-push "VecApiPoint")
    (define (vec-api-point-vec-push [v : VecApiPointVec] [value : VecApiPoint]) : VecApiPointVec
      (if (< (vec-api-point-vec-len v) (vec-api-point-vec-capacity v))
        (let
          [slots : (Array VecApiPoint) (vec-api-point-vec-slots v)]
          [index : i64 (vec-api-point-vec-len v)]
          (begin
            (array-set! slots index value)
            (set! (struct-get v len) (+ index 1))
            v))
        (vec-api-point-vec-push (vec-api-point-vec-grow v) value)))))

(cfg
  test
  (comptime-decl
    (:generated vector-family vec-api-point-vec-pop "VecApiPoint")
    (define (vec-api-point-vec-pop [v : VecApiPointVec]) : VecApiPointVecPop
      (if (<= (vec-api-point-vec-len v) 0)
        (VecApiPointVecPopEmpty)
        (let
          [last-index : i64 (- (vec-api-point-vec-len v) 1)]
          [value : VecApiPoint
            (array-ref (vec-api-point-vec-slots v) last-index)]
          (begin
            (set! (struct-get v len) last-index)
            (VecApiPointVecPopOk value v)))))))

(cfg
  test
  (comptime-decl
    (:generated vector-family vec-api-point-vec-to-array "VecApiPoint")
    (define (vec-api-point-vec-to-array [v : VecApiPointVec]) : (Array
        VecApiPoint)
      (let
        [n : i64 (vec-api-point-vec-len v)]
        [out : (Array VecApiPoint) (make-array VecApiPoint n)]
        (begin
          (vec-api-point-vec-copy-range out (vec-api-point-vec-slots v) 0 n)
          out)))))

(cfg
  test
  (comptime-decl
    (:generated vector-family vec-api-point-vec-score-from "VecApiPoint")
    (define (vec-api-point-vec-score-from
      [v : VecApiPointVec]
      [index : i64]
      [acc : i64]) : i64
      (if (>= index (vec-api-point-vec-len v))
        acc
        (vec-api-point-vec-score-from
          v
          (+ index 1)
          (+
            acc
            (let
              [point : VecApiPoint
                (array-ref (vec-api-point-vec-slots v) index)]
              (+ (struct-get point x) (* (struct-get point y) 10)))))))))

(cfg
  test
  (comptime-decl
    (:generated vector-family vec-api-point-vec-score "VecApiPoint")
    (define (vec-api-point-vec-score [v : VecApiPointVec]) : i64
      (vec-api-point-vec-score-from v 0 0))))

(cfg
  test
  (comptime-decl
    (:generated vector-family VecApiTagVec "VecApiTag")
    (defstruct VecApiTagVec
      (slots (Array VecApiTag))
      (len i64))))

(cfg
  test
  (comptime-decl
    (:generated vector-family VecApiTagVecPop "VecApiTag")
    (defenum VecApiTagVecPop
      (VecApiTagVecPopEmpty)
      (VecApiTagVecPopOk VecApiTag VecApiTagVec))))

(cfg
  test
  (comptime-decl
    (:generated vector-family vec-api-tag-vec-slots "VecApiTag")
    (define (vec-api-tag-vec-slots [v : VecApiTagVec]) : (Array VecApiTag)
      (struct-get v slots))))

(cfg
  test
  (comptime-decl
    (:generated vector-family vec-api-tag-vec-len "VecApiTag")
    (define (vec-api-tag-vec-len [v : VecApiTagVec]) : i64
      (struct-get v len))))

(cfg
  test
  (comptime-decl
    (:generated vector-family vec-api-tag-vec-capacity "VecApiTag")
    (define (vec-api-tag-vec-capacity [v : VecApiTagVec]) : i64
      (array-length (struct-get v slots)))))

(cfg
  test
  (comptime-decl
    (:generated vector-family vec-api-tag-vec-with-capacity "VecApiTag")
    (define (vec-api-tag-vec-with-capacity [capacity : i64]) : VecApiTagVec
      (let
        [cap : i64
          (if (< capacity 1)
            1
            capacity)]
        (VecApiTagVec (make-array VecApiTag cap) 0)))))

(cfg
  test
  (comptime-decl
    (:generated vector-family vec-api-tag-vec-get "VecApiTag")
    (define (vec-api-tag-vec-get
      [v : VecApiTagVec]
      [index : i64]
      [fallback : VecApiTag]) : VecApiTag
      (if (if (>= index 0)
        (< index (vec-api-tag-vec-len v))
        false)
        (array-ref (vec-api-tag-vec-slots v) index)
        fallback))))

(cfg
  test
  (comptime-decl
    (:generated vector-family vec-api-tag-vec-set! "VecApiTag")
    (define (vec-api-tag-vec-set!
      [v : VecApiTagVec]
      [index : i64]
      [value : VecApiTag]) : VecApiTagVec
      (begin
        (if (if (>= index 0)
          (< index (vec-api-tag-vec-len v))
          false)
          (array-set! (vec-api-tag-vec-slots v) index value)
          unit)
        v))))

(cfg
  test
  (comptime-decl
    (:generated vector-family vec-api-tag-vec-copy-range "VecApiTag")
    (define (vec-api-tag-vec-copy-range
      [dst : (Array VecApiTag)]
      [src : (Array VecApiTag)]
      [index : i64]
      [count : i64]) : unit
      (if (>= index count)
        unit
        (begin
          (array-set! dst index (array-ref src index))
          (vec-api-tag-vec-copy-range dst src (+ index 1) count))))))

(cfg
  test
  (comptime-decl
    (:generated vector-family vec-api-tag-vec-grow "VecApiTag")
    (define (vec-api-tag-vec-grow [v : VecApiTagVec]) : VecApiTagVec
      (let
        [n : i64 (vec-api-tag-vec-len v)]
        [bigger : (Array VecApiTag)
          (make-array VecApiTag (* (vec-api-tag-vec-capacity v) 2))]
        (begin
          (vec-api-tag-vec-copy-range bigger (vec-api-tag-vec-slots v) 0 n)
          (set! (struct-get v slots) bigger)
          v)))))

(cfg
  test
  (comptime-decl
    (:generated vector-family vec-api-tag-vec-push "VecApiTag")
    (define (vec-api-tag-vec-push [v : VecApiTagVec] [value : VecApiTag]) : VecApiTagVec
      (if (< (vec-api-tag-vec-len v) (vec-api-tag-vec-capacity v))
        (let
          [slots : (Array VecApiTag) (vec-api-tag-vec-slots v)]
          [index : i64 (vec-api-tag-vec-len v)]
          (begin
            (array-set! slots index value)
            (set! (struct-get v len) (+ index 1))
            v))
        (vec-api-tag-vec-push (vec-api-tag-vec-grow v) value)))))

(cfg
  test
  (comptime-decl
    (:generated vector-family vec-api-tag-vec-pop "VecApiTag")
    (define (vec-api-tag-vec-pop [v : VecApiTagVec]) : VecApiTagVecPop
      (if (<= (vec-api-tag-vec-len v) 0)
        (VecApiTagVecPopEmpty)
        (let
          [last-index : i64 (- (vec-api-tag-vec-len v) 1)]
          [value : VecApiTag (array-ref (vec-api-tag-vec-slots v) last-index)]
          (begin
            (set! (struct-get v len) last-index)
            (VecApiTagVecPopOk value v)))))))

(cfg
  test
  (comptime-decl
    (:generated vector-family vec-api-tag-vec-to-array "VecApiTag")
    (define (vec-api-tag-vec-to-array [v : VecApiTagVec]) : (Array VecApiTag)
      (let
        [n : i64 (vec-api-tag-vec-len v)]
        [out : (Array VecApiTag) (make-array VecApiTag n)]
        (begin
          (vec-api-tag-vec-copy-range out (vec-api-tag-vec-slots v) 0 n)
          out)))))

(cfg
  test
  (define (vector-test-tag-pop-ok? [p : VecApiTagVecPop]) : bool
    (match p
      [(VecApiTagVecPopOk _ _) true]
      [(VecApiTagVecPopEmpty) false])))

(cfg
  test
  (define (vector-test-tag-pop-score-or [p : VecApiTagVecPop] [fallback : i64]) : i64
    (match p
      [(VecApiTagVecPopOk value _) (vec-api-tag-score value)]
      [(VecApiTagVecPopEmpty) fallback])))

(cfg
  test
  (define (vector-test-tag-pop-vec-or
    [p : VecApiTagVecPop]
    [fallback : VecApiTagVec]) : VecApiTagVec
    (match p
      [(VecApiTagVecPopOk _ rest) rest]
      [(VecApiTagVecPopEmpty) fallback])))

(cfg
  test
  (define (vector-test-point-pop-ok? [p : VecApiPointVecPop]) : bool
    (match p
      [(VecApiPointVecPopOk _ _) true]
      [(VecApiPointVecPopEmpty) false])))

(cfg
  test
  (define (vector-test-point-pop-score-or
    [p : VecApiPointVecPop]
    [fallback : i64]) : i64
    (match p
      [(VecApiPointVecPopOk value _) (vec-api-point-score value)]
      [(VecApiPointVecPopEmpty) fallback])))

(cfg
  test
  (define (vector-test-point-pop-vec-or
    [p : VecApiPointVecPop]
    [fallback : VecApiPointVec]) : VecApiPointVec
    (match p
      [(VecApiPointVecPopOk _ rest) rest]
      [(VecApiPointVecPopEmpty) fallback])))

(cfg
  test
  (define (vector-test-main) : i64
    (begin
      ;; --- empty vector: len/capacity/is-empty? ---
      (let
        [empty : I64Vec (i64-vec-with-capacity 2)]
        (begin
          (assert-i64-eq (i64-vec-len empty) 0 "empty len 0")
          (assert-i64-eq (i64-vec-capacity empty) 2 "empty capacity 2")
          (assert-true (i64-vec-is-empty? empty) "empty is-empty?")
          ;; out-of-range reads fall back
          (assert-i64-eq (i64-vec-get empty 0 -1) -1 "empty get 0 fallback")
          (assert-i64-eq (i64-vec-last empty -1) -1 "empty last fallback")))
      ;; --- non-positive capacity is clamped to 1 ---
      (assert-i64-eq
        (i64-vec-capacity (i64-vec-with-capacity 0))
        1
        "zero capacity clamps to 1")
      (assert-true (>= (i64-vec-capacity (i64-vec-new)) 1) "new has capacity")
      ;; --- push within capacity: no growth ---
      (let
        [v2 : I64Vec
          (i64-vec-push (i64-vec-push (i64-vec-with-capacity 2) 10) 20)]
        (begin
          (assert-i64-eq (i64-vec-len v2) 2 "two pushes -> len 2")
          (assert-i64-eq (i64-vec-capacity v2) 2 "still capacity 2")
          (assert-i64-eq (i64-vec-get v2 0 -1) 10 "get 0 -> 10")
          (assert-i64-eq (i64-vec-get v2 1 -1) 20 "get 1 -> 20")
          (assert-i64-eq (i64-vec-last v2 -1) 20 "last -> 20")
          ;; index at len and a negative index both fall back
          (assert-i64-eq (i64-vec-get v2 2 -1) -1 "get at len fallback")
          (assert-i64-eq (i64-vec-get v2 -1 -1) -1 "get negative fallback")
          ;; --- push past capacity: grows, preserves prefix ---
          (let
            [v3 : I64Vec (i64-vec-push v2 30)]
            (begin
              (assert-i64-eq (i64-vec-len v3) 3 "third push -> len 3")
              (assert-i64-eq (i64-vec-capacity v3) 4 "grew to capacity 4")
              (assert-i64-eq
                (i64-vec-get v3 0 -1)
                10
                "prefix preserved: 0 -> 10")
              (assert-i64-eq
                (i64-vec-get v3 1 -1)
                20
                "prefix preserved: 1 -> 20")
              (assert-i64-eq (i64-vec-get v3 2 -1) 30 "new element: 2 -> 30")
              (assert-i64-eq (i64-vec-last v3 -1) 30 "last -> 30")
              ;; --- set! mutates in place within bounds ---
              (let
                [v4 : I64Vec (i64-vec-set! v3 1 99)]
                (begin
                  (assert-i64-eq (i64-vec-get v4 1 -1) 99 "set! 1 -> 99")
                  (assert-i64-eq (i64-vec-len v4) 3 "set! keeps len")
                  ;; out-of-range set! is a no-op
                  (i64-vec-set! v4 5 7)
                  (assert-i64-eq
                    (i64-vec-get v4 5 -1)
                    -1
                    "set! out of range no-op")
                  ;; --- pop: last element + shrunk vector ---
                  (let
                    [popped : I64VecPop (i64-vec-pop v4)]
                    (begin
                      (assert-true (vector-test-pop-ok? popped) "pop ok")
                      (assert-i64-eq
                        (vector-test-pop-value-or popped -1)
                        30
                        "pop value -> 30")
                      (let
                        [rest : I64Vec (vector-test-pop-vec-or popped v4)]
                        (begin
                          (assert-i64-eq (i64-vec-len rest) 2 "pop shrinks len")
                          (assert-i64-eq
                            (i64-vec-last rest -1)
                            99
                            "rest last -> 99")))))))))))
      ;; --- returned handles can be threaded through mutable locals ---
      (let
        [mut : I64Vec (i64-vec-with-capacity 1)]
        (begin
          (set! mut (i64-vec-push mut 41))
          (assert-i64-eq (i64-vec-len mut) 1 "mutable push len 1")
          (assert-i64-eq (i64-vec-capacity mut) 1 "mutable push no growth")
          (set! mut (i64-vec-push mut 42))
          (assert-i64-eq (i64-vec-len mut) 2 "mutable growth push len 2")
          (assert-i64-eq (i64-vec-capacity mut) 2 "mutable growth capacity 2")
          (set! mut (i64-vec-set! mut 0 40))
          (assert-i64-eq (i64-vec-get mut 0 -1) 40 "mutable set after push")
          (set! mut (i64-vec-reverse! mut))
          (assert-i64-eq (i64-vec-get mut 0 -1) 42 "mutable reverse first")
          (assert-i64-eq (i64-vec-get mut 1 -1) 40 "mutable reverse second")
          (match (i64-vec-pop mut)
            [(I64VecPopOk value rest)
              (begin
                (set! mut rest)
                (assert-i64-eq value 40 "mutable pop value")
                (assert-i64-eq (i64-vec-len mut) 1 "mutable pop len 1")
                (assert-i64-eq (i64-vec-last mut -1) 42 "mutable pop rest last"))]
            [(I64VecPopEmpty) (assert-true false "mutable pop should be ok")])))
      ;; --- pop on an empty vector is Empty ---
      (let
        [pe : I64VecPop (i64-vec-pop (i64-vec-with-capacity 1))]
        (begin
          (assert-true (not (vector-test-pop-ok? pe)) "empty pop not ok")
          (assert-i64-eq
            (vector-test-pop-value-or pe -1)
            -1
            "empty pop value fallback")))
      ;; --- from-array / to-array round-trip (#1212) ---
      (let
        [src : (Array i64) (make-array i64 3)]
        (begin
          (array-set! src 0 5)
          (array-set! src 1 6)
          (array-set! src 2 7)
          ;; from-array copies the live prefix [0, count)
          (let
            [fv : I64Vec (i64-vec-from-array src 3)]
            (begin
              (assert-i64-eq (i64-vec-len fv) 3 "from-array len 3")
              (assert-i64-eq (i64-vec-get fv 0 -1) 5 "from-array[0] = 5")
              (assert-i64-eq (i64-vec-get fv 2 -1) 7 "from-array[2] = 7")
              ;; sum + contains? over the live elements
              (assert-i64-eq (i64-vec-sum fv) 18 "sum 5+6+7 = 18")
              (assert-true (i64-vec-contains? fv 6) "contains 6")
              (assert-false (i64-vec-contains? fv 99) "does not contain 99")
              ;; to-array snapshot has exactly len elements and is independent
              (let
                [snap : (Array i64) (i64-vec-to-array fv)]
                (begin
                  (assert-i64-eq (array-length snap) 3 "to-array length = len")
                  (assert-i64-eq (array-ref snap 1) 6 "to-array[1] = 6")
                  ;; mutating the snapshot does not affect the vector
                  (array-set! snap 1 0)
                  (assert-i64-eq
                    (i64-vec-get fv 1 -1)
                    6
                    "vector unaffected by snapshot mutation")))
              ;; reverse! reverses the live prefix in place
              (let
                [rv : I64Vec (i64-vec-reverse! fv)]
                (begin
                  (assert-i64-eq (i64-vec-get rv 0 -1) 7 "reverse![0] = 7")
                  (assert-i64-eq (i64-vec-get rv 2 -1) 5 "reverse![2] = 5")
                  (assert-i64-eq (i64-vec-sum rv) 18 "reverse keeps sum")))))
          ;; from-array with non-positive count yields an empty, growable vector
          (let
            [ev : I64Vec (i64-vec-from-array src 0)]
            (begin
              (assert-true (i64-vec-is-empty? ev) "from-array 0 is empty")
              (assert-true
                (>= (i64-vec-capacity ev) 1)
                "empty from-array still growable")
              ;; extend pushes the first count elements (growing as needed)
              (let
                [xv : I64Vec (i64-vec-extend ev src 3)]
                (begin
                  (assert-i64-eq (i64-vec-len xv) 3 "extend len 3")
                  (assert-i64-eq (i64-vec-get xv 0 -1) 5 "extend[0] = 5")
                  (assert-i64-eq (i64-vec-get xv 2 -1) 7 "extend[2] = 7")
                  (assert-i64-eq (i64-vec-sum xv) 18 "extend sum 18")))))))
      ;; --- I64Vec higher-order fold/map helpers (#2067) ---
      (let
        [src : (Array i64) (make-array i64 5)]
        (begin
          (array-set! src 0 1)
          (array-set! src 1 2)
          (array-set! src 2 3)
          (array-set! src 3 4)
          (array-set! src 4 5)
          (let
            [hv : I64Vec (i64-vec-from-array src 5)]
            (begin
              (assert-i64-eq
                (i64-vec-fold hv 0 vec-api-fold-decimal)
                12345
                "fold named function preserves order")
              (assert-i64-eq
                (i64-vec-fold-from hv 2 10 vec-api-fold-decimal)
                10345
                "fold-from starts at index")
              (assert-i64-eq
                (i64-vec-fold (i64-vec-new) 77 vec-api-fold-decimal)
                77
                "fold empty returns initial")
              (let
                [empty-mapped : I64Vec
                  (i64-vec-map (i64-vec-new) vec-api-double)]
                (begin
                  (assert-i64-eq (i64-vec-len empty-mapped) 0 "map empty len 0")
                  (assert-true
                    (>= (i64-vec-capacity empty-mapped) 1)
                    "map empty remains growable")))
              (let
                [doubled : I64Vec (i64-vec-map hv vec-api-double)]
                (begin
                  (assert-i64-eq (i64-vec-len doubled) 5 "map len 5")
                  (assert-i64-eq
                    (i64-vec-capacity doubled)
                    8
                    "map output grows through push")
                  (assert-i64-eq (i64-vec-get doubled 0 -1) 2 "map order 0")
                  (assert-i64-eq (i64-vec-get doubled 4 -1) 10 "map order 4")))
              (let
                [suffix : I64Vec (i64-vec-map-from hv 2 vec-api-double)]
                (begin
                  (assert-i64-eq (i64-vec-len suffix) 3 "map-from len 3")
                  (assert-i64-eq
                    (i64-vec-get suffix 0 -1)
                    6
                    "map-from first suffix")
                  (assert-i64-eq
                    (i64-vec-get suffix 2 -1)
                    10
                    "map-from last suffix")))
              (let
                [bias : i64 7]
                [biased : I64Vec
                  (i64-vec-map
                    hv
                    (lambda ([x : i64]) : i64
                      (+ x bias)))]
                (begin
                  (assert-i64-eq
                    (i64-vec-get biased 0 -1)
                    8
                    "map scalar-capturing lambda first")
                  (assert-i64-eq
                    (i64-vec-get biased 4 -1)
                    12
                    "map scalar-capturing lambda last")))))))
      ;; --- generated StringVec: growth, mutation, pop, snapshot, reverse ---
      (let
        [sv2 : StringVec
          (string-vec-push
            (string-vec-push (string-vec-with-capacity 2) "alpha")
            "beta")]
        (begin
          (assert-i64-eq (string-vec-len sv2) 2 "string two pushes -> len 2")
          (assert-i64-eq
            (string-vec-capacity sv2)
            2
            "string capacity unchanged")
          (vector-test-assert-owned-string-eq
            (string-vec-get sv2 0 "missing")
            "alpha"
            "string get 0")
          (vector-test-assert-owned-string-eq
            (string-vec-last sv2 "missing")
            "beta"
            "string last")
          (let
            [sv3 : StringVec (string-vec-push sv2 "gamma")]
            (begin
              (assert-i64-eq (string-vec-len sv3) 3 "string third push len")
              (assert-i64-eq (string-vec-capacity sv3) 4 "string grow capacity")
              (assert-true
                (string-vec-contains? sv3 "beta")
                "string contains beta")
              (let
                [sv4 : StringVec (string-vec-set! sv3 1 "BETA")]
                (begin
                  (vector-test-assert-owned-string-eq
                    (string-vec-get sv4 1 "missing")
                    "BETA"
                    "string set! 1")
                  (let
                    [popped : StringVecPop (string-vec-pop sv4)]
                    (begin
                      (assert-true
                        (vector-test-string-pop-ok? popped)
                        "string pop ok")
                      (vector-test-assert-owned-string-eq
                        (vector-test-string-pop-value-or popped "missing")
                        "gamma"
                        "string pop value")
                      (let
                        [rest : StringVec
                          (vector-test-string-pop-vec-or popped sv4)]
                        (begin
                          (assert-i64-eq
                            (string-vec-len rest)
                            2
                            "string pop shrinks")
                          (let
                            [snap : (Array String) (string-vec-to-array rest)]
                            (begin
                              (assert-i64-eq
                                (array-length snap)
                                2
                                "string snapshot length")
                              (vector-test-assert-owned-string-eq
                                (array-ref snap 1)
                                "BETA"
                                "string snapshot value")
                              (array-set! snap 1 "changed")
                              (vector-test-assert-owned-string-eq
                                (string-vec-get rest 1 "missing")
                                "BETA"
                                "string snapshot independent")))
                          (let
                            [rv : StringVec (string-vec-reverse! rest)]
                            (begin
                              (vector-test-assert-owned-string-eq
                                (string-vec-get rv 0 "missing")
                                "BETA"
                                "string reverse first")
                              (vector-test-assert-owned-string-eq
                                (string-vec-get rv 1 "missing")
                                "alpha"
                                "string reverse second")))))))))))))
      ;; --- generated nominal enum payload vector witness ---
      (let
        [tv2 : VecApiTagVec
          (vec-api-tag-vec-push
            (vec-api-tag-vec-push
              (vec-api-tag-vec-with-capacity 1)
              (VecApiTagA 1))
            (VecApiTagB 2))]
        (begin
          (assert-i64-eq (vec-api-tag-vec-len tv2) 2 "tag vec len")
          (assert-i64-eq (vec-api-tag-vec-capacity tv2) 2 "tag vec grew")
          (assert-i64-eq
            (vec-api-tag-score (vec-api-tag-vec-get tv2 1 (VecApiTagA 0)))
            102
            "tag vec get")
          (let
            [tv3 : VecApiTagVec (vec-api-tag-vec-set! tv2 0 (VecApiTagB 7))]
            (begin
              (assert-i64-eq
                (vec-api-tag-score (vec-api-tag-vec-get tv3 0 (VecApiTagA 0)))
                107
                "tag vec set!")
              (let
                [popped : VecApiTagVecPop (vec-api-tag-vec-pop tv3)]
                (begin
                  (assert-true (vector-test-tag-pop-ok? popped) "tag pop ok")
                  (assert-i64-eq
                    (vector-test-tag-pop-score-or popped -1)
                    102
                    "tag pop value")
                  (let
                    [rest : VecApiTagVec
                      (vector-test-tag-pop-vec-or popped tv3)]
                    (begin
                      (assert-i64-eq (vec-api-tag-vec-len rest) 1 "tag pop len")
                      (let
                        [snap : (Array VecApiTag)
                          (vec-api-tag-vec-to-array rest)]
                        (begin
                          (assert-i64-eq
                            (array-length snap)
                            1
                            "tag snapshot length")
                          (assert-i64-eq
                            (vec-api-tag-score (array-ref snap 0))
                            107
                            "tag snapshot value")
                          (array-set! snap 0 (VecApiTagA 99))
                          (assert-i64-eq
                            (vec-api-tag-score
                              (vec-api-tag-vec-get rest 0 (VecApiTagA 0)))
                            107
                            "tag snapshot independent")))))))))))
      ;; --- generated nominal struct element vector witness (#2564) ---
      (let
        [pv2 : VecApiPointVec
          (vec-api-point-vec-push
            (vec-api-point-vec-push
              (vec-api-point-vec-with-capacity 1)
              (VecApiPoint 1 2))
            (VecApiPoint 3 4))]
        (begin
          (assert-i64-eq (vec-api-point-vec-len pv2) 2 "point vec len")
          (assert-i64-eq (vec-api-point-vec-capacity pv2) 2 "point vec grew")
          (assert-i64-eq
            (vec-api-point-score
              (vec-api-point-vec-get pv2 1 (VecApiPoint 0 0)))
            43
            "point vec get")
          (assert-i64-eq
            (vec-api-point-vec-score pv2)
            64
            "point vec index iteration")
          (let
            [pv3 : VecApiPointVec
              (vec-api-point-vec-set! pv2 0 (VecApiPoint 5 6))]
            (begin
              (assert-i64-eq
                (vec-api-point-score
                  (vec-api-point-vec-get pv3 0 (VecApiPoint 0 0)))
                65
                "point vec set!")
              (assert-i64-eq
                (vec-api-point-vec-score pv3)
                108
                "point vec iteration after set!")
              (let
                [pv4 : VecApiPointVec
                  (vec-api-point-vec-set! pv3 99 (VecApiPoint 9 9))]
                (begin
                  (assert-i64-eq
                    (vec-api-point-vec-score pv4)
                    108
                    "point vec out-of-range set! no-op")
                  (let
                    [popped : VecApiPointVecPop (vec-api-point-vec-pop pv4)]
                    (begin
                      (assert-true
                        (vector-test-point-pop-ok? popped)
                        "point pop ok")
                      (assert-i64-eq
                        (vector-test-point-pop-score-or popped -1)
                        43
                        "point pop value")
                      (let
                        [rest : VecApiPointVec
                          (vector-test-point-pop-vec-or popped pv4)]
                        (begin
                          (assert-i64-eq
                            (vec-api-point-vec-len rest)
                            1
                            "point pop len")
                          (let
                            [snap : (Array VecApiPoint)
                              (vec-api-point-vec-to-array rest)]
                            (begin
                              (assert-i64-eq
                                (array-length snap)
                                1
                                "point snapshot length")
                              (assert-i64-eq
                                (vec-api-point-score (array-ref snap 0))
                                65
                                "point snapshot value")
                              (array-set! snap 0 (VecApiPoint 9 9))
                              (assert-i64-eq
                                (vec-api-point-score
                                  (vec-api-point-vec-get
                                    rest
                                    0
                                    (VecApiPoint 0 0)))
                                65
                                "point snapshot independent")))))))))))))
      42)))

(cfg
  test
  (test
    vector-api
    (assert-i64-eq (vector-test-main) 42 "vector-api fixture result")))