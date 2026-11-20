;; #9479: the read of a branded owner's phase value after its rewind.
(import stdlib.arena)
(import stdlib.string)

(define (main) : i64
  (let
    [owner (arena.make)]
    [phase (arena.phase owner)]
    [text (in-arena owner (string.copy "Ada"))]
    (arena.rewind-safe! phase)
    (string.string-length (& text))))