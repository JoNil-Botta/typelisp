(import stdlib.arena)
(import stdlib.string)

(defstruct ArenaHolder
  (a arena.Arena))

(define (main) : i64
  (let
    [h : ArenaHolder (with-scratch (ArenaHolder (arena.current)))]
    (in-arena h.a (string.string-length (string.int->string 42)))))