; Scalar reference semantics for spmd-shuffle (#3545). The selector is varying
; but evaluates to lane 0 for every scalar gang.
; Compatibility exception for #3772: spmd-shuffle value expressions still use
; bare `array-ref` so the checker sees the compiler array-read AST.
(import stdlib.vector)
(import (vector.vector i64) as i64v)
(import spmd_vec_support as spmdv)
(import (spmdv.zeroed i64 0) as i64z)

(define (init [xs : (&mut xs i64v.Vec)] [n : i64]) : unit
  (let
    [xs-slots (i64v.slots-mut xs)]
    [i : i64 0]
    (while (< i n)
      (begin
        (array-set! xs-slots i (+ (* i 3) 1))
        (set! i (+ i 1))))))

(define (sum [xs : (& xs i64v.Vec)] [n : i64]) : i64
  (let
    [xs-slots (i64v.slots xs)]
    [i : i64 0]
    [acc : i64 0]
    (begin
      (while (< i n)
        (begin
          (set! acc (+ acc (array-ref xs-slots i)))
          (set! i (+ i 1))))
      acc)))

(define (main) : i64
  (let
    [n : i64 5]
    [xs : i64v.Vec (i64z.make n)]
    [out : i64v.Vec (i64z.make n)]
    (begin
      (init (&mut xs) n)
      (let
        [xs-slots (i64v.slots (& xs))]
        [out-slots (i64v.slots-mut (&mut out))]
        (foreach
          ([i : i64 0 n])
          (array-set! out-slots i (spmd-shuffle (array-ref xs-slots i) (- i i)))))
      (if (= (sum (& out) n) 35)
        42
        1))))