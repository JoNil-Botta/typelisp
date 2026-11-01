(import stdlib.arena)
(import stdlib.string)

(defstruct Slot
  (text String))

(define (fill [owner : (arena.Arena source)]) : (in source Slot)
  (with-arena
    r1
    (let
      [short (string.append "r1" "-text")]
      (in-arena
        owner
        (let
          [slot (Slot (string.append "o" "-text"))]
          (begin
            (set! slot.text short)
            slot))))))

(define (main) : i64
  (let
    [o (arena.make)]
    [slot (fill o)]
    (string.string-length slot.text)))