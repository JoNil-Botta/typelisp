; Scalar-reference, AVX2, and AVX-512 lowering for `spmd-scan` (#2905, #5349,
; #5350). Each scan
; writes inclusive prefixes and is checked across empty, sub-lane, exact-lane,
; multiple-gang, and tail-sized ranges.
; Compatibility exception for #3772: spmd-scan value expressions and direct
; scan body writes still use bare array helpers so the checker sees compiler
; array ASTs.
(import stdlib.vector)
(import (vector.vector i64) as i64v)
(import (vector.vector i32) as i32v)
(import (vector.vector bool) as boolv)
(import "spmd_vec_support.tl" module spmd.vec.support as spmdv)
(import (spmdv.zeroed i64 0) as i64z)
(import (spmdv.zeroed i32 (cast 0 : i32)) as i32z)
(import (spmdv.zeroed bool false) as boolz)

(define (fill-i64 [xs : (&mut xs i64v.Vec)] [n : i64]) : unit
  (let
    [xs-slots (i64v.slots-mut xs)]
    (foreach ([i : i64 0 n]) (array-set! xs-slots i (+ i 1)))))

(define (fill-i64-mixed [xs : (&mut xs i64v.Vec)] [n : i64]) : unit
  (let
    [xs-slots (i64v.slots-mut xs)]
    [i : i64 0]
    (while (< i n)
      (begin
        (array-set!
          xs-slots
          i
          (match (% i 5)
            [0 6]
            [1 (- 0 2)]
            [2 7]
            [3 1]
            [_ (- 0 8)]))
        (set! i (+ i 1))))))

(define (fill-i32-mixed [xs : (&mut xs i32v.Vec)] [n : i64]) : unit
  (let
    [xs-slots (i32v.slots-mut xs)]
    [i : i64 0]
    (while (< i n)
      (begin
        (array-set!
          xs-slots
          i
          (cast
            (match (% i 5)
              [0 (- 0 3)]
              [1 4]
              [2 1]
              [3 9]
              [_ (- 0 2)])
            : i32))
        (set! i (+ i 1))))))

(define (fill-bools
  [all-in : (&mut all-in boolv.Vec)]
  [any-in : (&mut any-in boolv.Vec)]
  [n : i64]) : unit
  (let
    [all-slots (boolv.slots-mut all-in)]
    [any-slots (boolv.slots-mut any-in)]
    [i : i64 0]
    (while (< i n)
      (begin
        (array-set! all-slots i (!= (% i 11) 7))
        (array-set! any-slots i (= (% i 13) 9))
        (set! i (+ i 1))))))

(define (scan-sum-i64
  [xs : (& xs i64v.Vec)]
  [out : (&mut out i64v.Vec)]
  [n : i64]) : unit
  (let
    [xs-slots (i64v.slots xs)]
    [out-slots (i64v.slots-mut out)]
    (spmd-scan
      sum
      ([i : i64 0 n] [prefix : i64 0])
      (array-ref xs-slots i)
      (array-set! out-slots i prefix))))

(define (scan-min-i64
  [xs : (& xs i64v.Vec)]
  [out : (&mut out i64v.Vec)]
  [n : i64]) : unit
  (let
    [xs-slots (i64v.slots xs)]
    [out-slots (i64v.slots-mut out)]
    (spmd-scan
      min
      ([i : i64 0 n] [prefix : i64 20])
      (array-ref xs-slots i)
      (array-set! out-slots i prefix))))

(define (scan-max-i64
  [xs : (& xs i64v.Vec)]
  [out : (&mut out i64v.Vec)]
  [n : i64]) : unit
  (let
    [xs-slots (i64v.slots xs)]
    [out-slots (i64v.slots-mut out)]
    (spmd-scan
      max
      ([i : i64 0 n] [prefix : i64 (- 0 20)])
      (array-ref xs-slots i)
      (array-set! out-slots i prefix))))

(define (scan-sum-i32
  [xs : (& xs i32v.Vec)]
  [out : (&mut out i32v.Vec)]
  [n : i64]) : unit
  (let
    [xs-slots (i32v.slots xs)]
    [out-slots (i32v.slots-mut out)]
    (spmd-scan
      sum
      ([i : i64 0 n] [prefix : i32 (cast 0 : i32)])
      (array-ref xs-slots i)
      (array-set! out-slots i prefix))))

(define (scan-min-i32
  [xs : (& xs i32v.Vec)]
  [out : (&mut out i32v.Vec)]
  [n : i64]) : unit
  (let
    [xs-slots (i32v.slots xs)]
    [out-slots (i32v.slots-mut out)]
    (spmd-scan
      min
      ([i : i64 0 n] [prefix : i32 (cast 10 : i32)])
      (array-ref xs-slots i)
      (array-set! out-slots i prefix))))

(define (scan-max-i32
  [xs : (& xs i32v.Vec)]
  [out : (&mut out i32v.Vec)]
  [n : i64]) : unit
  (let
    [xs-slots (i32v.slots xs)]
    [out-slots (i32v.slots-mut out)]
    (spmd-scan
      max
      ([i : i64 0 n] [prefix : i32 (cast (- 0 10) : i32)])
      (array-ref xs-slots i)
      (array-set! out-slots i prefix))))

(define (scan-all-bool
  [xs : (& xs boolv.Vec)]
  [out : (&mut out boolv.Vec)]
  [n : i64]) : unit
  (let
    [xs-slots (boolv.slots xs)]
    [out-slots (boolv.slots-mut out)]
    (spmd-scan
      all
      ([i : i64 0 n] [prefix : bool true])
      (array-ref xs-slots i)
      (array-set! out-slots i prefix))))

(define (scan-any-bool
  [xs : (& xs boolv.Vec)]
  [out : (&mut out boolv.Vec)]
  [n : i64]) : unit
  (let
    [xs-slots (boolv.slots xs)]
    [out-slots (boolv.slots-mut out)]
    (spmd-scan
      any
      ([i : i64 0 n] [prefix : bool false])
      (array-ref xs-slots i)
      (array-set! out-slots i prefix))))

(define (take-bound [bounds : (&mut bounds i64v.Vec)]) : i64
  (let
    [bounds-slots (i64v.slots-mut bounds)]
    [n : i64 (array-ref bounds-slots 0)]
    (begin
      (array-set! bounds-slots 0 0)
      n)))

(define (case-sum-i64 [n : i64]) : bool
  (let
    [xs : i64v.Vec (i64z.make 9)]
    [out : i64v.Vec (i64z.make 9)]
    (begin
      (fill-i64 (&mut xs) 9)
      (scan-sum-i64 (& xs) (&mut out) n)
      (cond
        [(and (> n 0) (!= (i64v.get (& out) 0 0) 1)) false]
        [(and (> n 3) (!= (i64v.get (& out) 3 0) 10)) false]
        [(and (> n 4) (!= (i64v.get (& out) 4 0) 15)) false]
        [(and (> n 8) (!= (i64v.get (& out) 8 0) 45)) false]
        [else true]))))

(define (case-min-max-i64 [n : i64]) : bool
  (let
    [xs : i64v.Vec (i64z.make 9)]
    [out-min : i64v.Vec (i64z.make 9)]
    [out-max : i64v.Vec (i64z.make 9)]
    [min-acc : i64 20]
    [max-acc : i64 (- 0 20)]
    [i : i64 0]
    [ok : bool true]
    (begin
      (fill-i64-mixed (&mut xs) 9)
      (scan-min-i64 (& xs) (&mut out-min) n)
      (scan-max-i64 (& xs) (&mut out-max) n)
      (while (< i n)
        (let
          [value : i64 (i64v.get (& xs) i 0)]
          (begin
            (if (< value min-acc)
              (set! min-acc value)
              unit)
            (if (> value max-acc)
              (set! max-acc value)
              unit)
            (if (!= (i64v.get (& out-min) i 0) min-acc)
              (set! ok false)
              unit)
            (if (!= (i64v.get (& out-max) i 0) max-acc)
              (set! ok false)
              unit)
            (set! i (+ i 1)))))
      ok)))

(define (case-i32-ops [n : i64]) : bool
  (let
    [xs : i32v.Vec (i32z.make 17)]
    [out-sum : i32v.Vec (i32z.make 17)]
    [out-min : i32v.Vec (i32z.make 17)]
    [out-max : i32v.Vec (i32z.make 17)]
    [sum-acc : i32 (cast 0 : i32)]
    [min-acc : i32 (cast 10 : i32)]
    [max-acc : i32 (cast (- 0 10) : i32)]
    [i : i64 0]
    [ok : bool true]
    (begin
      (fill-i32-mixed (&mut xs) 17)
      (scan-sum-i32 (& xs) (&mut out-sum) n)
      (scan-min-i32 (& xs) (&mut out-min) n)
      (scan-max-i32 (& xs) (&mut out-max) n)
      (while (< i n)
        (let
          [value : i32 (i32v.get (& xs) i (cast 0 : i32))]
          (begin
            (set! sum-acc (+ sum-acc value))
            (if (< value min-acc)
              (set! min-acc value)
              unit)
            (if (> value max-acc)
              (set! max-acc value)
              unit)
            (if (!= (i32v.get (& out-sum) i (cast 0 : i32)) sum-acc)
              (set! ok false)
              unit)
            (if (!= (i32v.get (& out-min) i (cast 0 : i32)) min-acc)
              (set! ok false)
              unit)
            (if (!= (i32v.get (& out-max) i (cast 0 : i32)) max-acc)
              (set! ok false)
              unit)
            (set! i (+ i 1)))))
      ok)))

(define (case-wrapping-sums) : bool
  (let
    [i64-in : i64v.Vec (i64z.make 4)]
    [i64-out : i64v.Vec (i64z.make 4)]
    [i32-in : i32v.Vec (i32z.make 8)]
    [i32-out : i32v.Vec (i32z.make 8)]
    [i64-acc : i64 9223372036854775806]
    [i32-acc : i32 (cast 2147483646 : i32)]
    [i : i64 0]
    [ok : bool true]
    (begin
      (while (< i 8)
        (begin
          (if (< i 4)
            (i64v.set (&mut i64-in) i 1)
            unit)
          (i32v.set (&mut i32-in) i (cast 1 : i32))
          (set! i (+ i 1))))
      (let
        [src (i64v.slots (& i64-in))]
        [dst (i64v.slots-mut (&mut i64-out))]
        (spmd-scan
          sum
          ([lane : i64 0 4] [prefix : i64 9223372036854775806])
          (array-ref src lane)
          (array-set! dst lane prefix)))
      (let
        [src (i32v.slots (& i32-in))]
        [dst (i32v.slots-mut (&mut i32-out))]
        (spmd-scan
          sum
          ([lane : i64 0 8] [prefix : i32 (cast 2147483646 : i32)])
          (array-ref src lane)
          (array-set! dst lane prefix)))
      (set! i 0)
      (while (< i 8)
        (begin
          (if (< i 4)
            (begin
              (set! i64-acc (+ i64-acc (i64v.get (& i64-in) i 0)))
              (if (!= (i64v.get (& i64-out) i 0) i64-acc)
                (set! ok false)
                unit))
            unit)
          (set! i32-acc (+ i32-acc (i32v.get (& i32-in) i (cast 0 : i32))))
          (if (!= (i32v.get (& i32-out) i (cast 0 : i32)) i32-acc)
            (set! ok false)
            unit)
          (set! i (+ i 1))))
      ok)))

(define (case-bool-scans [n : i64]) : bool
  (let
    [all-in : boolv.Vec (boolz.make 65)]
    [all-out : boolv.Vec (boolz.make 65)]
    [any-in : boolv.Vec (boolz.make 65)]
    [any-out : boolv.Vec (boolz.make 65)]
    [all-acc : bool true]
    [any-acc : bool false]
    [i : i64 0]
    [ok : bool true]
    (begin
      (fill-bools (&mut all-in) (&mut any-in) 65)
      (scan-all-bool (& all-in) (&mut all-out) n)
      (scan-any-bool (& any-in) (&mut any-out) n)
      (while (< i n)
        (begin
          (set! all-acc (and all-acc (boolv.get (& all-in) i false)))
          (set! any-acc (or any-acc (boolv.get (& any-in) i false)))
          (if (!= (boolv.get (& all-out) i false) all-acc)
            (set! ok false)
            unit)
          (if (!= (boolv.get (& any-out) i false) any-acc)
            (set! ok false)
            unit)
          (set! i (+ i 1))))
      ok)))

(define (case-empty-range) : bool
  (let
    [xs : i64v.Vec (i64z.make 1)]
    [out : i64v.Vec (i64z.make 1)]
    (begin
      (i64v.set (&mut out) 0 7)
      (let
        [src (i64v.slots (& xs))]
        [dst (i64v.slots-mut (&mut out))]
        (spmd-scan
          sum
          ([i : i64 0 0] [prefix : i64 99])
          (array-ref src 99)
          (array-set! dst 99 prefix)))
      (= (i64v.get (& out) 0 0) 7))))

(define (case-extreme-empty-ranges) : bool
  (let
    [xs : i64v.Vec (i64z.make 1)]
    [out : i64v.Vec (i64z.make 1)]
    (begin
      (i64v.set (&mut out) 0 17)
      (let
        [src (i64v.slots (& xs))]
        [dst (i64v.slots-mut (&mut out))]
        (begin
          (spmd-scan
            sum
            ([i : i64 (- 0 1) (- 0 1)] [prefix : i64 3])
            (array-ref src i)
            (array-set! dst i prefix))
          (spmd-scan
            sum
            ([i : i64 9223372036854775807 9223372036854775807] [prefix : i64 5])
            (array-ref src i)
            (array-set! dst i prefix))))
      (= (i64v.get (& out) 0 0) 17))))

(define (case-end-bound-evaluated-once) : bool
  (let
    [bounds : i64v.Vec (i64z.make 1)]
    [xs : i64v.Vec (i64z.make 3)]
    [out : i64v.Vec (i64z.make 3)]
    (begin
      (i64v.set (&mut bounds) 0 3)
      (fill-i64 (&mut xs) 3)
      (let
        [src (i64v.slots (& xs))]
        [dst (i64v.slots-mut (&mut out))]
        (spmd-scan
          sum
          ([i : i64 0 (take-bound (&mut bounds))] [prefix : i64 0])
          (array-ref src i)
          (array-set! dst i prefix)))
      (and (= (i64v.get (& bounds) 0 0) 0) (= (i64v.get (& out) 2 0) 6)))))

(define (case-nonzero-seeded-range) : bool
  (let
    [start-box : i64v.Vec (i64z.make 1)]
    [end-box : i64v.Vec (i64z.make 1)]
    [init-box : i64v.Vec (i64z.make 1)]
    [xs : i64v.Vec (i64z.make 12)]
    [out : i64v.Vec (i64z.make 12)]
    (begin
      (i64v.set (&mut start-box) 0 2)
      (i64v.set (&mut end-box) 0 11)
      (i64v.set (&mut init-box) 0 5)
      (i64v.set (&mut out) 1 99)
      (fill-i64 (&mut xs) 12)
      (let
        [src (i64v.slots (& xs))]
        [dst (i64v.slots-mut (&mut out))]
        (spmd-scan
          sum
          ([i : i64 (take-bound (&mut start-box)) (take-bound (&mut end-box))]
            [prefix : i64 (take-bound (&mut init-box))])
          (array-ref src i)
          (array-set! dst i prefix)))
      (and
        (= (i64v.get (& start-box) 0 0) 0)
        (= (i64v.get (& end-box) 0 0) 0)
        (= (i64v.get (& init-box) 0 0) 0)
        (= (i64v.get (& out) 1 0) 99)
        (= (i64v.get (& out) 2 0) 8)
        (= (i64v.get (& out) 5 0) 23)
        (= (i64v.get (& out) 9 0) 57)
        (= (i64v.get (& out) 10 0) 68)))))

(define (case-prefix-binding-is-scoped) : bool
  (=
    (let
      [prefix : i64 7]
      (begin
        (spmd-scan sum ([i : i64 0 3] [prefix : i64 0]) i unit)
        prefix))
    7))

(define (case-prefix-mutation-does-not-feed-acc) : bool
  (let
    [xs : i64v.Vec (i64z.make 3)]
    [out : i64v.Vec (i64z.make 3)]
    (begin
      (fill-i64 (&mut xs) 3)
      (let
        [src (i64v.slots (& xs))]
        [dst (i64v.slots-mut (&mut out))]
        (spmd-scan
          sum
          ([i : i64 0 3] [prefix : i64 0])
          (array-ref src i)
          (begin
            (array-set! dst i prefix)
            (set! prefix 0))))
      (and
        (= (i64v.get (& out) 0 0) 1)
        (= (i64v.get (& out) 1 0) 3)
        (= (i64v.get (& out) 2 0) 6)))))

(define (main) : i64
  (cond
    [(not (case-sum-i64 0)) 1]
    [(not (case-sum-i64 3)) 2]
    [(not (case-sum-i64 4)) 3]
    [(not (case-sum-i64 9)) 4]
    [(not (case-min-max-i64 3)) 5]
    [(not (case-min-max-i64 4)) 6]
    [(not (case-min-max-i64 9)) 7]
    [(not (case-i32-ops 5)) 8]
    [(not (case-i32-ops 8)) 9]
    [(not (case-i32-ops 17)) 10]
    [(not (case-wrapping-sums)) 11]
    [(not (case-bool-scans 4)) 12]
    [(not (case-bool-scans 32)) 13]
    [(not (case-bool-scans 65)) 14]
    [(not (case-empty-range)) 15]
    [(not (case-extreme-empty-ranges)) 16]
    [(not (case-end-bound-evaluated-once)) 17]
    [(not (case-nonzero-seeded-range)) 18]
    [(not (case-prefix-binding-is-scoped)) 19]
    [(not (case-prefix-mutation-does-not-feed-acc)) 20]
    [else 42]))