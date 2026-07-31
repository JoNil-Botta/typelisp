;; Private varying helper with enough leading uniform arguments to use the
;; platform stack ABI. The helper is deliberately too large to inline.
(import stdlib.array)

(define (heavy-uniform-stack
  [a : i64]
  [b : i64]
  [c : i64]
  [d : i64]
  [e : i64]
  [f : i64]
  [g : i64]
  [x : i64]) : i64
  (+ (+ (+ (+ (+ (+ (+ x a) b) c) d) e) f) g))

(define (fill [out : (Array i64)] [n : i64]) : unit
  (foreach
    ([i : i64 0 n])
    (array-set! out i (heavy-uniform-stack 1 2 3 4 5 6 7 i))))

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
    [n : i64 13]
    [out : (Array i64) (array.make-array i64 n)]
    (begin
      (fill out n)
      (if (= (sum-array out n) 442)
        42
        1))))