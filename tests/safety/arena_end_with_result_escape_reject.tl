;; #9775: a value allocated in a with-bound arena cannot be the with's result,
;; which would outlive the arena its cleanup destroys.
(import stdlib.string)
(import stdlib.arena)

(define (keep) : String
  (with
    ([a (arena.make) arena.destroy-safe!])
    (in-arena a (string.int->string 42))))

(define (main) : i64
  (let
    [k (keep)]
    (+ 40 (string.string-length (& k)))))