;; KNOWN OPEN, pre-existing and unsafe (accepted; reads destroyed storage at run
;; time): tracked in #9508. A call result loses the region of a Copy reference
;; argument, and a reference parameter is not a place that loan tracking could
;; see, so shortening `(id x)` drops the brand. This row records current
;; behaviour, not correctness, and must flip to check-fail when call results
;; keep provenance (D-C47 I2).
(import stdlib.arena)

(define (id [p : (& a i64)]) : (& a i64)
  p)

(define (exercise [owner : (arena.Arena r) (:invalidate r)] [x : (& r i64)]) : i64
  (let
    [k : i64 5]
    (let
      [alias : (& k i64) (id x)]
      (begin
        (arena.destroy-safe! owner)
        (deref alias)))))

(define (main) : i64
  0)