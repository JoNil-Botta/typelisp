;; The recursive reader keeps a three-word result out of line. LGA drops its
;; unchanged global Vec argument and moves the hidden return-buffer position;
;; every recursion must still write into the correct caller-owned result.
(import stdlib.iterator)
(import stdlib.io)
(import stdlib.string)
(import stdlib.vector)
(import (vector.vector i64) as values)

(defstruct Reading
  (sum i64)
  (count i64)
  (tag i64))

(define data : values.Vec
  (values.Vec (__tl_make-array i64 0) 0))

(define (read-values [v : (& v values.Vec)] [n : i64]) : Reading
  (if (<= n 0)
    (Reading 0 0 22)
    (let
      [previous : Reading (read-values v (- n 1))]
      (Reading
        (+ previous.sum (array-ref (values.slots v) (- n 1)))
        (+ previous.count 1)
        previous.tag))))

(define (main) : i64
  (let
    [n : i64 (string.>int (io.arg 1))]
    (set! data (values.Vec (__tl_make-array i64 n) n))
    (for [i (iterator.range 0 n)]
      (set! (array-ref (values.slots-mut (&mut data)) i) (+ i 1)))
    (let
      [result : Reading (read-values (& data) n)]
      (+ result.sum result.count result.tag))))