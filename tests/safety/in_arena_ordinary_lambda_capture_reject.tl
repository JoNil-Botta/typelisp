(import stdlib.arena)
(import stdlib.string)

(define (main) : i64
  (let
    [owner : arena.Arena (arena.make)]
    [text : String (in-arena owner (string.append "not-" "captured"))]
    [read : (-> i64)
      (lambda () : i64
        (string.string-length text))]
    (read)))