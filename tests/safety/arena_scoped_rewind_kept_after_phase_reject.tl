(import stdlib.arena)
(import stdlib.string)

(defstruct Slot
  (text String))

;; Known conservative rejection (#9445): a phase's allocations are stored as
;; values of its owner, so a store of the owner's older value made after the
;; phase was taken is ended by the rewind too.
(define (main) : i64
  (let
    [o (arena.make)]
    [kept (in-arena o (string.append "owner" "-text"))]
    [phase (arena.phase o)]
    (with-arena
      r1
      (let
        [slot (Slot (string.append "r1" "-text"))]
        (begin
          (set! slot.text kept)
          (arena.rewind-safe! phase)
          (+ (string.string-length slot.text) 32))))))