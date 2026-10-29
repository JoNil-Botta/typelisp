(import stdlib.arena)
(import stdlib.string)

(defstruct Slot
  (text String))

(define (release [owner : (arena.Arena r) (:invalidate r)]) : unit
  (arena.destroy-safe! owner))

(define (main) : i64
  (let
    [o (arena.make)]
    [t (in-arena o (string.append "owner" "-text"))]
    (with-arena
      r1
      (let
        [slot (Slot (string.append "r1" "-text"))]
        (begin
          (set! slot.text t)
          (release o)
          (if (string.string=? (& slot.text) "owner-text")
            42
            7))))))