;; Refs #9508: a callable parameter's result keeps the stored brand of its
;; argument through a shortening annotation (C58 p1).
(import stdlib.arena)

(define (exercise
  [owner : (arena.Arena r) (:invalidate r)]
  [x : (& r i64)]
  [f : (-> (& a i64) (& a i64))]) : i64
  (let
    [k : i64 5]
    [alias : (& k i64) (f x)]
    (begin
      (arena.destroy-safe! owner)
      (deref alias))))

(define (main) : i64
  0)