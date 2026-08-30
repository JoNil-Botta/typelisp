;; IAG-2 runtime coverage, the cfg-natural-loops shape: a loop whose body reads
;; two module-global Vecs through their inline `.comm` cells and, on a rare
;; arm, calls a helper that mutates a THIRD global's element storage. The
;; helper writes neither the read globals' cells (no `set!`) nor their own
;; storage (its only `(&mut ...)` parameter names the marks vector), so the
;; descriptor handles the loop reads out of those cells are loop-invariant and
;; the header hoist may take them to the preheader. Every element and length
;; load stays inside the loop, so the sum must be identical at every opt level
;; and identical to the base compiler's.
(import stdlib.io)
(import stdlib.string)
(import stdlib.vector)
(import (vector.vector i64) as i64vec)

(define (zero-vec [n : i64]) : i64vec.Vec
  (i64vec.Vec (__tl_make-array i64 n) n))

(define hh-data : i64vec.Vec
  (zero-vec 1))
(define hh-keys : i64vec.Vec
  (zero-vec 1))
(define hh-marks : i64vec.Vec
  (zero-vec 1))

;; The rare arm's callee. Its writes all land in the element storage of the
;; vector its `(&mut ...)` parameter names; it reads the other two.
(define (hh-mark
  [data-vec : (& data i64vec.Vec)]
  [keys-vec : (& keys i64vec.Vec)]
  [marks-vec : (&mut marks i64vec.Vec)]
  [index : i64]) : i64
  (let
    [data : (& data (__tl_dyn-array i64)) (i64vec.slots data-vec)]
    [keys : (& keys (__tl_dyn-array i64)) (i64vec.slots keys-vec)]
    [marks : (&mut marks (__tl_dyn-array i64)) (i64vec.slots-mut marks-vec)]
    [total : i64 0]
    [step : i64 0]
    (begin
      (while (< step 3)
        (begin
          (set!
            (array-ref marks index)
            (+ (array-ref marks index) (array-ref keys index)))
          (set! total (+ total (array-ref data index)))
          (set! step (+ step 1))))
      total)))

(define (hh-scan [n : i64]) : i64
  (let
    [acc : i64 0]
    [i : i64 0]
    (begin
      (while (< i n)
        (begin
          (set! acc (+ acc (array-ref (i64vec.slots (& hh-data)) i)))
          (set! acc (+ acc (array-ref (i64vec.slots (& hh-keys)) i)))
          (when
            (= 0 (% (array-ref (i64vec.slots (& hh-keys)) i) 5))
            (set!
              acc
              (+ acc (hh-mark (& hh-data) (& hh-keys) (&mut hh-marks) i))))
          (set! i (+ i 1))))
      acc)))

(define (main) : i64
  (let
    [n : i64 (string.>int (io.arg 1))]
    [i : i64 0]
    [total : i64 0]
    (begin
      (set! hh-data (zero-vec n))
      (set! hh-keys (zero-vec n))
      (set! hh-marks (zero-vec n))
      (while (< i n)
        (begin
          (set! (array-ref (i64vec.slots-mut (&mut hh-data)) i) (+ i 1))
          (set! (array-ref (i64vec.slots-mut (&mut hh-keys)) i) (* i 3))
          (set! i (+ i 1))))
      (set! total (+ (hh-scan n) (hh-scan (- n 1))))
      (set! i 0)
      (while (< i n)
        (begin
          (set! total (+ total (array-ref (i64vec.slots (& hh-marks)) i)))
          (set! i (+ i 1))))
      (io.print-format "{}\n" total)
      42)))