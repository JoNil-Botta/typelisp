;; KNOWN OPEN (#9503): shortening a join can erase the parameter's provenance.
;; This pins unsafe current behaviour only. Never execute the ended read.
(import stdlib.arena)

(define (exercise
  [owner : (arena.Arena r) (:invalidate r)]
  [x : (& r i64)]
  [c : bool]) : i64
  (let
    [k : i64 0]
    [alias : (& k i64)
      (if c
        x
        x)]
    (arena.destroy-safe! owner)
    (deref alias)))

(define (main) : i64
  0)