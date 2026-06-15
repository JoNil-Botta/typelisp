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
;# Compiler code should use generated vectors for append-heavy private sequences
;# that are not part of the user-facing AST shape, such as IR instructions,
;# tool discovery buffers, or temporary ordered worklists. Recursive enum lists
;# remain the better fit for parser/AST structures where the cons shape is the
;# language model, pattern matching is the main operation, or preserving a stable
;# checked-in recursive representation matters more than append throughput.
;#
;# Usage: `(import stdlib.vector)`
;#
;# ```typelisp
;# (import stdlib.vector)
;# (define (main) : i64
;#   (let
;#     [v : vector.I64Vec (vector.i64-vec-push (vector.i64-vec-push (vector.i64-vec-new) 10) 32)]
;#     (+ (vector.i64-vec-get v 0 0) (vector.i64-vec-get v 1 0))))
;# ```
;: A growable `i64` sequence: the backing array and the number of live
;: elements stored in its prefix `[0, len)`. Capacity is `(array-length slots)`.
(module stdlib.vector)

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
    (<= (stdlib.vector.i64-vec-len v) 0)))

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
    (stdlib.vector.i64-vec-with-capacity 4)))

;: Read element `index`, returning `fallback` when `index` is out of the live
;: range `[0, len)`.
(comptime-decl
  (:generated vector-family i64-vec-get "i64")
  (define (i64-vec-get [v : I64Vec] [index : i64] [fallback : i64]) : i64
    (if (if (>= index 0)
      (< index (stdlib.vector.i64-vec-len v))
      false)
      (array-ref (stdlib.vector.i64-vec-slots v) index)
      fallback)))

;: Read the last live element, or `fallback` when the vector is empty.
(comptime-decl
  (:generated vector-family i64-vec-last "i64")
  (define (i64-vec-last [v : I64Vec] [fallback : i64]) : i64
    (stdlib.vector.i64-vec-get v (- (stdlib.vector.i64-vec-len v) 1) fallback)))

;: Overwrite element `index` in place when it is within `[0, len)`; otherwise
;: leave the vector unchanged. Returns the same vector either way.
(comptime-decl
  (:generated vector-family i64-vec-set! "i64")
  (define (i64-vec-set! [v : I64Vec] [index : i64] [value : i64]) : I64Vec
    (begin
      (if (if (>= index 0)
        (< index (stdlib.vector.i64-vec-len v))
        false)
        (array-set! (stdlib.vector.i64-vec-slots v) index value)
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
        (stdlib.vector.i64-vec-copy-range dst src (+ index 1) count)))))

;: Return a copy of `v` whose backing array is twice as large, preserving the
;: live prefix. Capacity is always positive (see `i64-vec-with-capacity`), so
;: doubling strictly grows the array.
(comptime-decl
  (:generated vector-family i64-vec-grow "i64")
  (define (i64-vec-grow [v : I64Vec]) : I64Vec
    (let
      [n : i64 (stdlib.vector.i64-vec-len v)]
      [bigger : (Array i64)
        (make-array i64 (* (stdlib.vector.i64-vec-capacity v) 2))]
      (begin
        (stdlib.vector.i64-vec-copy-range
          bigger
          (stdlib.vector.i64-vec-slots v)
          0
          n)
        (I64Vec bigger n)))))

;: Append `value` to the end, growing the backing array first when it is full.
;: Returns the updated vector, which callers must thread forward because a push
;: that grows reallocates the backing array.
(comptime-decl
  (:generated vector-family i64-vec-push "i64")
  (define (i64-vec-push [v : I64Vec] [value : i64]) : I64Vec
    (if (< (stdlib.vector.i64-vec-len v) (stdlib.vector.i64-vec-capacity v))
      (let
        [slots : (Array i64) (stdlib.vector.i64-vec-slots v)]
        (begin
          (array-set! slots (stdlib.vector.i64-vec-len v) value)
          (I64Vec slots (+ (stdlib.vector.i64-vec-len v) 1))))
      (stdlib.vector.i64-vec-push (stdlib.vector.i64-vec-grow v) value))))

