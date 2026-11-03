;; A colliding `with-arena` inside an SPMD `foreach` is typed only by the
;; legacy and SPMD checkers and is lowered with the same fresh region, so
;; annotations spelled like the arena still name it there (#9593).
(define (sum [p : (& r i64)]) : i64
  (foreach
    ([i : i64 0 1])
    (with-arena
      r
      (let
        [n : i64 30]
        [x : (in r (Box i64)) (box n)]
        [y : (& r i64) (& r (deref x))]
        unit)))
  (deref p))

(define (main) : i64
  (let
    [seed : i64 42]
    (sum (& seed))))