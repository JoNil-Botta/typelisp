;; #9846 sibling: helper taking an aggregate holding `(arena.Arena r)` allocates
;; in the owner's active phase, so its result must end at `arena.rewind-safe!`.
(import stdlib.arena)
(import stdlib.string)

(defstruct Wrap
  (:lifetimes r)
  (a (arena.Arena r)))

(define (fill-wrap [w : (Wrap r)]) : (in r String)
  (in-arena w.a (string.append "a" "b")))

(define (main) : i64
  (let
    [owner (arena.make)]
    [p (arena.phase owner)]
    [w (Wrap owner)]
    [text (fill-wrap w)]
    (arena.rewind-safe! p)
    (if (string.eq (& text) "ab")
      42
      7)))