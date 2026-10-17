;: `hh` is reassigned whole, so its reads are split into its definitions.
;: `Outer` passes its lifetimes to `Inner` in swapped order: the read of
;: `hh.inner` keeps the field's own type, so `x` holds the loan of `q.r` and
;: writing `q.r` before reading `x` conflicts, as in Rust (#8449).
(defstruct Inner
  (:lifetimes a b)
  (x (& a i64))
  (y (& b i64)))

(defstruct Outer
  (:lifetimes a b)
  (inner (Inner b a)))

(defstruct P
  (l i64)
  (r i64))

(define (main) : i64
  (let
    [p : P (P 1 2)]
    [q : P (P 3 4)]
    [hh : (Outer p q) (Outer (Inner (& q.l) (& p.l)))]
    (set! hh (Outer (Inner (& q.r) (& p.r))))
    (let
      [in : (Inner q p) hh.inner]
      [x : (& q i64) in.x]
      (set! q.r 9)
      (deref x))))