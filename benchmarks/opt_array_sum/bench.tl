(import stdlib.array)
(import stdlib.io)
(import stdlib.string)
(import stdlib.vector)
(import (vector.vector i64) as i64vec)

(define (fill [xs : (&mut xs i64vec.Vec)] [n : i64]) : unit
  (let
    [slots (i64vec.slots-mut xs)]
    [i : i64 0]
    (while (< i n)
      (begin
        (set! (array-ref slots i) (% (+ (* i 13) 5) 97))
        (set! i (+ i 1))))))

(define (sum-array [xs : (& xs i64vec.Vec)] [n : i64]) : i64
  (let
    [slots (i64vec.slots xs)]
    [i : i64 0]
    [acc : i64 0]
    (begin
      (while (< i n)
        (begin
          (set! acc (+ acc (array-ref slots i)))
          (set! i (+ i 1))))
      acc)))

(define (main) : i64
  (let
    [n : i64 (string.>int (io.arg 1))]
    [xs : i64vec.Vec (i64vec.Vec (array.make-array i64 n) n)]
    (begin
      (fill (&mut xs) n)
      (io.print (sum-array (& xs) n))
      0)))