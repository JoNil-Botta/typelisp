;; SPMD inline helper arguments must not be captured by helper-local bindings.
(import stdlib.array)

(define (bump-with-shadow [x : i64]) : i64
  (let
    [lane : i64 1]
    (+ x lane)))

(define (fill-inline-shadow [xs : (Array i64)] [out : (Array i64)] [n : i64]) : unit
  (foreach
    ([i : i64 0 n])
    (let
      [lane : i64 (array.array-ref xs i)]
      (array.array-set! out i (bump-with-shadow lane)))))

(define (sum-array [xs : (Array i64)] [n : i64]) : i64
  (let
    [i : i64 0]
    [sum : i64 0]
    (begin
      (while (< i n)
        (begin
          (set! sum (+ sum (array.array-ref xs i)))
          (set! i (+ i 1))))
      sum)))

(define (main) : i64
  (let
    [n : i64 13]
    [xs : (Array i64) (array.make-array i64 n)]
    [out : (Array i64) (array.make-array i64 n)]
    [i : i64 0]
    (begin
      (while (< i n)
        (begin
          (array.array-set! xs i (+ i 1))
          (set! i (+ i 1))))
      (fill-inline-shadow xs out n)
      (if (= (sum-array out n) 104)
        42
        1))))