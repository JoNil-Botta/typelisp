;: A type holding a recursive one takes its variance from the fixpoint too:
;: `Outer` is invariant in `a` because `M` is.
(defenum M
  (:lifetimes a b)
  (Link (&mut a (& b i64)))
  (Wrap (Box (M b a))))

(defstruct Outer
  (:lifetimes a b)
  (m (M a b)))

(define (shrink [w : (Outer program y)] [q : (& q i64)]) : (Outer q y)
  w)

(define (main) : i64
  0)