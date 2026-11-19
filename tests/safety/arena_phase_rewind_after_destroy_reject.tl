;; #9788: destroying an owner ends its phase tokens.
(import stdlib.arena)

(define (main) : i64
  (let
    [s (arena.make)]
    [p (arena.phase s)]
    (begin
      (arena.destroy-safe! s)
      (arena.rewind-safe! p)
      42)))