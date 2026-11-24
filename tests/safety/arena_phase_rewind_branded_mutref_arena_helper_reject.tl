;; #9846 sibling: helper taking `(&mut (arena.Arena r))` allocates in the
;; owner's active phase, so its result must end at `arena.rewind-safe!`.
(import stdlib.arena)
(import stdlib.string)

(define (fill-mut [a : (&mut (arena.Arena r))]) : (in r String)
  (in-arena a (string.append "a" "b")))

(define (main) : i64
  (let
    [owner (arena.make)]
    [p (arena.phase owner)]
    [text (fill-mut (&mut owner))]
    (arena.rewind-safe! p)
    (if (string.eq (& text) "ab")
      42
      7)))