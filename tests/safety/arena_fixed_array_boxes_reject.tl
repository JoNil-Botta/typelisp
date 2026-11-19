;; #8985: a fixed array of arena Boxes keeps their region.
(import stdlib.arena)

(define (keep) : (Array (Box i64) 2)
  (with-arena r (array (box 42) (box 42))))

(define (main) : i64
  (let
    [k (keep)]
    (deref (array-ref k 0))))