;; CB-1 runtime coverage: the CSR shape the content-bounds summary exists for.
;; `cb-edges` is a module-global Vec of a DIFFERENT length from the family
;; `cb-keys`/`cb-marks`, and every element ever written into it is a value that
;; passed a `cb-keys` bounds check one instruction earlier -- so the whole
;; program guarantees `content(cb-edges) subset [0, len(cb-keys) - 1]`, and
;; `cb-marks` is length-equal to `cb-keys`. The load-side check
;; `marks[edges[i]]` inside `cb-walk` is therefore the one CB-1 retires: the
;; zero fill is covered by the dominating `marks[0]` check, which proves
;; `len(cb-marks) >= 1`. The four cells are reset in one straight-line region,
;; which is what makes the lengths of one epoch comparable.
;;
;; The answer must be identical at every optimization level, and every index
;; must stay in range.
(import stdlib.io)
(import stdlib.string)
(import stdlib.vector)
(import (vector.vector i64) as i64vec)

(define (zero-vec [n : i64]) : i64vec.Vec
  (i64vec.Vec (__tl_make-array i64 n) n))

(define cb-keys : i64vec.Vec
  (zero-vec 1))
(define cb-marks : i64vec.Vec
  (zero-vec 1))
(define cb-edges : i64vec.Vec
  (zero-vec 1))
(define cb-src : i64vec.Vec
  (zero-vec 1))

;; Every store into `edges` writes a value the `keys` check just admitted.
(define (cb-fill
  [edges-vec : (&mut edges i64vec.Vec)]
  [keys-vec : (&mut keys i64vec.Vec)]
  [src-vec : (& src i64vec.Vec)]
  [total : i64]) : i64
  (let
    [edges (i64vec.slots-mut edges-vec)]
    [keys (i64vec.slots-mut keys-vec)]
    [src (i64vec.slots src-vec)]
    [i : i64 0]
    (begin
      (while (< i total)
        (let
          [v : i64 (array-ref src i)]
          (begin
            (set! (array-ref keys v) (+ (array-ref keys v) 1))
            (set! (array-ref edges i) v)
            (set! i (+ i 1)))))
      total)))

;; The load side: `edges[i]` is an index into a length-equal sibling.
(define (cb-walk
  [edges-vec : (& edges i64vec.Vec)]
  [marks-vec : (&mut marks i64vec.Vec)]
  [total : i64]) : i64
  (let
    [edges (i64vec.slots edges-vec)]
    [marks (i64vec.slots-mut marks-vec)]
    [i : i64 0]
    [acc : i64 0]
    (begin
      (set! (array-ref marks 0) 1)
      (while (< i total)
        (let
          [e : i64 (array-ref edges i)]
          (begin
            (set! (array-ref marks e) (+ (array-ref marks e) 1))
            (set! acc (+ acc (array-ref marks e)))
            (set! i (+ i 1)))))
      acc)))

(define (main) : i64
  (let
    [n : i64 (string.>int (io.arg 1))]
    [m : i64 (* n 2)]
    [i : i64 0]
    (begin
      (set! cb-keys (zero-vec n))
      (set! cb-marks (zero-vec n))
      (set! cb-edges (zero-vec m))
      (set! cb-src (zero-vec m))
      (while (< i m)
        (begin
          (set!
            (array-ref (i64vec.slots-mut (&mut cb-src)) i)
            (if (< i n)
              i
              (- i n)))
          (set! i (+ i 1))))
      (cb-fill (&mut cb-edges) (&mut cb-keys) (& cb-src) m)
      (io.print-format "{}\n" (cb-walk (& cb-edges) (&mut cb-marks) m))
      42)))