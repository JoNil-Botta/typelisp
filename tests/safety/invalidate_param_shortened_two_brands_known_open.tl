;; KNOWN OPEN, pre-existing and unsafe (accepted; reads destroyed storage at run
;; time): tracked in #9503. Only reference parameters carry the arena region of
;; an invalidated brand, so a nominal parameter shortened as a whole to a
;; body-local lifetime drops the brand it no longer names, as on main. This row
;; records current behaviour, not correctness, and must flip to check-fail when
;; nominal parameters keep provenance (D-C47 I2).
(import stdlib.arena)

(defstruct Pair2
  (:lifetimes a b)
  (p (& a i64))
  (q (& b i64)))

(define (exercise
  [o1 : (arena.Arena r) (:invalidate r)]
  [o2 : (arena.Arena s) (:invalidate s)]
  [x : (Pair2 r s)]) : i64
  (let
    [k : i64 5]
    (let
      [w : (Pair2 r k) x]
      (begin
        (arena.destroy-safe! o2)
        (let
          [v : i64 (deref w.q)]
          (begin
            (arena.destroy-safe! o1)
            v))))))

(define (main) : i64
  0)