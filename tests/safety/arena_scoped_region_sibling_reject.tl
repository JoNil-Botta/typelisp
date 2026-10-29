(import stdlib.arena)
(import stdlib.string)

(defstruct Slot
  (text String))

;; Known conservative rejection (#9445): the store places `o`'s value in `r1`,
;; so ending `o` ends every value of `r1`, `x` included, though `x` never held
;; it.
(define (main) : i64
  (let
    [o (arena.make)]
    [t (in-arena o (string.append "owner" "-text"))]
    (with-arena
      r1
      (let
        [slot (Slot (string.append "r1" "-text"))]
        [x (string.append "r1" "-text")]
        (begin
          (set! slot.text t)
          (arena.destroy-safe! o)
          (+ (string.string-length x) 35))))))