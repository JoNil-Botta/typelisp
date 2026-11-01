;; Known conservative rejection (#9503; flow-sensitive kill: #9464, #9256): a
;; shortened binding keeps its brand after it is re-pointed at body-local
;; storage, so a read after the end is rejected.
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
