;; Moving the owner out before the destroy is judged by the existing `with`
;; rule: an ordinary cleanup owner may not be moved before its scope ends.
(import stdlib.arena)
(import stdlib.string)

(define (drop-n [n : i64]) : unit
  unit)

(defstruct Owner
  (:cleanup cleanup-owner)
  (n i64 (:cleanup drop-n))
  (text String))

(define (consume [owner : Owner]) : i64
  (string.string-length (& owner.text)))

(define (main) : i64
  (let
    [scratch : arena.Arena (arena.make)]
    (with
      ([owner
          (in-arena scratch (Owner 1 (string.concat "ab" "cd")))
          cleanup-owner])
      (let
        [n : i64 (consume owner)]
        (begin
          (arena.destroy-safe! scratch)
          n)))))