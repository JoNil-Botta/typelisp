(import stdlib.arena)
(import stdlib.string)

(defstruct Slot
  (text String))

(define (main) : i64
  (with-arena
    r1
    (let
      [slot (Slot (string.append "r1" "-text"))]
      [o (arena.make)]
      (begin
        (in-arena o (set! slot.text (string.append "owner" "-text")))
        (arena.destroy-safe! o)
        (if (string.string=? (& slot.text) "owner-text")
          42
          7)))))