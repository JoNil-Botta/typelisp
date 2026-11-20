;; #9490: the safe arena ends are not first-class values; bound to a local,
;; `arena.destroy-safe!` would end the arena with no end checks.
(import stdlib.arena)
(import stdlib.string)

(define (main) : i64
  (let
    [scratch (arena.make)]
    [text (in-arena scratch (string.concat "ab" "cd"))]
    [f arena.destroy-safe!]
    (begin
      (f scratch)
      (string.string-length text))))