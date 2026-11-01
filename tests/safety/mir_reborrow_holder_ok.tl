;: An implicit reborrow of `r`, a `&mut` to a value holding a reference, has
;: `r`'s own loan as its parent, not the loans `rb` holds (#8449).
(defstruct RefBox
  (:lifetimes a)
  (value (& a i64)))

(defstruct Pair
  (l i64)
  (r i64))

(define (pass [b : (&mut m (RefBox a))]) : (&mut m (RefBox a))
  b)

(define (main) : i64
  (let
    [p : Pair (Pair 1 2)]
    [rb : (RefBox p) (RefBox (& p.l))]
    (let
      [r (&mut rb)]
      [m (pass r)]
      (set! (deref m).value (& p.r)))
    (+ 40 (deref rb.value))))