;: Remove and return the last element together with the shrunk vector, or
;: `Empty` when the vector has no elements. The backing array is shared with the
;: input vector (only `len` shrinks), so do not keep using the popped vector.
(comptime-decl
  (:generated vector-family i64-vec-pop "i64")
  (define (i64-vec-pop [v : I64Vec]) : I64VecPop
    (if (<= (stdlib.vector.i64-vec-len v) 0)
      stdlib.vector.I64VecPopEmpty
      (let
        [last-index : i64 (- (stdlib.vector.i64-vec-len v) 1)]
        (I64VecPopOk
          (array-ref (stdlib.vector.i64-vec-slots v) last-index)
          (I64Vec (stdlib.vector.i64-vec-slots v) last-index))))))

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
        (stdlib.vector.i64-vec-copy-range slots src 0 n)
        (I64Vec slots n)))))

;: Return a fresh `(Array i64)` holding exactly the `len` live elements â€” a
;: caller-owned snapshot independent of the vector's backing array.
(comptime-decl
  (:generated vector-family i64-vec-to-array "i64")
  (define (i64-vec-to-array [v : I64Vec]) : (Array i64)
    (let
      [n : i64 (stdlib.vector.i64-vec-len v)]
      [out : (Array i64) (make-array i64 n)]
      (begin
        (stdlib.vector.i64-vec-copy-range
          out
          (stdlib.vector.i64-vec-slots v)
          0
          n)
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
      (stdlib.vector.i64-vec-extend-from
        (stdlib.vector.i64-vec-push v (array-ref src index))
        src
        (+ index 1)
        count))))

;: Append the first `count` elements of `src` to `v` (growing as needed) and
;: return the threaded vector.
(comptime-decl
  (:generated vector-family i64-vec-extend "i64")
  (define (i64-vec-extend [v : I64Vec] [src : (Array i64)] [count : i64]) : I64Vec
    (stdlib.vector.i64-vec-extend-from v src 0 count)))

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
          (stdlib.vector.i64-vec-reverse-range! slots (+ lo 1) (- hi 1)))))))

;: Reverse the live prefix `[0, len)` in place; return the same vector.
(comptime-decl
  (:generated vector-family i64-vec-reverse! "i64")
  (define (i64-vec-reverse! [v : I64Vec]) : I64Vec
    (begin
      (stdlib.vector.i64-vec-reverse-range!
        (stdlib.vector.i64-vec-slots v)
        0
        (- (stdlib.vector.i64-vec-len v) 1))
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
    (if (>= index (stdlib.vector.i64-vec-len v))
      acc
      (stdlib.vector.i64-vec-fold-from
        v
        (+ index 1)
        (step acc (array-ref (stdlib.vector.i64-vec-slots v) index))
        step))))

;: Fold all live elements from left to right.
(comptime-decl
  (:generated vector-family i64-vec-fold "i64")
  (define (i64-vec-fold [v : I64Vec] [acc : i64] [step : (-> i64 i64 i64)]) : i64
    (stdlib.vector.i64-vec-fold-from v 0 acc step)))

;: Build a mapped vector by pushing mapped elements from `index` onward onto
;: `out`. Kept separate so public map helpers reuse the normal growth path.
(comptime-decl
  (:generated vector-family i64-vec-map-build-from "i64")
  (define (i64-vec-map-build-from
    [v : I64Vec]
    [index : i64]
    [out : I64Vec]
    [mapper : (-> i64 i64)]) : I64Vec
    (if (>= index (stdlib.vector.i64-vec-len v))
      out
      (stdlib.vector.i64-vec-map-build-from
        v
        (+ index 1)
        (stdlib.vector.i64-vec-push
          out
          (mapper (array-ref (stdlib.vector.i64-vec-slots v) index)))
        mapper))))

;: Map live elements at or after `index` into a fresh vector, preserving order.
(comptime-decl
  (:generated vector-family i64-vec-map-from "i64")
  (define (i64-vec-map-from [v : I64Vec] [index : i64] [mapper : (-> i64 i64)]) : I64Vec
    (stdlib.vector.i64-vec-map-build-from
      v
      index
      (stdlib.vector.i64-vec-new)
      mapper)))

;: Map all live elements into a fresh vector, preserving order.
(comptime-decl
  (:generated vector-family i64-vec-map "i64")
  (define (i64-vec-map [v : I64Vec] [mapper : (-> i64 i64)]) : I64Vec
    (stdlib.vector.i64-vec-map-from v 0 mapper)))

;: Sum of the live elements, accumulated from `index`.
(comptime-decl
  (:generated vector-family i64-vec-sum-from "i64")
  (define (i64-vec-sum-from [v : I64Vec] [index : i64] [acc : i64]) : i64
    (if (>= index (stdlib.vector.i64-vec-len v))
      acc
      (stdlib.vector.i64-vec-sum-from
        v
        (+ index 1)
        (+ acc (array-ref (stdlib.vector.i64-vec-slots v) index))))))

;: Sum of the live elements (0 for an empty vector). A concrete monomorphic
;: convenience reduction retained alongside the higher-order fold helpers.
(comptime-decl
  (:generated vector-family i64-vec-sum "i64")
  (define (i64-vec-sum [v : I64Vec]) : i64
    (stdlib.vector.i64-vec-sum-from v 0 0)))

;: True when `x` is among the live elements at or after `index`.
(comptime-decl
  (:generated vector-family i64-vec-contains-from? "i64")
  (define (i64-vec-contains-from? [v : I64Vec] [x : i64] [index : i64]) : bool
    (if (>= index (stdlib.vector.i64-vec-len v))
      false
      (if (= (array-ref (stdlib.vector.i64-vec-slots v) index) x)
        true
        (stdlib.vector.i64-vec-contains-from? v x (+ index 1))))))

;: True when `x` is among the live elements.
(comptime-decl
  (:generated vector-family i64-vec-contains? "i64")
  (define (i64-vec-contains? [v : I64Vec] [x : i64]) : bool
    (stdlib.vector.i64-vec-contains-from? v x 0)))

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
    (<= (stdlib.vector.string-vec-len v) 0)))

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
    (stdlib.vector.string-vec-with-capacity 4)))

