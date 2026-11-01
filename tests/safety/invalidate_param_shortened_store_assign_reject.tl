;; Known conservative rejection (#9503; flow-sensitive kill: #9464, #9256): a
;; value that keeps a stored brand cannot be assigned into an existing
;; body-local reference, even with no use after the end.
(import stdlib.arena)

(define (exercise [owner : (arena.Arena r) (:invalidate r)] [x : (& r i64)]) : i64
  (let
    [k : i64 5]
    (let
      [alias : (& k i64) (& k)]
      (begin
        (set! alias x)
        (arena.destroy-safe! owner)
        0))))

(define (main) : i64
  0)
