;; Refs #9508: a deref of a reference to a reference keeps the stored brand
;; through a shortening annotation.
(import stdlib.arena)

(define (exercise
  [owner : (arena.Arena r) (:invalidate r)]
  [x : (& r (& r i64))]) : i64
  (let
    [k : i64 5]
    (let
      [alias : (& k i64) (deref x)]
      (begin
        (arena.destroy-safe! owner)
        (deref alias)))))

(define (main) : i64
  0)