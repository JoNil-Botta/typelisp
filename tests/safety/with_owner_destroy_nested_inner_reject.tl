;; Only the inner owner carries the destroyed arena's brand, so the diagnostic
;; names it; the outer owner lives in the caller's arena.
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
    [scratch : arena.Arena (arena.make)]
    (with
      ([outer (Owner 1 (string.concat "out" "er")) cleanup-owner])
      (with
        ([inner
            (in-arena scratch (Owner 1 (string.concat "in" "ner")))
            cleanup-owner])
        (begin
          (arena.destroy-safe! scratch)
          (string.string-length (& outer.text)))))))