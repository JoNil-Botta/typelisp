;; #9537 control: a reference into another, still-live arena passes.
(import stdlib.arena)

(define (exercise [owner : (arena.Arena r) (:invalidate r)] [x : (& a i64)]) : i64
  (begin
    (arena.destroy-safe! owner)
    (deref x)))

(define (main) : i64
  (let
    [seed : i64 42]
    [o (arena.make)]
    [p (arena.make)]
    [b (in-arena p (box seed))]
    [n : i64 (exercise o (& (deref b)))]
    (begin
      (arena.destroy-safe! p)
      n)))