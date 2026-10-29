(import stdlib.arena)
(import stdlib.string)

(defstruct Slot
  (text String))

(defstruct Holder
  (slot Slot))

;; Must fail: `o`'s value is stored into an `r1` container whose binder has
;; left scope, and that container into `o2`'s `Holder`; ending `o` ends `held`
;; (#9445).
(define (main) : i64
  (let
    [o (arena.make)]
    [t (in-arena o (string.append "owner" "-text"))]
    (with-arena
      r1
      (let
        [o2 (arena.make)]
        [held
          (let
            [s (Slot (string.append "r1" "-text"))]
            (begin
              (set! s.text t)
              (in-arena o2 (Holder s))))]
        (begin
          (arena.destroy-safe! o)
          (if (string.string=? (& held.slot.text) "owner-text")
            42
            7))))))