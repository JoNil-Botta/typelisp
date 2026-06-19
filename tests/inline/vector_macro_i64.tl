;; vector_macro_i64.tl - runnable scalar coverage for stdlib `(vector T)`.
(import "stdlib/test.tl")
(import "stdlib/vector.tl")

(vector i64)

(define (vector-macro-i64-fill [n : i64]) : Vec
  (let
    [v : Vec (new)]
    [i : i64 0]
    (begin
      (while (< i n)
        (begin
          (set! v (push v (* i 3)))
          (set! i (+ i 1))))
      v)))

(test
  vector-macro-i64-growth
  (let
    [v : Vec (vector-macro-i64-fill 9)]
    (begin
      (assert-i64-eq (len v) 9 "i64 vector macro length")
      (assert-i64-eq (capacity v) 16 "i64 vector macro doubled capacity")
      (assert-i64-eq (get v 0 -1) 0 "i64 vector macro keeps first element")
      (assert-i64-eq (get v 7 -1) 21 "i64 vector macro keeps grown element")
      (assert-i64-eq (get v 9 -1) -1 "i64 vector macro get at len fallback")
      (assert-i64-eq (get v -1 -1) -1 "i64 vector macro negative fallback")
      (let
        [updated : Vec (set v 2 99)]
        (begin
          (assert-i64-eq (get updated 2 -1) 99 "i64 vector macro set")
          (assert-i64-eq (len updated) 9 "i64 vector macro set keeps len"))))))