;: Read element `index`, returning `fallback` when `index` is out of range.
(comptime-decl
  (:generated vector-family string-vec-get "String")
  (define (string-vec-get [v : StringVec] [index : i64] [fallback : String]) : String
    (if (if (>= index 0)
      (< index (stdlib.vector.string-vec-len v))
      false)
      (array-ref (stdlib.vector.string-vec-slots v) index)
      fallback)))

;: Read the last live string, or `fallback` when the vector is empty.
(comptime-decl
  (:generated vector-family string-vec-last "String")
  (define (string-vec-last [v : StringVec] [fallback : String]) : String
    (stdlib.vector.string-vec-get
      v
      (- (stdlib.vector.string-vec-len v) 1)
      fallback)))

;: Overwrite element `index` in place when it is within `[0, len)`.
(comptime-decl
  (:generated vector-family string-vec-set! "String")
  (define (string-vec-set! [v : StringVec] [index : i64] [value : String]) : StringVec
    (begin
      (if (if (>= index 0)
        (< index (stdlib.vector.string-vec-len v))
        false)
        (array-set! (stdlib.vector.string-vec-slots v) index value)
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
        (stdlib.vector.string-vec-copy-range dst src (+ index 1) count)))))

;: Return a copy of `v` whose backing array is twice as large.
(comptime-decl
  (:generated vector-family string-vec-grow "String")
  (define (string-vec-grow [v : StringVec]) : StringVec
    (let
      [n : i64 (stdlib.vector.string-vec-len v)]
      [bigger : (Array String)
        (make-array String (* (stdlib.vector.string-vec-capacity v) 2))]
      (begin
        (stdlib.vector.string-vec-copy-range
          bigger
          (stdlib.vector.string-vec-slots v)
          0
          n)
        (StringVec bigger n)))))

;: Append `value` to the end, growing the backing array first when it is full.
(comptime-decl
  (:generated vector-family string-vec-push "String")
  (define (string-vec-push [v : StringVec] [value : String]) : StringVec
    (if (<
      (stdlib.vector.string-vec-len v)
      (stdlib.vector.string-vec-capacity v))
      (let
        [slots : (Array String) (stdlib.vector.string-vec-slots v)]
        (begin
          (array-set! slots (stdlib.vector.string-vec-len v) value)
          (StringVec slots (+ (stdlib.vector.string-vec-len v) 1))))
      (stdlib.vector.string-vec-push (stdlib.vector.string-vec-grow v) value))))

;: Remove and return the last string together with the shrunk vector.
(comptime-decl
  (:generated vector-family string-vec-pop "String")
  (define (string-vec-pop [v : StringVec]) : StringVecPop
    (if (<= (stdlib.vector.string-vec-len v) 0)
      stdlib.vector.StringVecPopEmpty
      (let
        [last-index : i64 (- (stdlib.vector.string-vec-len v) 1)]
        (StringVecPopOk
          (array-ref (stdlib.vector.string-vec-slots v) last-index)
          (StringVec (stdlib.vector.string-vec-slots v) last-index))))))

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
        (stdlib.vector.string-vec-copy-range slots src 0 n)
        (StringVec slots n)))))

