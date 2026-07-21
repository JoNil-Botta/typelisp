;; vector_macro_struct.tl - runnable aggregate coverage for stdlib `(vector.vector T)`.
(import stdlib.test)
(import stdlib.vector)

(defstruct Pair
  (left i64)
  (right i64))

(defstruct Segment
  (start Pair)
  (finish Pair))

(import (vector.vector Pair) as pvec)
(import (vector.vector Segment) as svec)

(define (pair-score [p : Pair]) : i64
  (+ (* (struct-get p left) 10) (struct-get p right)))

(define (pair-swap [p : Pair]) : Pair
  (Pair (struct-get p right) (struct-get p left)))

(define (vector-macro-pair-fill [n : i64]) : pvec.Vec
  (let
    [v : pvec.Vec (pvec.new)]
    [i : i64 0]
    (begin
      (while (< i n)
        (begin
          (pvec.push (&mut v) (Pair i (+ i 1)))
          (set! i (+ i 1))))
      v)))

(test
  vector-macro-struct-growth
  (let
    [v : pvec.Vec (vector-macro-pair-fill 6)]
    (begin
      (test.assert-i64-eq (pvec.len (& v)) 6 "struct vector macro length")
      (test.assert-i64-eq
        (pvec.capacity (& v))
        8
        "struct vector macro doubled capacity")
      (test.assert-i64-eq
        (pair-score (pvec.get (& v) 5 (Pair 0 0)))
        56
        "struct vector macro keeps grown element")
      (pvec.set (&mut v) 1 (Pair 9 8))
      (test.assert-i64-eq
        (pair-score (pvec.get (& v) 1 (Pair 0 0)))
        98
        "struct vector macro set in place")
      (pvec.set (&mut v) 20 (Pair 7 7))
      (test.assert-i64-eq
        (pair-score (pvec.get (& v) 1 (Pair 0 0)))
        98
        "struct vector macro out-of-range set is no-op"))))

(test
  vector-macro-struct-derived-helpers
  (let
    [v : pvec.Vec (vector-macro-pair-fill 3)]
    (begin
      (pvec.reverse! (&mut v))
      (test.assert-i64-eq
        (pair-score (pvec.get (& v) 0 (Pair 0 0)))
        23
        "struct vector reverse mutates first slot")
      (let
        [mapped : pvec.Vec (pvec.map (& v) pair-swap)]
        [snapshot : (Array Pair) (pvec.to-array (& mapped))]
        (begin
          (test.assert-i64-eq
            (pair-score (array-ref snapshot 0))
            32
            "struct vector map snapshots aggregate")
          (match (pvec.pop (&mut v))
            [(pvec.Pop.Ok value)
              (begin
                (test.assert-i64-eq
                  (pair-score value)
                  1
                  "struct vector pop value")
                (test.assert-i64-eq
                  (pvec.len (& v))
                  2
                  "struct vector pop shrinks"))]
            [pvec.Pop.Empty
              (test.assert-true false "struct vector pop should return a value")]))))))

(test
  vector-macro-struct-contains
  (let
    [pairs : pvec.Vec (pvec.new)]
    [segments : svec.Vec (svec.new)]
    (begin
      (pvec.push (&mut pairs) (Pair 3 5))
      (pvec.push (&mut pairs) (Pair 8 13))
      (test.assert-true
        (pvec.contains? (& pairs) (Pair 8 13))
        "contains? finds a struct element")
      (test.assert-false
        (pvec.contains? (& pairs) (Pair 8 12))
        "contains? rejects a differing struct element")
      (svec.push (&mut segments) (Segment (Pair 1 2) (Pair 3 4)))
      (test.assert-true
        (svec.contains? (& segments) (Segment (Pair 1 2) (Pair 3 4)))
        "contains? finds a nested aggregate element")
      (test.assert-false
        (svec.contains? (& segments) (Segment (Pair 1 2) (Pair 3 5)))
        "contains? detects a nested aggregate mismatch"))))