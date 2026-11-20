;; A `break` leaving a with whose cleanup ends an arena is an end of it, as
;; the scope's normal exit is: `text`, allocated in it, is invalidated.
(import stdlib.arena)
(import stdlib.string)

(define (main) : i64
  (let
    [o (arena.make)]
    [text (in-arena o (string.concat "ab" "cd"))]
    (begin
      (while true
        (with ([a o arena.destroy-safe!]) (break)))
      (string.string-length text))))