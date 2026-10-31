;; KNOWN OPEN, pre-existing and unsafe (accepted; reads destroyed storage at run
;; time): tracked in #9508. A constructor stores a Copy reference without its
;; region, so a struct built from `x` at a body-local lifetime drops the brand.
;; This row records current behaviour, not correctness, and must flip to
;; check-fail when constructed values keep provenance (D-C47 I2).
(import stdlib.arena)

(defstruct Cell
  (:lifetimes a)
  (p (& a i64)))

(define (exercise [owner : (arena.Arena r) (:invalidate r)] [x : (& r i64)]) : i64
  (let
    [k : i64 5]
    (let
      [c : (Cell k) (Cell x)]
      (begin
        (arena.destroy-safe! owner)
        (deref c.p)))))

(define (main) : i64
  0)