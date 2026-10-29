(import stdlib.arena)
(import stdlib.string)

(defstruct Slot
  (text String))

;; Must pass: a younger owner's struct survives an older owner's phase rewind
;; when no store places the phase's values in it (#9445).
(define (main) : i64
  (let
    [o (arena.make)]
    [phase (arena.phase o)]
    [scratch (in-arena o (string.append "tmp" "-text"))]
    [o2 (arena.make)]
    [held (in-arena o2 (Slot (string.append "o2" "-text")))]
    (begin
      (arena.rewind-safe! phase)
      (if (string.string=? (& held.text) "o2-text")
        42
        7))))