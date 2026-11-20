;; #8985: a fixed array of Boxes read out of an arena Box keeps the region.
(import stdlib.arena)

(define (keep) : (Array (Box i64) 2)
  (with-arena
    r
    (let
      [b : (Box (Array (Box i64) 2)) (box (array (box 42) (box 42)))]
      (deref b))))

(define (main) : i64
  (let
    [k (keep)]
    (deref (array-ref k 0))))