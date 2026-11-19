;; A loop exit out of a with whose cleanup ends an arena would end it
;; unchecked: `break` cannot leave the scope.
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