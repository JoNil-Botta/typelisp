;; Refs #9503: a mutable reference shortened to a body-local lifetime ends with
;; the brand.
(import stdlib.arena)

(define (exercise [owner : (arena.Arena r) (:invalidate r)] [x : (&mut r i64)]) : i64
  (let
    [k : i64 0]
    [alias : (&mut k i64) x]
    (arena.destroy-safe! owner)
    (deref alias)))

(define (main) : i64
  0)
