;; Refs #9502 Refs #9493. An owner alias keeps the active root brand beneath a mark.
(import stdlib.arena)

(define (main) : i64
  (let
    [owner (arena.make)]
    (in-arena
      owner
      (with-arena
        mark
        (let
          [alias owner]
          (arena.destroy-safe! alias)
          42)))))