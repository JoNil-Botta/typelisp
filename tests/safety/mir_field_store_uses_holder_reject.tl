;: `j` holds a reborrow of `*m`; `(pass m)` reborrows `*m` mutably again
;: while `j` is still live: storing into its field `j.v` uses `j`, whose
;: other field keeps the first reborrow, as in Rust (#8449).
(defstruct P
  (l i64)
  (r i64))

(defstruct RefBox
  (:lifetimes a)
  (value (& a i64)))

(defstruct Job
  (:lifetimes i a)
  (m (&mut i (RefBox a)))
  (v (& a i64)))

(define (pass [b : (&mut m (RefBox a))]) : (&mut m (RefBox a))
  b)

(define (main) : i64
  (let
    [p : P (P 40 2)]
    [rb : (RefBox p) (RefBox (& p.l))]
    [m (&mut rb)]
    [j (Job m (& p.r))]
    [m2 (pass m)]
    (set! j.v (& p.l))
    42))