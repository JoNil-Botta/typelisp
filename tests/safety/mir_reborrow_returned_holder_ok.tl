;: A `&mut` passed through a function and returned keeps the loans its type
;: names, and releases them after its last use (#8449).
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
      (deref (deref m).value))
    (+ 41 (deref rb.value))))