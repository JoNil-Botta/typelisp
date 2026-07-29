;; Incoming masks guard stores and atomics in an out-of-line helper.
(import stdlib.array)
(import stdlib.atomic)

(define (heavy-effects
  [out : (Array i64)]
  [atomic-out : (& atomic-out atomic.AtomicI64Buffer)]
  [i : i64]) : unit
  (begin
    (array-set! out i (+ (+ (+ (+ (+ (+ (+ i 1) 2) 3) 4) 5) 6) 7))
    (atomic.atomic-i64-add! atomic-out 0 1)))

(define (fill
  [out : (Array i64)]
  [atomic-out : (& atomic-out atomic.AtomicI64Buffer)]
  [n : i64]) : unit
  (foreach
    ([i : i64 0 n])
    (if (< i 5)
      (heavy-effects out atomic-out i)
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
    [atomic-out : atomic.AtomicI64Buffer (atomic.i64-buffer 1)]
    (begin
      (fill out (& atomic-out) 13)
      (if (=
        (+ (sum-array out 16) (atomic.atomic-i64-load (& atomic-out) 0))
        155)
        42
        1))))