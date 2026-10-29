(import stdlib.arena)
(import stdlib.string)

(defstruct Slot
  (text String))

(defstruct Holder
  (slot Slot))

(define (release [owner : (arena.Arena r) (:invalidate r)]) : unit
  (arena.destroy-safe! owner))

;; Must fail: the same chain into `o2`'s `Holder`, ended by an `:invalidate`
;; call (#9445).
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
          (release o)
          (if (string.string=? (& held.slot.text) "owner-text")
            42
            7))))))