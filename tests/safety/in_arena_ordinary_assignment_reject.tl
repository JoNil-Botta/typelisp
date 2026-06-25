(import "stdlib/arena.tl")
(import "stdlib/string.tl")

(define (main) : i64
  (let
    [owner : Arena (arena-make)]
    [text : String ""]
    (begin
      (set! text (in-arena owner (string-append "not-" "stored")))
      (string-length text))))