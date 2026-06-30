(import stdlib.arena)
(import stdlib.string)

(define (main) : i64
  (let
    [owner : arena.Arena (arena.make)]
    [text : String ""]
    (begin
      (set! text (in-arena owner (string.append "not-" "stored")))
      (string.string-length text))))