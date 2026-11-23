;; #9846: helper taking a struct with a borrowed `(& s (arena.Arena r))`
;; allocates in the owner's active phase, so its result ends at rewind.
(import stdlib.arena)
(import stdlib.string)

(defstruct RefWrap
  (:lifetimes s r)
  (a (& s (arena.Arena r))))

(define (fill [w : (RefWrap s r)]) : (in r String)
  (in-arena w.a (string.append "a" "b")))

(define (main) : i64
  (let
    [owner (arena.make)]
    [p (arena.phase owner)]
    [w (RefWrap (& owner))]
    [text (fill w)]
    (arena.rewind-safe! p)
    (if (string.eq (& text) "ab")
      42
      7)))