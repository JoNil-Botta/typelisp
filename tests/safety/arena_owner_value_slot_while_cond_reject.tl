;; #9445: as arena_owner_value_scoped_slot_destroy_reject, with the end in a
;; loop condition that runs after the previous iteration's store.
(import stdlib.arena)
(import stdlib.string)

(defstruct Slot
  (text String))

(defstruct Holder
  (slot Slot))

;; The end is in the while condition, which runs before the body in every
;; iteration; the store in the body ran in the previous iteration.
(define (main) : i64
  (let
    [o (arena.make)]
    (with-arena
      r1
      (let
        [slot (Slot (string.append "r1" "-text"))]
        [round : i64 0]
        (begin
          (while (begin
            (when
              (= round 1)
              (arena.destroy-safe! o)
              (return
                (if (string.string=? (& slot.text) "owner-text")
                  42
                  7)))
            (< round 3))
            (set! slot.text (in-arena o (string.append "owner" "-text")))
            (set! round (+ round 1)))
          5)))))