(import stdlib.arena)
(import "stdlib/string.tl")

(define (build-text) : String
  (let
    [owner : arena.Arena (arena.make)]
    (in-arena owner (append "not-" "returned"))))

(define (main) : i64
  (string-length (build-text)))