;; #8985: a fixed array holding an arena Box local keeps its region.
(import stdlib.arena)

(define (keep) : (Array (Box i64) 1)
  (with-arena
    r
    (let
      [b (box (ann 1 : i64))]
      (array b))))

(define (main) : i64
  (+ 40 (deref (array-ref (keep) 0))))