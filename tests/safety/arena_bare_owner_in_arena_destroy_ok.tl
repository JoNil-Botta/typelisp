;; A bare-annotated owner used directly by `in-arena`, then destroyed, stays
;; accepted (#8172).
(import stdlib.arena)
(import stdlib.string)

(define (main) : i64
  (let
    [owner : arena.Arena (arena.make)]
    [length : i64
      (string.string-length (in-arena owner (string.concat "forty" "-two")))]
    (begin
      (arena.destroy-safe! owner)
      (+ length 33))))