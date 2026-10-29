;; Must pass: no store places the older arena's values in the region of the
;; younger scope's `with` owner, so rewinding that arena while the owner is
;; live is allowed (#9445).
(import stdlib.arena)
(import stdlib.string)

(define (drop-n [n : i64]) : unit
  unit)

(defstruct Owner
  (:cleanup cleanup-owner)
  (n i64 (:cleanup drop-n))
  (text String))

(define (main) : i64
  (let
    [o (arena.make)]
    [phase (arena.phase o)]
    [t (in-arena o (string.append "owner" "-text"))]
    [n : i64 (string.string-length t)]
    (with-arena
      r1
      (with
        ([w (Owner 1 (string.concat "r1" "-own")) cleanup-owner])
        (begin
          (arena.rewind-safe! phase)
          (+ n 32))))))