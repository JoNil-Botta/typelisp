;; #9508 (q13): a `box` element keeps its own type, so it cannot take a
;; longer annotated lifetime than the boxed reference's.
(import stdlib.arena)

(define (exercise [owner : (arena.Arena r) (:invalidate r)] [x : (& r i64)]) : i64
  (let
    [k : i64 5]
    [b : (Box (& k i64)) (box x)]
    (begin
      (arena.destroy-safe! owner)
      (deref (deref b)))))

(define (main) : i64
  0)