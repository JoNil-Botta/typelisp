;; An item import alias as a with cleanup ends the arena at the scope exit.
(import stdlib.arena)
(import stdlib.string)
(import stdlib.arena.destroy-safe! as kill)

(define (main) : i64
  (let
    [o (arena.make)]
    [text (in-arena o (string.concat "ab" "cd"))]
    (begin
      (with ([a o kill]) unit)
      (string.string-length text))))