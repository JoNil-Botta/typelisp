;; A `continue` out of such a with is valid too.
(import stdlib.arena)

(define (main) : i64
  (let
    [n : i64 0]
    [i : i64 0]
    (begin
      (while (< i 6)
        (begin
          (set! i (+ i 1))
          (with
            ([a (arena.make) arena.destroy-safe!])
            (begin
              (set! n (+ n 7))
              (continue)))))
      n)))