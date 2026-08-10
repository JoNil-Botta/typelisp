;; Two mutable Slice destinations cannot be derived from the same live owner
;; for one SPMD call, even when their runtime ranges appear disjoint.
(define (write-two-slices!
  [left : (&mut left (Slice i64))]
  [right : (&mut right (Slice i64))]
  [n : i64]) : unit
  (foreach
    ([i : i64 0 n])
    (begin
      (array-set! left i (+ i 1))
      (array-set! right i (+ i 5)))))

(define (main) : i64
  (let
    [items : (Array i64 4) (array 1 2 3 4)]
    (begin
      (write-two-slices!
        (slice-mut-view items 0 2)
        (slice-mut-view items 2 2)
        2)
      42)))