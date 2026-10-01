;; After a copy moves a bare-annotated owner, a safe rewind of the original is a
;; use of the moved owner (#8172).
(import stdlib.arena)
(import stdlib.string)

(define (main) : i64
  (let
    [owner : arena.Arena (arena.make)]
    [copied : arena.Arena owner]
    [mark : arena.ArenaPhase (arena.phase owner)]
    (begin
      (arena.rewind-safe! mark)
      (string.string-length (in-arena copied (string.concat "a" "b"))))))