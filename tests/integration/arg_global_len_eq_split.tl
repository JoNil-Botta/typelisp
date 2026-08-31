;; The negative twin of arg_global_len_eq_pair: the same two module-global Vecs
;; and the same helper, but the second is reset ONE SHORTER. The two cells are
;; then not length-equal, so neither bounds check may be retired on the other
;; however confidently the call-site fact names the globals. The last index is
;; in range for the first array and out of range for the second, so the run
;; must take the ordinary array bounds abort inside the helper.
(import stdlib.io)
(import stdlib.string)
(import stdlib.vector)
(import (vector.vector i64) as i64vec)

(define (zero-vec [n : i64]) : i64vec.Vec
  (i64vec.Vec (__tl_make-array i64 n) n))

(define split-left : i64vec.Vec
  (zero-vec 1))
(define split-right : i64vec.Vec
  (zero-vec 1))

(define (pair-fold
  [left-vec : (& left i64vec.Vec)]
  [right-vec : (& right i64vec.Vec)]
  [count : i64]
  [scale : i64]) : i64
  (let
    [i : i64 0]
    [acc : i64 0]
    (begin
      (while (< i count)
        (begin
          (set! acc (+ acc (* scale (array-ref (i64vec.slots left-vec) i))))
          (set! acc (+ acc (array-ref (i64vec.slots right-vec) i)))
          (set! i (+ i 1))))
      acc)))

(define (main) : i64
  (let
    [n : i64 (string.>int (io.arg 1))]
    [i : i64 0]
    (begin
      (set! split-left (zero-vec n))
      (set! split-right (zero-vec (- n 1)))
      (while (< i (- n 1))
        (begin
          (set! (array-ref (i64vec.slots-mut (&mut split-left)) i) (+ i 1))
          (set! (array-ref (i64vec.slots-mut (&mut split-right)) i) (- n i))
          (set! i (+ i 1))))
      (io.print-format
        "{}\n"
        (+
          (pair-fold (& split-left) (& split-right) (- n 1) 5)
          (+
            (pair-fold (& split-left) (& split-right) (- n 2) 7)
            (pair-fold (& split-left) (& split-right) n 11))))
      42)))