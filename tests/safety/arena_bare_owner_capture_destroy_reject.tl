;; A closure capturing a bare-annotated ordinary owner moves the owner (#8172).
(import stdlib.arena)
(import stdlib.string)

(define (main) : i64
  (let
    [owner : arena.Arena (arena.make)]
    [measure : (-> i64)
      (lambda () : i64
        (string.string-length (in-arena owner (string.concat "a" "b"))))]
    (begin
      (arena.destroy-safe! owner)
      (measure))))