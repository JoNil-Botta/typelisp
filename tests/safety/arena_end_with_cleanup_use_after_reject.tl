;; #9490: a with cleanup `arena.destroy-safe!` ends its arena at the scope
;; exit through the end operator: `text`, allocated in it, is invalidated.
(import stdlib.arena)
(import stdlib.string)

(define (main) : i64
  (let
    [o (arena.make)]
    [text (in-arena o (string.concat "ab" "cd"))]
    (begin
      (with ([a o arena.destroy-safe!]) unit)
      (string.string-length text))))