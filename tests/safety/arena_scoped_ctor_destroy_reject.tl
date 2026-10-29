(import stdlib.arena)
(import stdlib.string)

(defstruct Slot
  (text String))

(define (main) : i64
  (let
    [o (arena.make)]
    [t (in-arena o (string.append "owner" "-text"))]
    (with-arena
      r1
      (let
        [slot (Slot t)]
        (begin
          (arena.destroy-safe! o)
          (if (string.string=? (& slot.text) "owner-text")
            42
            7))))))