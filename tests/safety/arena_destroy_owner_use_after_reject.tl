(import "stdlib/arena.tl")
(import "stdlib/string.tl")

(define (main) : i64
  (let
    [owner : Arena (arena-make)]
    [text : String (in-arena owner (string-append "owned" "-text"))]
    (begin
      (string-length text)
      (arena-destroy-safe! owner)
      (in-arena owner (string-append "after" "-destroy"))
      42)))