(import stdlib.io)
(import stdlib.vector)
(import (vector.vector i64) as vec)

(extern (alias-globals) : unit (:symbol "alias_globals"))

(define (fresh [count : i64]) : vec.Vec
  (vec.Vec (__tl_make-array i64 count) count))

(define reads : vec.Vec
  (fresh 8))
(define writes : vec.Vec
  (fresh 8))

(define (read-at [index : i64]) : i64
  (array-ref (vec.slots (& reads)) index))

(define (write-at [index : i64] [value : i64]) : unit
  (set! (array-ref (vec.slots-mut (&mut writes)) index) value))

(define (work [count : i64] [index : i64]) : i64
  (let
    [sum : i64 (read-at index)]
    [i : i64 0]
    (while (< i count)
      (write-at index (+ i 10))
      (+= sum (read-at index))
      (+= i 1))
    sum))

(define (run) : i64
  (set! (array-ref (vec.slots-mut (&mut reads)) 0) 1)
  (alias-globals)
  (let
    [sum : i64 (work 4 (- (io.arg-count) 1))]
    (io.println "sum={sum}")
    (if (= sum 47)
      42
      1)))