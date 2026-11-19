;; A loop inside a with whose cleanup ends an arena keeps its own exits.
(import stdlib.arena)

(define (main) : i64
  (let
    [n : i64 0]
    [i : i64 0]
    (begin
      (while (< i 3)
        (begin
          (with
            ([a (arena.make) arena.destroy-safe!])
            (while true
              (begin
                (set! n (+ n 14))
                (break))))
          (set! i (+ i 1))))
      n)))