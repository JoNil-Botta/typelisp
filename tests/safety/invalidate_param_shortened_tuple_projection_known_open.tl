;; KNOWN OPEN, pre-existing and unsafe (accepted; reads destroyed storage at run
;; time): tracked in #9508. A tuple projection loses the region of a Copy
;; reference element, as for `(in r T)` parameters, so shortening an element
;; read through a reference parameter drops the brand. This row records current
;; behaviour, not correctness, and must flip to check-fail when projections
;; keep provenance (D-C47 I2).
(import stdlib.arena)

(define (exercise
  [owner : (arena.Arena r) (:invalidate r)]
  [x : (& r (Tuple (& r i64) i64))]) : i64
  (let
    [k : i64 5]
    (let
      [alias : (& k i64) (tuple-ref (deref x) 0)]
      (begin
        (arena.destroy-safe! owner)
        (deref alias)))))

(define (main) : i64
  0)