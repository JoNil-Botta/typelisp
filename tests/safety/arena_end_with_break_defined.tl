;; A `break` out of a with whose cleanup ends an arena is valid when nothing
;; outside holds its values.
(import stdlib.arena)
(import stdlib.string)

(define (main) : i64
  (let
    [n : i64 0]
    (begin
      (while true
        (with
          ([a (arena.make) arena.destroy-safe!])
          (begin
            (set!
              n
              (+ 40 (string.string-length (in-arena a (string.concat "a" "b")))))
            (break))))
      n)))