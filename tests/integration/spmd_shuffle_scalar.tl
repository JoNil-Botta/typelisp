; Scalar reference semantics for spmd-shuffle (#3545). The selector is varying
; but evaluates to lane 0 for every scalar gang.
; Compatibility exception for #3772: spmd-shuffle value expressions still use
; bare `array-ref` so the checker sees the compiler array-read AST.
(import stdlib.array)

(define (init [xs : (Array i64)] [n : i64]) : unit
  (let
    [i : i64 0]
    (while (< i n)
      (begin
        (array-set! xs i (+ (* i 3) 1))
        (set! i (+ i 1))))))

(define (sum [xs : (Array i64)] [n : i64]) : i64
  (let
    [i : i64 0]
    [acc : i64 0]
    (begin
      (while (< i n)
        (begin
          (set! acc (+ acc (array-ref xs i)))
          (set! i (+ i 1))))
      acc)))

(define (main) : i64
  (let
    [n : i64 5]
    [xs : (Array i64) (array.make-array i64 n)]
    [out : (Array i64) (array.make-array i64 n)]
    (begin
      (init xs n)
      (foreach
        ([i : i64 0 n])
        (array-set! out i (spmd-shuffle (array-ref xs i) (- i i))))
      (if (= (sum out n) 35)
        42
        1))))