;; Refs #9503: a tuple shortened as a whole keeps the brand it stores.
(import stdlib.arena)

(define (exercise
  [owner : (arena.Arena r) (:invalidate r)]
  [x : (Tuple (& r i64) i64)]) : i64
  (let
    [k : i64 5]
    (let
      [t : (Tuple (& k i64) i64) x]
      (begin
        (arena.destroy-safe! owner)
        (deref (tuple-ref t 0))))))

(define (main) : i64
  0)
