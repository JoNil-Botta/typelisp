;; Refs #9502 Refs #9493. Brand/phase ids are not current binding boundaries.
(import stdlib.arena)
;; Branded param brand r; a bare Arena value named r is bound inside the activation.
(define (exercise [owner : (arena.Arena r) (:invalidate r)]) : i64
  (in-arena
    owner
    (let
      [r : arena.Arena (arena.make)]
      (begin
        (arena.destroy-safe! owner)
        (arena.destroy-safe! r)
        42))))
(define (main) : i64
  (let
    [owner (arena.make)]
    (exercise owner)))
