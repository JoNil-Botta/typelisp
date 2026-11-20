;; #9479: a clone-out through `with-scratch` inside `in-arena` lands in the
;; branded owner's phase, so its rewind ends the value.
(import stdlib.arena)
(import stdlib.string)

(define (main) : i64
  (let
    [owner (arena.make)]
    [p (arena.phase owner)]
    [text (in-arena owner (with-scratch (string.append "a" "b")))]
    (begin
      (arena.rewind-safe! p)
      (if (string.eq (& text) "ab")
        42
        7))))