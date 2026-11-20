;; #9479: a branded owner's phase covers a constructor result allocated by
;; `in-arena`, so its rewind ends the value.
(import stdlib.arena)
(import stdlib.string)

(defstruct Holder
  (text String))

(define (main) : i64
  (let
    [owner (arena.make)]
    [p (arena.phase owner)]
    [h (in-arena owner (Holder (string.append "a" "b")))]
    (begin
      (arena.rewind-safe! p)
      (if (string.eq (& h.text) "ab")
        42
        7))))