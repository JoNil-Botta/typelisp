(import stdlib.arena)
(import stdlib.string)

(defstruct Slot
  (text String))

;; Known conservative rejection (#9445): a store later in the loop places `o`'s
;; values in `slot`'s region, so ending `o` inside the loop while `slot` is
;; live is rejected, though `slot` is not read after the end.
(define (main) : i64
  (let
    [o (arena.make)]
    (with-arena
      r1
      (let
        [slot (Slot (string.append "r1" "-text"))]
        [round : i64 0]
        (while (< round 3)
          (when (= round 1) (arena.destroy-safe! o) (break))
          (set! slot.text (in-arena o (string.append "owner" "-text")))
          (set! round (+ round 1)))
        42))))