;; Copying a bare-annotated atomic owner into another binding moves the owner
;; (#8172).
(import stdlib.arena)
(import stdlib.string)

(define (main) : i64
  (let
    [owner : arena.Arena (arena.make-atomic)]
    [copied : arena.Arena owner]
    (begin
      (arena.destroy-safe! owner)
      (string.string-length (in-arena copied (string.concat "a" "b"))))))