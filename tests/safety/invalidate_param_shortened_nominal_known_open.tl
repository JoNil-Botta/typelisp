;; KNOWN OPEN, pre-existing and unsafe (accepted; reads destroyed storage at run
;; time): tracked in #9503. Only reference parameters carry the arena region of
;; an invalidated brand, so a `(View r)` parameter shortened as a whole to
;; `(View k)` no longer names `r`, as on main. This row records current
;; behaviour, not correctness, and must flip to check-fail when nominal
;; parameters keep provenance (D-C47 I2).
(import stdlib.arena)

(defstruct View
  (:lifetimes a)
  (p (& a i64))
  (n i64))

(define (exercise [owner : (arena.Arena r) (:invalidate r)] [v : (View r)]) : i64
  (let
    [k : i64 5]
    (let
      [w : (View k) v]
      (begin
        (arena.destroy-safe! owner)
        (deref w.p)))))

(define (main) : i64
  0)