;; Refs #9503: a shortened `match` join keeps the brand any arm stores.
(import stdlib.arena)

(define (exercise
  [owner : (arena.Arena r) (:invalidate r)]
  [x : (& r i64)]
  [c : bool]) : i64
  (let
    [k : i64 5]
    [alias : (& k i64)
      (match c
        [true (& k)]
        [false x])]
    (begin
      (arena.destroy-safe! owner)
      (deref alias))))

(define (main) : i64
  0)