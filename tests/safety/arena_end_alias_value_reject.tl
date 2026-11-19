;; An item import alias of `arena.destroy-safe!` is not a function value
;; either.
(import stdlib.arena)
(import stdlib.string)
(import stdlib.arena.destroy-safe! as kill)

(define (main) : i64
  (let
    [scratch : arena.Arena (arena.make)]
    [text (in-arena scratch (string.concat "ab" "cd"))]
    [f : (-> arena.Arena unit) kill]
    (begin
      (f scratch)
      (string.string-length text))))