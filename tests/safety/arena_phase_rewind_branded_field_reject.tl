;; #9479: `in-arena` on a branded owner field allocates in the owner's phase,
;; so its rewind ends the value.
(import stdlib.arena)
(import stdlib.string)

(defstruct State
  (:lifetimes r)
  (arena (arena.Arena r)))

(define (main) : i64
  (let
    [owner (arena.make)]
    [p (arena.phase owner)]
    [state (State owner)]
    [text (in-arena state.arena (string.append "a" "b"))]
    (begin
      (arena.rewind-safe! p)
      (if (string.eq (& text) "ab")
        42
        7))))