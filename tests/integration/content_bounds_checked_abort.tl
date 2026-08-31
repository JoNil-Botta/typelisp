;; The negative twin of content_bounds_checked: the SAME three shapes fed a
;; corpus whose source values run one past the family's length. With `bump` = 1
;; the largest value `ab-src` holds is `n`, which is out of range for `ab-keys`,
;; and the `keys[v]` store -- the very check CB-3 READS to admit the store into
;; `ab-single` -- is the one that fires, on the first iteration, before anything
;; is written.
;;
;; CB-3 changes nothing about that run: it retires no store-side check. Clause
;; (a) admits only the value 0, clause (b) reads a check that is still emitted,
;; and clause (c) reads a fact whose own store-side checks are still emitted. So
;; the abort site, the message and the exit status must be byte-identical to the
;; base compiler's at every optimization level. The load-side checks CB-3 does
;; retire could not have been the ones to fire: the program stops at the
;; store-side check before a single element is written.
(import stdlib.io)
(import stdlib.string)
(import stdlib.vector)
(import (vector.vector i64) as i64vec)

(define (zero-vec [n : i64]) : i64vec.Vec
  (i64vec.Vec (__tl_make-array i64 n) n))

(define ab-keys : i64vec.Vec
  (zero-vec 1))
(define ab-marks : i64vec.Vec
  (zero-vec 1))
(define ab-src : i64vec.Vec
  (zero-vec 1))
(define ab-single : i64vec.Vec
  (zero-vec 1))
(define ab-many : i64vec.Vec
  (zero-vec 1))
(define ab-copy : i64vec.Vec
  (zero-vec 1))

;; Clause (a) and the single-definition CHECKED store. `(set! (array-ref single
;; 0) 0)` is the fill the lowering copies into a register first; `v` is a fresh
;; binding per iteration that the `keys[v]` store checks against the family.
(define (ab-fill
  [single-vec : (&mut single i64vec.Vec)]
  [keys-vec : (&mut keys i64vec.Vec)]
  [src-vec : (& src i64vec.Vec)]
  [count : i64]) : i64
  (let
    [single (i64vec.slots-mut single-vec)]
    [keys (i64vec.slots-mut keys-vec)]
    [src (i64vec.slots src-vec)]
    [i : i64 0]
    (begin
      (set! (array-ref single 0) 0)
      (while (< i count)
        (let
          [v : i64 (array-ref src i)]
          (begin
            (set! (array-ref keys v) 0)
            (set! (array-ref single i) v)
            (set! i (+ i 1)))))
      count)))

;; Clause (b). `slot` is assigned once outside the loop and once inside it, so
;; it has more than one definition and CB-1 refuses it; the `keys[slot]` check
;; earlier in the same straight-line run governs the store, and nothing
;; reassigns `slot` between the two.
(define (ab-many-fill
  [many-vec : (&mut many i64vec.Vec)]
  [keys-vec : (&mut keys i64vec.Vec)]
  [src-vec : (& src i64vec.Vec)]
  [count : i64]) : i64
  (let
    [many (i64vec.slots-mut many-vec)]
    [keys (i64vec.slots-mut keys-vec)]
    [src (i64vec.slots src-vec)]
    [slot : i64 0]
    [i : i64 0]
    (begin
      (while (< i count)
        (begin
          (set! slot (array-ref src i))
          (set! (array-ref keys slot) 0)
          (set! (array-ref many i) slot)
          (set! i (+ i 1))))
      count)))

;; Clause (c). Nothing checks the stored value here: it is admitted only
;; because `ab-single` already carries a content fact for this family.
(define (ab-copy-fill
  [copy-vec : (&mut copy i64vec.Vec)]
  [single-vec : (& single i64vec.Vec)]
  [count : i64]) : i64
  (let
    [copy (i64vec.slots-mut copy-vec)]
    [single (i64vec.slots single-vec)]
    [j : i64 0]
    (begin
      (while (< j count)
        (begin
          (set! (array-ref copy j) (array-ref single j))
          (set! j (+ j 1))))
      count)))

;; The load side: three element loads used as indices into a length-equal
;; sibling, which are the checks the three facts retire.
(define (ab-walk
  [single-vec : (& single i64vec.Vec)]
  [many-vec : (& many i64vec.Vec)]
  [copy-vec : (& copy i64vec.Vec)]
  [marks-vec : (&mut marks i64vec.Vec)]
  [total : i64]) : i64
  (let
    [single (i64vec.slots single-vec)]
    [many (i64vec.slots many-vec)]
    [copy (i64vec.slots copy-vec)]
    [marks (i64vec.slots-mut marks-vec)]
    [j : i64 0]
    [acc : i64 0]
    (begin
      (set! (array-ref marks 0) 1)
      (while (< j total)
        (begin
          (set! (array-ref marks (array-ref single j)) 2)
          (set! (array-ref marks (array-ref many j)) 3)
          (set! (array-ref marks (array-ref copy j)) 4)
          (set! acc (+ acc (array-ref marks (array-ref copy j))))
          (set! j (+ j 1))))
      acc)))

(define (main) : i64
  (let
    [n : i64 (string.>int (io.arg 1))]
    [bump : i64 (string.>int (io.arg 2))]
    [i : i64 0]
    (begin
      (set! ab-keys (zero-vec n))
      (set! ab-marks (zero-vec n))
      (set! ab-src (zero-vec n))
      (set! ab-single (zero-vec n))
      (set! ab-many (zero-vec n))
      (set! ab-copy (zero-vec n))
      (while (< i n)
        (begin
          (set!
            (array-ref (i64vec.slots-mut (&mut ab-src)) i)
            (+ (- (- n 1) i) bump))
          (set! i (+ i 1))))
      (ab-fill (&mut ab-single) (&mut ab-keys) (& ab-src) n)
      (ab-many-fill (&mut ab-many) (&mut ab-keys) (& ab-src) n)
      (ab-copy-fill (&mut ab-copy) (& ab-single) n)
      (io.print-format
        "{}\n"
        (ab-walk (& ab-single) (& ab-many) (& ab-copy) (&mut ab-marks) n))
      42)))