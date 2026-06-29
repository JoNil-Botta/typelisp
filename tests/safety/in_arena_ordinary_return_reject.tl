(import stdlib.arena)
(import stdlib.string)

(define (build-text) : String
  (let
    [owner : arena.Arena (arena.make)]
    (in-arena owner (string.append "not-" "returned"))))

(define (main) : i64
  (string.string-length (build-text)))