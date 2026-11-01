;; Refs #9536: the moved mutable reference still ends with its region.
(import stdlib.arena)

(define (exercise
  [owner : (arena.Arena r) (:invalidate r)]
  [x : (in r (&mut r i64))]) : i64
  (let
    [alias : (&mut r i64) x]
    (arena.destroy-safe! owner)
    (deref alias)))

(define (main) : i64
  0)