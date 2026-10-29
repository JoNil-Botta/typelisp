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
      [p (arena.phase o)]
      (begin
        (in-arena o (set! slot.text (string.append "owner" "-text")))
        (arena.rewind-safe! p)
        (+ (string.string-length slot.text) 32)))))