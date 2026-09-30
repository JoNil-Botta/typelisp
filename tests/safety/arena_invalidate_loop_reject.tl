(import stdlib.arena)
(import stdlib.string)

(define (release [owner : (arena.Arena r) (:invalidate r)] [count : i64]) : unit
  (let
    [i : i64 0]
    (while (< i count)
      (begin
        (arena.destroy-safe! owner)
        (set! i (+ i 1))))))

(define (main) : i64
  42)