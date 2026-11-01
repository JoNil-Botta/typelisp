;: `L`'s `a` reaches the `&mut` pointee through the recursive occurrence
;: `(L b a)`, which fills the other position, so `a` is invariant, as Rust's
;: variance fixpoint finds; main counted the occurrence as covariant.
(defenum L
  (:lifetimes a b)
  (Link (&mut a (& b i64)))
  (Wrap (Box (L b a))))

(define (shrink [w : (L program y)] [q : (& q i64)]) : (L q y)
  w)

(define (main) : i64
  0)