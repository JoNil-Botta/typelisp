;; #9775: the with result is rejected where it is bound, not only returned.
(import stdlib.string)
(import stdlib.arena)

(define (main) : i64
  (let
    [s
      (with
        ([a (arena.make) arena.destroy-safe!])
        (in-arena a (string.int->string 42)))]
    (+ 40 (string.string-length (& s)))))