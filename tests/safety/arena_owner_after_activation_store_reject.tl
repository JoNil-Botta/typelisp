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
      [t (in-arena o (string.append "owner" "-text"))]
      (begin
        (set! slot.text t)
        (arena.destroy-safe! o)
        (if (string.string=? (& slot.text) "owner-text")
          42
          7)))))