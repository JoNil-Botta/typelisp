;; Known conservative rejection (#9503; #9464, #9256): storing a reference that
;; carries an arena region into an existing body-local reference is rejected,
;; as for `(in r T)` parameters, even when nothing reads it after the end.
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