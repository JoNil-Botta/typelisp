;; #9846: helper taking an enum with a borrowed `(& s (arena.Arena r))`
;; payload allocates in the owner's active phase, so its result ends at rewind.
(import stdlib.arena)
(import stdlib.string)

(defenum RefEnum
  (:lifetimes s r)
  (Has (& s (arena.Arena r)))
  (None))

(define (fill [e : (RefEnum s r)]) : (in r String)
  (match e
    [(Has a) (in-arena a (string.append "a" "b"))]
    [(None) ""]))

(define (main) : i64
  (let
    [owner (arena.make)]
    [p (arena.phase owner)]
    [e (RefEnum.Has (& owner))]
    [text (fill e)]
    (arena.rewind-safe! p)
    (if (string.eq (& text) "ab")
      42
      7)))