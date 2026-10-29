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
        [slot (Slot (string.append "r1" "-text"))]
        [o2 (arena.make)]
        (begin
          (set! slot.text t)
          (let
            [held (in-arena o2 (Holder slot))]
            (begin
              (arena.destroy-safe! o)
              (if (string.string=? (& held.slot.text) "owner-text")
                42
                7))))))))