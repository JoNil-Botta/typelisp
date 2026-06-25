(import "stdlib/arena.tl")
(import "stdlib/string.tl")

(define (build-text) : String
  (let
    [owner : Arena (arena-make)]
    (in-arena owner (string-append "not-" "returned"))))

(define (main) : i64
  (string-length (build-text)))