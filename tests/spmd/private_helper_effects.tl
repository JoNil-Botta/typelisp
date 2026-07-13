;; Incoming masks guard stores and atomics in an out-of-line helper.
(import stdlib.array)
(import stdlib.atomic)

(define (heavy-effects [out : (Array i64)] [i : i64]) : unit
  (begin
    (array-set! out i (+ (+ (+ (+ (+ (+ (+ i 1) 2) 3) 4) 5) 6) 7))
    (atomic.atomic-i64-add! out 15 1)))

(define (fill [out : (Array i64)] [n : i64]) : unit
  (foreach
    ([i : i64 0 n])
    (if (< i 5)
      (heavy-effects out i)
      unit)))

(define (sum-array [xs : (Array i64)] [n : i64]) : i64
  (let
    [i : i64 0]
    [sum : i64 0]
    (begin
      (while (< i n)
        (begin
          (set! sum (+ sum (array-ref xs i)))
          (set! i (+ i 1))))
      sum)))

(define (main) : i64
  (let
    [out : (Array i64) (array.make-array i64 16)]
    (begin
      (fill out 13)
      (if (= (sum-array out 16) 155)
        42
        1))))