;; vector_macro_struct.tl - runnable aggregate coverage for stdlib `(vector T)`.
(import "stdlib/test.tl")
(import "stdlib/vector.tl")

(defstruct Pair
  (left i64)
  (right i64))

(define (pair-score [p : Pair]) : i64
  (+ (* (struct-get p left) 10) (struct-get p right)))

(vector Pair)

(define (vector-macro-pair-fill [n : i64]) : Vec
  (let
    [v : Vec (new)]
    [i : i64 0]
    (begin
      (while (< i n)
        (begin
          (set! v (push v (Pair i (+ i 1))))
          (set! i (+ i 1))))
      v)))

(test
  vector-macro-struct-growth
  (let
    [v : Vec (vector-macro-pair-fill 6)]
    (begin
      (assert-i64-eq (len v) 6 "struct vector macro length")
      (assert-i64-eq (capacity v) 8 "struct vector macro doubled capacity")
      (assert-i64-eq
        (pair-score (get v 5 (Pair 0 0)))
        56
        "struct vector macro keeps grown element")
      (let
        [updated : Vec (set v 1 (Pair 9 8))]
        (begin
          (assert-i64-eq
            (pair-score (get updated 1 (Pair 0 0)))
            98
            "struct vector macro set")
          (let
            [unchanged : Vec (set updated 20 (Pair 7 7))]
            (assert-i64-eq
              (pair-score (get unchanged 1 (Pair 0 0)))
              98
              "struct vector macro out-of-range set is no-op")))))))