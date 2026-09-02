;; CB-3 runtime coverage: the three shapes the widened recorder exists for, in
;; one program. All six cells are length-equal and reset in one straight-line
;; region, which is what makes their lengths comparable in one epoch.
;;
;; `chk-single` is the shape that refused `cfg-stack-node`: one store passes a
;; dominating `keys[v]` check, and the other writes the literal 0, which the
;; lowering hides behind a `mov` -- CB-1 read that store as an unchecked value
;; and refused the whole array. `chk-multi` writes a MULTIPLY ASSIGNED value the
;; same dominating check governs, which CB-1's one-definition rule refused and
;; no loop bound rescues. `chk-copy` writes a value LOADED out of `chk-single`
;; with no check on it anywhere, so only `chk-single`'s own content fact can
;; admit it -- a fact a strictly earlier round of the walk had to establish.
;;
;; With all three admitted, the load-side checks in `chk-walk` -- `marks[e]` for
;; `e` drawn from each array -- are the ones CB-3 retires, and the zero fill is
;; covered by the dominating `marks[0]` check, which proves `len >= 1`.
;;
;; The answer must be identical at every optimization level, and every index
;; must stay in range.
(import stdlib.io)
(import stdlib.string)
(import stdlib.vector)
(import (vector.vector i64) as i64vec)

(define (zero-vec [n : i64]) : i64vec.Vec
  (i64vec.Vec (__tl_make-array i64 n) n))

(define chk-keys : i64vec.Vec
  (zero-vec 1))
(define chk-marks : i64vec.Vec
  (zero-vec 1))
(define chk-src : i64vec.Vec
  (zero-vec 1))
(define chk-single : i64vec.Vec
  (zero-vec 1))
(define chk-many : i64vec.Vec
  (zero-vec 1))
(define chk-copy : i64vec.Vec
  (zero-vec 1))

;; Clause (a) and the single-definition CHECKED store. `(set! (array-ref single
;; 0) 0)` is the fill the lowering copies into a register first; `v` is a fresh
;; binding per iteration that the `keys[v]` store checks against the family.
(define (chk-fill
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
(define (chk-many-fill
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
;; because `chk-single` already carries a content fact for this family.
(define (chk-copy-fill
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
(define (chk-walk
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
    [i : i64 0]
    (begin
      (set! chk-keys (zero-vec n))
      (set! chk-marks (zero-vec n))
      (set! chk-src (zero-vec n))
      (set! chk-single (zero-vec n))
      (set! chk-many (zero-vec n))
      (set! chk-copy (zero-vec n))
      (while (< i n)
        (begin
          (set! (array-ref (i64vec.slots-mut (&mut chk-src)) i) (- (- n 1) i))
          (set! i (+ i 1))))
      (chk-fill (&mut chk-single) (&mut chk-keys) (& chk-src) n)
      (chk-many-fill (&mut chk-many) (&mut chk-keys) (& chk-src) n)
      (chk-copy-fill (&mut chk-copy) (& chk-single) n)
      (io.print-format
        "{}\n"
        (chk-walk (& chk-single) (& chk-many) (& chk-copy) (&mut chk-marks) n))
      42)))