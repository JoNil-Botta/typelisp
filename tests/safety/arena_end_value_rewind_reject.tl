;; #9490: the rewind alias is rejected like the destroy alias.
(import stdlib.arena)
(import stdlib.string)

(define (main) : i64
  (let
    [scratch : arena.Arena (arena.make)]
    [phase : arena.ArenaPhase (arena.phase scratch)]
    [text (in-arena scratch (string.concat "ab" "cd"))]
    [f arena.rewind-safe!]
    (begin
      (f phase)
      (string.string-length text))))