;; CB-2 runtime coverage: the scatter-fill shape the induction store class
;; exists for. `ind-scatter` is a module-global Vec of a DIFFERENT length from
;; the family `ind-keys`/`ind-marks`, and the only value ever written into it is
;; the LOOP COUNTER of `ind-fill` -- a multiply-assigned variable, which is
;; exactly what CB-1's one-definition rule refuses. The counter is nevertheless
;; in range for the family every time the store runs: it is seeded at 0, stepped
;; by 1, and the loop's own condition `i < count` is tested before the store on
;; every path into it, with `count` proved `<u len(ind-keys)` by the
;; `keys[count]` store one statement earlier. So the whole program guarantees
;; `content(ind-scatter) subset [0, len(ind-keys) - 1]`, and `ind-marks` is
;; length-equal to `ind-keys`. The load-side check `marks[scatter[j]]` inside
;; `ind-walk` is therefore the one CB-2 retires; the zero fill is covered by the
;; dominating `marks[0]` check, which proves `len(ind-marks) >= 1`. The four
;; cells are reset in one straight-line region, which is what makes the lengths
;; of one epoch comparable.
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
    (begin
      (set! (array-ref keys count) 0)
      (while (< i count)
        (begin
          (set! (array-ref scatter (array-ref slot i)) i)
          (set! i (+ i 1))))
      count)))

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
    (begin
      (set! (array-ref marks 0) 1)
      (while (< j total)
        (let
          [e : i64 (array-ref scatter j)]
          (begin
            (set! (array-ref marks e) (+ (array-ref marks e) 1))
            (set! acc (+ acc (array-ref marks e)))
            (set! j (+ j 1)))))
      acc)))

(define (main) : i64
  (let
    [n : i64 (string.>int (io.arg 1))]
    [m : i64 (* n 2)]
    [i : i64 0]
    (begin
      (set! ind-keys (zero-vec n))
      (set! ind-marks (zero-vec n))
      (set! ind-scatter (zero-vec m))
      (set! ind-slot (zero-vec m))
      (while (< i m)
        (begin
          (set! (array-ref (i64vec.slots-mut (&mut ind-slot)) i) i)
          (set! i (+ i 1))))
      (ind-fill (&mut ind-scatter) (&mut ind-keys) (& ind-slot) (- n 1))
      (io.print-format "{}\n" (ind-walk (& ind-scatter) (&mut ind-marks) m))
      42)))