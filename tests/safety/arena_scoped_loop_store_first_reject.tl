(import stdlib.arena)
(import stdlib.string)

(defstruct Slot
  (text String))

;; Must fail: the store into `slot` precedes the end in the loop body (#9445).
(define (main) : i64
  (let
    [o (arena.make)]
    (with-arena
      r1
      (let
        [slot (Slot (string.append "r1" "-text"))]
        [round : i64 0]
        (while (< round 3)
          (set! slot.text (in-arena o (string.append "owner" "-text")))
          (when (= round 1) (arena.destroy-safe! o) (break))
          (set! round (+ round 1)))
        (if (string.string=? (& slot.text) "owner-text")
          42
          7)))))