;; Refs #9503: the shortened binding ends with the brand even when the
;; function also takes an unrelated reference parameter.
(import stdlib.arena)

(define (exercise
  [owner : (arena.Arena r) (:invalidate r)]
  [x : (& r i64)]
  [y : (& q i64)]) : i64
  (let
    [k : i64 5]
    (let
      [alias : (& k i64) x]
      (begin
        (arena.destroy-safe! owner)
        (+ (deref alias) (deref y))))))

(define (main) : i64
  0)