(import stdlib.arena)
(import "stdlib/string.tl")

(define (main) : i64
  (let
    [owner : arena.Arena (arena.make)]
    [text : String ""]
    (begin
      (set! text (in-arena owner (append "not-" "stored")))
      (string-length text))))