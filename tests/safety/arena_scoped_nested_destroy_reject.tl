(import stdlib.arena)
(import stdlib.string)

(defstruct Slot
  (text String))

(defstruct Holder
  (slot Slot))

(define (main) : i64
  (let
    [o (arena.make)]
    [t (in-arena o (string.append "owner" "-text"))]
    (with-arena
      r1
      (let
        [holder (Holder (Slot (string.append "r1" "-text")))]
        (with-arena
          r2
          (let
            [slot (Slot (string.append "r2" "-text"))]
            (begin
              (set! slot.text t)
              (arena.destroy-safe! o)
              (if (string.string=? (& slot.text) "owner-text")
                42
                7))))))))