;: Return a fresh `(Array String)` snapshot of the live prefix.
(comptime-decl
  (:generated vector-family string-vec-to-array "String")
  (define (string-vec-to-array [v : StringVec]) : (Array String)
    (let
      [n : i64 (stdlib.vector.string-vec-len v)]
      [out : (Array String) (make-array String n)]
      (begin
        (stdlib.vector.string-vec-copy-range
          out
          (stdlib.vector.string-vec-slots v)
          0
          n)
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
      (stdlib.vector.string-vec-extend-from
        (stdlib.vector.string-vec-push v (array-ref src index))
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
    (stdlib.vector.string-vec-extend-from v src 0 count)))

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
          (stdlib.vector.string-vec-reverse-range! slots (+ lo 1) (- hi 1)))))))

;: Reverse the live prefix `[0, len)` in place; return the same vector.
(comptime-decl
  (:generated vector-family string-vec-reverse! "String")
  (define (string-vec-reverse! [v : StringVec]) : StringVec
    (begin
      (stdlib.vector.string-vec-reverse-range!
        (stdlib.vector.string-vec-slots v)
        0
        (- (stdlib.vector.string-vec-len v) 1))
      v)))

;: True when `x` is among the live strings at or after `index`.
(comptime-decl
  (:generated vector-family string-vec-contains-from? "String")
  (define (string-vec-contains-from? [v : StringVec] [x : String] [index : i64]) : bool
    (if (>= index (stdlib.vector.string-vec-len v))
      false
      (if (string-eq (array-ref (stdlib.vector.string-vec-slots v) index) x)
        true
        (stdlib.vector.string-vec-contains-from? v x (+ index 1))))))

;: True when `x` is among the live strings.
(comptime-decl
  (:generated vector-family string-vec-contains? "String")
  (define (string-vec-contains? [v : StringVec] [x : String]) : bool
    (stdlib.vector.string-vec-contains-from? v x 0)))

;# Dotted-module migration: preserve the pre-module flat stdlib surface.
(export
  (value i64-vec-slots)
  (value i64-vec-len)
  (value i64-vec-capacity)
  (value i64-vec-is-empty?)
  (value i64-vec-with-capacity)
  (value i64-vec-new)
  (value i64-vec-get)
  (value i64-vec-last)
  (value i64-vec-set!)
  (value i64-vec-copy-range)
  (value i64-vec-grow)
  (value i64-vec-push)
  (value i64-vec-pop)
  (value i64-vec-from-array)
  (value i64-vec-to-array)
  (value i64-vec-extend-from)
  (value i64-vec-extend)
  (value i64-vec-reverse-range!)
  (value i64-vec-reverse!)
  (value i64-vec-fold-from)
  (value i64-vec-fold)
  (value i64-vec-map-build-from)
  (value i64-vec-map-from)
  (value i64-vec-map)
  (value i64-vec-sum-from)
  (value i64-vec-sum)
  (value i64-vec-contains-from?)
  (value i64-vec-contains?)
  (value string-vec-slots)
  (value string-vec-len)
  (value string-vec-capacity)
  (value string-vec-is-empty?)
  (value string-vec-with-capacity)
  (value string-vec-new)
  (value string-vec-get)
  (value string-vec-last)
  (value string-vec-set!)
  (value string-vec-copy-range)
  (value string-vec-grow)
  (value string-vec-push)
  (value string-vec-pop)
  (value string-vec-from-array)
  (value string-vec-to-array)
  (value string-vec-extend-from)
  (value string-vec-extend)
  (value string-vec-reverse-range!)
  (value string-vec-reverse!)
  (value string-vec-contains-from?)
  (value string-vec-contains?)
  (type I64Vec)
  (type I64VecPop)
  (type StringVec)
  (type StringVecPop)
  (constructor I64Vec)
  (constructor StringVec)
  (field I64Vec slots)
  (field I64Vec len)
  (field StringVec slots)
  (field StringVec len)
  (variant I64VecPopEmpty)
  (variant I64VecPopOk)
  (variant StringVecPopEmpty)
  (variant StringVecPopOk))