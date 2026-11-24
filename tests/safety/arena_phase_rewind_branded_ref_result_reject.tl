;; #9846 sibling: helper taking `(arena.Arena r)` returning `(& r str)` must
;; carry the owner's active phase across `arena.rewind-safe!`.
(import stdlib.arena)
(import stdlib.string)

(define (peek-ref [_a : (arena.Arena r)] [s : (& r str)]) : (& r str)
  s)

(define (main) : i64
  (let
    [owner (arena.make)]
    [pre (in-arena owner (string.append "a" "b"))]
    [p (arena.phase owner)]
    [v (peek-ref owner (& pre))]
    (arena.rewind-safe! p)
    (if (string.eq v "ab")
      42
      7)))