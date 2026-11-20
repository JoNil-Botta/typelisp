;; #9479: a branded owner's phase covers a `box` allocated by `in-arena`, so
;; its rewind ends the value.
(import stdlib.arena)
(import stdlib.string)

(define (main) : i64
  (let
    [owner (arena.make)]
    [p (arena.phase owner)]
    [b (in-arena owner (box (string.append "a" "b")))]
    (begin
      (arena.rewind-safe! p)
      (if (string.eq (& (deref b)) "ab")
        42
        7))))