;; KNOWN OPEN, pre-existing and unsafe (accepted; reads destroyed storage at run
;; time): tracked in #9508. A field projection loses the region of a Copy
;; reference field, as for `(in r T)` parameters, so shortening a field read
;; through a reference parameter drops the brand. This row records current
;; behaviour, not correctness, and must flip to check-fail when projections
;; keep provenance (D-C47 I2).
(import stdlib.arena)

(defstruct View
  (:lifetimes a)
  (p (& a i64))
  (n i64))

(define (exercise
  [owner : (arena.Arena r) (:invalidate r)]
  [v : (& r (View r))]) : i64
  (let
    [k : i64 5]
    (let
      [alias : (& k i64) (deref v).p]
      (begin
        (arena.destroy-safe! owner)
        (deref alias)))))

(define (main) : i64
  0)