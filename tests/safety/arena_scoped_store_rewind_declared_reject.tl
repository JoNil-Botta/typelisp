(import stdlib.arena)
(import stdlib.string)

(defstruct Slot
  (text String))

;; Must fail: the same store and rewind through a declared `arena.Arena`
;; owner, whose phase values carry the phase region (#9445).
(define (main) : i64
  (let
    [o : arena.Arena (arena.make)]
    [phase (arena.phase o)]
    [t (in-arena o (string.append "owner" "-text"))]
    (with-arena
      r1
      (let
        [slot (Slot (string.append "r1" "-text"))]
        (begin
          (set! slot.text t)
          (arena.rewind-safe! phase)
          (in-arena o (string.append "clobber" "-the-old-text"))
          (if (string.string=? (& slot.text) "owner-text")
            42
            7))))))