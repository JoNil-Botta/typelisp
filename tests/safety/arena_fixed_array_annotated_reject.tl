;; #8985: an annotated binding of an arena fixed array keeps the region.
(import stdlib.arena)

(define (keep) : (Array (Box i64) 2)
  (with-arena
    r
    (let
      [a : (Array (Box i64) 2) (array (box 42) (box 42))]
      a)))

(define (main) : i64
  (let
    [k (keep)]
    (deref (array-ref k 0))))