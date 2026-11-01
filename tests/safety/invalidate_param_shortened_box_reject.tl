;; Refs #9503: a Box holding a reference keeps the stored brand through a
;; shortening annotation.
(import stdlib.arena)

(define (exercise
  [owner : (arena.Arena r) (:invalidate r)]
  [x : (Box (& r i64))]) : i64
  (let
    [k : i64 0]
    [b : (Box (& k i64)) x]
    (arena.destroy-safe! owner)
    (deref (deref b))))

(define (main) : i64
  0)