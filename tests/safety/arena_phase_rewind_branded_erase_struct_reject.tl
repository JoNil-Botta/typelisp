;; #9846: branded `(arena.Arena r)` helper returning a Copy `ArenaBox` struct
;; must tag the struct with the active phase so allocations through its field
;; end at `arena.rewind-safe!`.
(import stdlib.arena)
(import stdlib.string)

(defstruct ArenaBox
  (a arena.Arena))

(define (box-arena [a : (arena.Arena r)]) : ArenaBox
  (ArenaBox a))

(define (main) : i64
  (let
    [owner (arena.make)]
    [p (arena.phase owner)]
    [b (box-arena owner)]
    [s (in-arena b.a (string.append "hello" "world"))]
    (arena.rewind-safe! p)
    (if (string.eq (& s) "helloworld")
      42
      7)))