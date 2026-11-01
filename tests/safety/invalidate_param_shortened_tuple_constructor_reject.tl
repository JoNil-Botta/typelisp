;; Refs #9503: a tuple built from a shortened element keeps the element's stored
;; brand, so the brand's end invalidates the tuple.
(import stdlib.arena)

(define (exercise [owner : (arena.Arena r) (:invalidate r)] [x : (& r i64)]) : i64
  (let
    [k : i64 0]
    [t : (Tuple (& k i64) i64) (tuple x 1)]
    (arena.destroy-safe! owner)
    (deref (tuple-ref t 0))))

(define (main) : i64
  0)
