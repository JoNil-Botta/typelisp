(import stdlib.arena)
(import stdlib.string)

(define (release [owner : (arena.Arena r) (:invalidate r)] [now : bool]) : i64
  (if now
    (begin
      (arena.destroy-safe! owner)
      40)
    (begin
      (arena.destroy-safe! owner)
      2)))

(define (main) : i64
  (let
    [first (arena.make)]
    [second (arena.make)]
    [a : i64 (release first true)]
    [b : i64 (release second false)]
    (+ a b)))