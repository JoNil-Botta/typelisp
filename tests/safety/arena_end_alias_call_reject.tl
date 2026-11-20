;; An item import alias names the same `stdlib.arena` definition: its call is
;; the destroy, decided by the declaration it resolves to.
(import stdlib.arena)
(import stdlib.string)
(import stdlib.arena.destroy-safe! as kill)

(define (main) : i64
  (let
    [scratch : arena.Arena (arena.make)]
    [text (in-arena scratch (string.concat "ab" "cd"))]
    (begin
      (kill scratch)
      (string.string-length text))))