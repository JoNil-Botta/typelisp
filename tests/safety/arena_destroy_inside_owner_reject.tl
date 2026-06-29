(import "stdlib/arena.tl")
(import "stdlib/string.tl")

(define (main) : i64
  (let
    [owner : Arena (arena-make)]
    (begin
      (in-arena owner (arena-destroy-safe! owner))
      42)))