;; Runtime coverage for a scatter fill. `ind-scatter` is a module-global Vec of
;; a DIFFERENT length from the family `ind-keys`/`ind-marks`, and the only value
;; ever written into it is the LOOP COUNTER of `ind-fill`, a multiply-assigned
;; variable that is in range for the family every time the store runs: it is
;; seeded at 0, stepped by 1, and the loop's condition `i < count` is tested
;; before the store, with `count` checked by the `keys[count]` store one
;; statement earlier. The load-side check `marks[scatter[j]]` inside `ind-walk`
;; therefore always passes. The four cells are reset in one straight-line
;; region.
;;
;; The answer must be identical at every optimization level, and every index
;; must stay in range.
(import stdlib.io)
(import stdlib.string)
(import stdlib.vector)
(import (vector.vector i64) as i64vec)

(define (zero-vec [n : i64]) : i64vec.Vec
  (i64vec.Vec (__tl_make-array i64 n) n))

(define ind-keys : i64vec.Vec
  (zero-vec 1))
(define ind-marks : i64vec.Vec
  (zero-vec 1))
(define ind-scatter : i64vec.Vec
  (zero-vec 1))
(define ind-slot : i64vec.Vec
  (zero-vec 1))

;; The scatter fill. `keys[count]` is the check that ties the loop's bound to
;; the family's length; every element store then writes the counter itself.
(define (ind-fill
  [scatter-vec : (&mut scatter i64vec.Vec)]
  [keys-vec : (&mut keys i64vec.Vec)]
  [slot-vec : (& slot i64vec.Vec)]
  [count : i64]) : i64
  (let
    [scatter (i64vec.slots-mut scatter-vec)]
    [keys (i64vec.slots-mut keys-vec)]
    [slot (i64vec.slots slot-vec)]
    [i : i64 0]
    (set! (array-ref keys count) 0)
    (while (< i count)
      (set! (array-ref scatter (array-ref slot i)) i)
      (set! i (+ i 1)))
    count))

;; The load side: `scatter[j]` is an index into a length-equal sibling.
(define (ind-walk
  [scatter-vec : (& scatter i64vec.Vec)]
  [marks-vec : (&mut marks i64vec.Vec)]
  [total : i64]) : i64
  (let
    [scatter (i64vec.slots scatter-vec)]
    [marks (i64vec.slots-mut marks-vec)]
    [j : i64 0]
    [acc : i64 0]
    (set! (array-ref marks 0) 1)
    (while (< j total)
      (let
        [e : i64 (array-ref scatter j)]
        (set! (array-ref marks e) (+ (array-ref marks e) 1))
        (set! acc (+ acc (array-ref marks e)))
        (set! j (+ j 1))))
    acc))

(define (main) : i64
  (let
    [n : i64 (string.>int (io.arg 1))]
    [m : i64 (* n 2)]
    [i : i64 0]
    (set! ind-keys (zero-vec n))
    (set! ind-marks (zero-vec n))
    (set! ind-scatter (zero-vec m))
    (set! ind-slot (zero-vec m))
    (while (< i m)
      (set! (array-ref (i64vec.slots-mut (&mut ind-slot)) i) i)
      (set! i (+ i 1)))
    (ind-fill (&mut ind-scatter) (&mut ind-keys) (& ind-slot) (- n 1))
    (io.print-format "{}\n" (ind-walk (& ind-scatter) (&mut ind-marks) m))
    42))