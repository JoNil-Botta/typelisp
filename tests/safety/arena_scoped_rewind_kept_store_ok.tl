(import stdlib.arena)
(import stdlib.string)

(defstruct Slot
  (text String))

;; Must pass: the owner's value is stored before the phase is taken, so
;; rewinding the phase leaves `slot` live (#9445).
(define (main) : i64
  (let
    [o (arena.make)]
    [kept (in-arena o (string.append "owner" "-text"))]
    (with-arena
      r1
      (let
        [slot (Slot (string.append "r1" "-text"))]
        (begin
          (set! slot.text kept)
          (let
            [phase (arena.phase o)]
            [temp (in-arena o (string.append "phase" "-text"))]
            [n : i64 (string.string-length temp)]
            (begin
              (arena.rewind-safe! phase)
              (+ n (string.string-length slot.text) 22))))))))