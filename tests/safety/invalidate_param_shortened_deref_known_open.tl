;; KNOWN OPEN, pre-existing and unsafe (accepted; reads destroyed storage at run
;; time): tracked in #9508. A deref of a reference to a reference loses the
;; region, as for `(in r T)` parameters, so shortening `(deref x)` drops the
;; brand. This row records current behaviour, not correctness, and must flip to
;; check-fail when derefs keep provenance (D-C47 I2).
(import stdlib.arena)

(define (exercise
  [owner : (arena.Arena r) (:invalidate r)]
  [x : (& r (& r i64))]) : i64
  (let
    [k : i64 5]
    (let
      [alias : (& k i64) (deref x)]
      (begin
        (arena.destroy-safe! owner)
        (deref alias)))))

(define (main) : i64
  0)