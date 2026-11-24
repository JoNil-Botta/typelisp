(import stdlib.arena)
(import stdlib.string)

(defstruct ArenaHolder
  (a arena.Arena))

(define (clone-arena-holder [x : (& r ArenaHolder)]) : ArenaHolder
  (ArenaHolder x.a))

(define (main) : i64
  (let
    [b : (Box ArenaHolder) (with-scratch (box (ArenaHolder (arena.current))))]
    (in-arena (. (deref b) a) (string.string-length (string.int->string 42)))))