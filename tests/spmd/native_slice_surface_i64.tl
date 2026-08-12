;; SPMD vector/native Slice surface: public APIs take generated vectors and
;; native borrowed slices while varying lane indexes operate through the views.
;; The cases span empty, sub-gang, AVX2/AVX-512 full-gang, multi-gang, and tail
;; lengths, including offset views backed by both generated Vecs and fixed
;; arrays.
(import stdlib.vector)
(import (vector.vector i64) as i64v)

(define (init-vec [v : (&mut v i64v.Vec)] [n : i64] [scale : i64] [bias : i64]) : unit
  (let
    [i : i64 0]
    (while (< i n)
      (begin
        (i64v.push v (+ (* i scale) bias))
        (set! i (+ i 1))))))

(define (fill-vector-foreach
  [a : (& a i64v.Vec)]
  [b : (& b i64v.Vec)]
  [out : (&mut out i64v.Vec)]
  [n : i64]) : unit
  (let
    [a-slots (i64v.slots a)]
    [b-slots (i64v.slots b)]
    [out-slots (i64v.slots-mut out)]
    (foreach
      ([i : i64 0 n])
      (set!
        (array-ref out-slots i)
        (+ (array-ref a-slots i) (array-ref b-slots i))))))

(define (fill-slice-foreach
  [a : (& a (Slice i64))]
  [b : (& b (Slice i64))]
  [out : (&mut out (Slice i64))]
  [n : i64]) : unit
  (foreach
    ([i : i64 0 n])
    (set! (array-ref out i) (+ (array-ref a i) (array-ref b i)))))

(define (reduce-slice-sum [values : (& values (Slice i64))] [n : i64]) : i64
  (spmd-reduce sum ([i : i64 0 n]) 0 (array-ref values i)))

(define (scan-slice-case
  [values : (& values (Slice i64))]
  [out : (&mut out (Slice i64))]
  [n : i64]) : bool
  (let
    [i : i64 0]
    [expected : i64 0]
    [ok : bool true]
    (begin
      (spmd-scan
        sum
        ([j : i64 0 n] [prefix : i64 0])
        (array-ref values j)
        (set! (array-ref out j) prefix))
      (while (and ok (< i n))
        (begin
          (set! expected (+ expected (array-ref values i)))
          (if (= (array-ref out i) expected)
            unit
            (set! ok false))
          (set! i (+ i 1))))
      ok)))

(define (slice-case
  [a : (& a (Slice i64))]
  [b : (& b (Slice i64))]
  [out : (&mut out (Slice i64))]
  [n : i64]) : bool
  (let
    [i : i64 0]
    [ok : bool true]
    (begin
      (fill-slice-foreach a b out n)
      (while (and ok (< i n))
        (begin
          (if (= (array-ref out i) (+ (array-ref a i) (array-ref b i)))
            unit
            (set! ok false))
          (set! i (+ i 1))))
      ok)))

(define (vector-slice-case
  [a : (& a i64v.Vec)]
  [b : (& b i64v.Vec)]
  [out : (&mut out i64v.Vec)]
  [a-start : i64]
  [b-start : i64]
  [out-start : i64]
  [n : i64]) : bool
  (let
    [a-view : (& a (Slice i64)) (slice-view (i64v.view a) a-start n)]
    [b-view : (& b (Slice i64)) (slice-view (i64v.view b) b-start n)]
    [out-view : (&mut out (Slice i64))
      (slice-mut-view (i64v.view-mut out) out-start n)]
    (slice-case a-view b-view out-view n)))

(define (vector-prefix-ok?
  [a : (& a i64v.Vec)]
  [b : (& b i64v.Vec)]
  [out : (& out i64v.Vec)]
  [n : i64]) : bool
  (let
    [i : i64 0]
    [ok : bool true]
    (begin
      (while (and ok (< i n))
        (begin
          (if (= (i64v.get out i 0) (+ (i64v.get a i 0) (i64v.get b i 0)))
            unit
            (set! ok false))
          (set! i (+ i 1))))
      ok)))

(define (fill-split-halves!
  [left : (&mut left (Slice i64))]
  [right : (&mut right (Slice i64))]
  [n : i64]) : unit
  (foreach
    ([i : i64 0 n])
    (begin
      (set! (array-ref left i) (+ i 1))
      (set! (array-ref right i) (+ i 20)))))

