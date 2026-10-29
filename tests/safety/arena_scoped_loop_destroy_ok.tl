(import stdlib.arena)
(import stdlib.string)

(defstruct Slot
  (text String))

;; Must pass: the loop ends `o` while `slot` is live, and its stores place only
;; another arena's values in `slot`'s region (#9445).
(define (main) : i64
  (let
    [o (arena.make)]
    [o3 (arena.make)]
    (with-arena
      r1
      (let
        [slot (Slot (string.append "r1" "-text"))]
        [round : i64 0]
        (while (< round 3)
          (when (= round 1) (arena.destroy-safe! o) (break))
          (set! slot.text (in-arena o3 (string.append "r1" "-next")))
          (set! round (+ round 1)))
        (if (string.string=? (& slot.text) "r1-next")
          42
          7)))))