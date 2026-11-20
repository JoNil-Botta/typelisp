;; #9445: the rule of arena_owner_value_scoped_slot_destroy_reject rejects the
;; store itself, so this twin, which never destroys `o`, is rejected too: `o`
;; outlives r1 lexically, but a safe destroy could reclaim it first.
(import stdlib.arena)
(import stdlib.string)

(defstruct Slot
  (text String))

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
          (if (string.string=? (& slot.text) "owner-text")
            42
            7))))))