;; #9846: helper taking a struct with `(& s (Wrap r))` reaching a branded
;; arena allocates in the owner's active phase, so its result ends at rewind.
(import stdlib.arena)
(import stdlib.string)

(defstruct Wrap
  (:lifetimes r)
  (a (arena.Arena r)))

(defstruct OuterRef
  (:lifetimes s r)
  (w (& s (Wrap r))))

(define (fill [o : (OuterRef s r)]) : (in r String)
  (in-arena o.w.a (string.append "a" "b")))

(define (main) : i64
  (let
    [owner (arena.make)]
    [p (arena.phase owner)]
    [w (Wrap owner)]
    [o (OuterRef (& w))]
    [text (fill o)]
    (arena.rewind-safe! p)
    (if (string.eq (& text) "ab")
      42
      7)))