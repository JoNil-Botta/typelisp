;; The negative twin of global_header_hoist_loop: the loop's callee pushes to
;; the SAME global Vec it reads, so the `(&mut ...)` argument is that global and
;; the push rewrites the cell's own `slots` and `len` words in place when the
;; buffer grows. The descriptor handle the loop reads is therefore NOT
;; loop-invariant, the header hoist must refuse it, and every read after the
;; call must observe the new buffer, the new length and the element the callee
;; wrote through it. The printed total pins all three.
(import stdlib.io)
(import stdlib.string)
(import stdlib.vector)
(import (vector.vector i64) as i64vec)

(define hh-grow : i64vec.Vec
  (i64vec.with-capacity 1))

;; Grows the vector it is handed -- reallocating its element storage and
;; rewriting the cell's `slots`/`len` words -- and then writes through the NEW
;; buffer.
(define (hh-push [v : (&mut v i64vec.Vec)] [value : i64]) : i64
  (begin
    (i64vec.push-ref! v value)
    (set! (array-ref (i64vec.slots-mut v) 0) value)
    (i64vec.len-mut v)))

(define (hh-walk [n : i64]) : i64
  (let
    [acc : i64 0]
    [i : i64 0]
    (begin
      (while (< i n)
        (begin
          ;; read through the cell BEFORE the call
          (set! acc (+ acc (array-ref (i64vec.slots (& hh-grow)) 0)))
          (set! acc (+ acc (i64vec.len (& hh-grow))))
          ;; the call replaces the buffer and rewrites the cell
          (set! acc (+ acc (hh-push (&mut hh-grow) (+ i 1))))
          ;; and again AFTER it, which must see the new words
          (set! acc (+ acc (array-ref (i64vec.slots (& hh-grow)) 0)))
          (set!
            acc
            (+
              acc
              (array-ref
                (i64vec.slots (& hh-grow))
                (- (i64vec.len (& hh-grow)) 1))))
          (set! i (+ i 1))))
      acc)))

(define (main) : i64
  (let
    [n : i64 (string.>int (io.arg 1))]
    (begin
      (i64vec.push-ref! (&mut hh-grow) 7)
      (io.print-format "{}\n" (hh-walk n))
      42)))