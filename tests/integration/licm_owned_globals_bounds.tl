(import stdlib.io)
(import stdlib.string)
(import stdlib.vector)
(import (vector.vector i64) as vec)

(define (fresh [count : i64]) : vec.Vec
  (vec.Vec (__tl_make-array i64 count) count))

(define reads : vec.Vec
  (fresh 8))
(define writes : vec.Vec
  (fresh 8))
(define empty : vec.Vec
  (fresh 0))

(define (read-at [index : i64]) : i64
  (array-ref (vec.slots (& reads)) index))

(define (empty-at) : i64
  (array-ref (vec.slots (& empty)) 0))

(define (write-at [value : i64]) : unit
  (set! (array-ref (vec.slots-mut (&mut writes)) 0) value))

(define (main) : i64
  (let
    [index : i64 (string.>int (io.arg 1))]
    [count : i64 (string.>int (io.arg 2))]
    [i : i64 0]
    [sum : i64 0]
    (while (< i count)
      (write-at i)
      (when (= index 10) (+= sum (/ 1 (- i i))))
      (+=
        sum
        (if (= index 9)
          (empty-at)
          (read-at index)))
      (+= i 1))
    (+ 42 sum)))