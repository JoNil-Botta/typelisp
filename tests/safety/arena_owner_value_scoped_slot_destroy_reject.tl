;; #9445: a value from an arena an explicit end can reclaim flows only into
;; storage whose type names that arena; this slot's type names only r1.
(import stdlib.arena)
(import stdlib.string)

(defstruct Slot
  (text String))

;; a04 plus destroy of the outer owner before reading the r1 slot.
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
          (arena.destroy-safe! o)
          (if (string.string=? (& slot.text) "owner-text")
            42
            7))))))