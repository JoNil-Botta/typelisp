;: A reference read through a `&mut` returned by a call holds the loans its
;: referent `rb` holds: writing `p.l` while it is used later conflicts (Rust
;: E0506, #8449).
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
      [m (pass (&mut rb))]
      [v : (& p i64) (deref m).value]
      (set! p.l 9)
      (deref v))))