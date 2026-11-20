;; #9775 X09: a fixed array allocated in a with-bound arena cannot be the
;; scope's result either: the exit ends the arena.
(import stdlib.arena)
(import stdlib.string)

(define (keep) : (Array String 2)
  (with
    ([a (arena.make) arena.destroy-safe!])
    (in-arena a (array (string.int->string 42) (string.int->string 42)))))

(define (main) : i64
  (let
    [value (keep)]
    (string.string-length (array-ref value 0))))