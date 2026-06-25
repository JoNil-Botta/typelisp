(import "stdlib/arena.tl")
(import "stdlib/string.tl")

(define (main) : i64
  (let
    [owner : Arena (arena-make)]
    [text : String (in-arena owner (string-append "not-" "captured"))]
    [read : (-> i64)
      (lambda () : i64
        (string-length text))]
    (read)))