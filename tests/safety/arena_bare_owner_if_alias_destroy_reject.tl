;; An owner selected by an `if` and bound elsewhere moves the owner (#8172).
(import stdlib.arena)
(import stdlib.string)

(define (main) : i64
  (let
    [owner : arena.Arena (arena.make)]
    [alias : arena.Arena
      (if (> (string.string-length "x") 0)
        owner
        owner)]
    (begin
      (arena.destroy-safe! owner)
      (string.string-length (in-arena alias (string.concat "a" "b"))))))