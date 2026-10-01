;; After a copy moves a bare-annotated owner, `in-arena` on the original is a
;; use of the moved owner (#8172).
(import stdlib.arena)
(import stdlib.string)

(define (main) : i64
  (let
    [owner : arena.Arena (arena.make)]
    [copied : arena.Arena owner]
    (string.string-length (in-arena owner (string.concat "a" "b")))))