(define (split-spmd-case) : bool
  (let
    [items : (Array i64 14) (array 0 0 0 0 0 0 0 0 0 0 0 0 0 0)]
    [score : i64
      (let
        [view : (&mut items (Slice i64)) (slice-mut-view items 0 14)]
        [halves : (Tuple (&mut items (Slice i64)) (&mut items (Slice i64)))
          (slice-split-at-mut view 7)]
        [left : (&mut items (Slice i64)) (tuple-ref halves 0)]
        [right : (&mut items (Slice i64)) (tuple-ref halves 1)]
        (begin
          (fill-split-halves! left right 7)
          (+ (array-ref left 6) (array-ref right 6))))]
    (and
      (= score 33)
      (and
        (= (array-ref items 0) 1)
        (and (= (array-ref items 7) 20) (= (array-ref items 13) 26))))))

(define (fixed-slice-case) : bool
  (let
    [a : (Array i64 20)
      (array 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20)]
    [b : (Array i64 20)
      (array
        101
        102
        103
        104
        105
        106
        107
        108
        109
        110
        111
        112
        113
        114
        115
        116
        117
        118
        119
        120)]
    [out : (Array i64 20)
      (array -9 -9 -9 -9 -9 -9 -9 -9 -9 -9 -9 -9 -9 -9 -9 -9 -9 -9 -9 -9)]
    [a-view : (& a (Slice i64)) (slice-view a 1 13)]
    [b-view : (& b (Slice i64)) (slice-view b 3 13)]
    [case-ok : bool
      (let
        [out-view : (&mut out (Slice i64)) (slice-mut-view out 2 13)]
        (slice-case a-view b-view out-view 13))]
    [scan-ok : bool
      (let
        [out-view : (&mut out (Slice i64)) (slice-mut-view out 2 13)]
        (scan-slice-case a-view out-view 13))]
    (and
      case-ok
      scan-ok
      (= (array-ref out 0) -9)
      (= (array-ref out 1) -9)
      (= (array-ref out 15) -9)
      (= (array-ref out 19) -9))))

(define (main) : i64
  (let
    [capacity : i64 40]
    [a : i64v.Vec (i64v.with-capacity capacity)]
    [b : i64v.Vec (i64v.with-capacity capacity)]
    [out : i64v.Vec (i64v.with-capacity capacity)]
    [ok : bool true]
    (begin
      (init-vec (&mut a) capacity 2 1)
      (init-vec (&mut b) capacity 3 2)
      (init-vec (&mut out) capacity 0 -777)
      ;; Generated vector backing remains a first-class borrowed SPMD surface.
      (fill-vector-foreach (& a) (& b) (&mut out) 17)
      (if (vector-prefix-ok? (& a) (& b) (& out) 17)
        unit
        (set! ok false))
      ;; Zero-length end views, sub-gangs, exact gangs for both SIMD widths,
      ;; and multiple-gang tails all use the same native Slice kernel.
      (if (vector-slice-case (& a) (& b) (&mut out) 40 40 40 0)
        unit
        (set! ok false))
      (if (vector-slice-case (& a) (& b) (&mut out) 2 4 6 1)
        unit
        (set! ok false))
      (if (vector-slice-case (& a) (& b) (&mut out) 3 5 7 3)
        unit
        (set! ok false))
      (if (vector-slice-case (& a) (& b) (&mut out) 4 6 8 4)
        unit
        (set! ok false))
      (if (vector-slice-case (& a) (& b) (&mut out) 1 2 5 8)
        unit
        (set! ok false))
      (if (vector-slice-case (& a) (& b) (&mut out) 2 3 5 9)
        unit
        (set! ok false))
      (if (vector-slice-case (& a) (& b) (&mut out) 1 2 5 17)
        unit
        (set! ok false))
      (if (= (reduce-slice-sum (slice-view (i64v.view (& a)) 3 9) 9) 135)
        unit
        (set! ok false))
      (if (and
        ok
        (= (i64v.get (& out) 0 0) 3)
        (= (i64v.get (& out) 39 0) -777)
        (fixed-slice-case)
        (split-spmd-case))
        42
        1))))