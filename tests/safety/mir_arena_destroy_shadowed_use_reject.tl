;; A destroy invalidates every binder in scope carrying the arena's brand,
;; including one an inner binding of the same name shadows.
(import stdlib.arena)
(import stdlib.string)

(define (main) : i64
  (let
    [owner (arena.make)]
    [text (in-arena owner (string.append "owned" "-text"))]
    (begin
      (let
        [text : i64 5]
        (begin
          (arena.destroy-safe! owner)
          text))
      (string.string-length text))))