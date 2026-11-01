;; Refs #9503: shortened `if` and `match` joins read before the end.
(import stdlib.arena)

(define (exercise
  [owner : (arena.Arena r) (:invalidate r)]
  [x : (& r i64)]
  [c : bool]) : i64
  (let
    [k : i64 1]
    [a : (& k i64) (if c x (& k))]
    [b : (& k i64)
      (match c
        [true x]
        [false (& k)])]
    [v : i64 (+ (deref a) (deref b))]
    (begin
      (arena.destroy-safe! owner)
      v)))

(define (main) : i64
  (let
    [seed : i64 21]
    [owner (arena.make)]
    [b (in-arena owner (box seed))]
    (exercise owner (& (deref b)) true)))
