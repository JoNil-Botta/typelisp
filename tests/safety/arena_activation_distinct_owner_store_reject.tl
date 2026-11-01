(import stdlib.arena)
(import stdlib.string)

(defstruct Slot
  (text String))

(define (main) : i64
  (let
    [o1 (arena.make)]
    [t (in-arena o1 (string.append "o1" "-text"))]
    [o2 (arena.make)]
    (in-arena
      o2
      (let
        [slot (Slot (string.append "o2" "-text"))]
        (begin
          (set! slot.text t)
          (arena.destroy-safe! o1)
          (if (string.string=? (& slot.text) "o1-text")
            42
            7))))))