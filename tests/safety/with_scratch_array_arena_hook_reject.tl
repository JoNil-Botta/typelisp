(import stdlib.arena)
(import stdlib.string)

(defstruct ArenaHolder
  (a arena.Arena))

(define (clone-arena-holder [x : (& r ArenaHolder)]) : ArenaHolder
  (ArenaHolder x.a))

(define (main) : i64
  (let
    [arr : (Array ArenaHolder 1)
      (with-scratch (array (ArenaHolder (arena.current))))]
    (in-arena
      (. (array-ref arr 0) a)
      (string.string-length (string.int->string 42)))))