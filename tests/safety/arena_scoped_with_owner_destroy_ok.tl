;; Must pass: no store places the older arena's values in the region of the
;; younger scope's `with` owner, so destroying that arena while the owner is
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
    [t (in-arena o (string.append "owner" "-text"))]
    [n : i64 (string.string-length t)]
    (with-arena
      r1
      (with
        ([w (Owner 1 (string.concat "r1" "-own")) cleanup-owner])
        (begin
          (arena.destroy-safe! o)
          (+ n 32))))))