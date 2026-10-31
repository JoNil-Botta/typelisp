;; Refs #9503: reading the shortened binding before the destroy is accepted.
(import stdlib.arena)

(define (exercise [owner : (arena.Arena r) (:invalidate r)] [x : (& r i64)]) : i64
  (let
    [k : i64 5]
    (let
      [alias : (& k i64) x]
      [read : i64 (deref alias)]
      (begin
        (arena.destroy-safe! owner)
        read))))

(define (main) : i64
  (let
    [seed : i64 42]
    [owner (arena.make)]
    [b (in-arena owner (box seed))]
    (exercise owner (& (deref b)))))