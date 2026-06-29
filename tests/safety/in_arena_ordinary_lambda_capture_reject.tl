(import stdlib.arena)
(import "stdlib/string.tl")

(define (main) : i64
  (let
    [owner : arena.Arena (arena.make)]
    [text : String (in-arena owner (append "not-" "captured"))]
    [read : (-> i64)
      (lambda () : i64
        (string-length text))]
    (read)))