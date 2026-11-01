;; Known conservative rejection (#9503; #9464, #9256): a binding initialized
;; from a reference that carries an arena region keeps that provenance, as for
;; `(in r T)` parameters, so re-pointing it at a body-local reference is
;; rejected even before the end.
(import stdlib.arena)

(define (exercise [owner : (arena.Arena r) (:invalidate r)] [x : (& r i64)]) : i64
  (let
    [k : i64 5]
    (let
      [alias : (& k i64) x]
      (begin
        (set! alias (& k))
        (arena.destroy-safe! owner)
        (deref alias)))))

(define (main) : i64
  0)