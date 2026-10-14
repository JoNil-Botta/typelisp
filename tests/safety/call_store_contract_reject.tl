;: A call through `(&mut (RefBox a))` may store its `(& a i64)` argument into
;: the box: the argument's loan then lives in `rb`, so writing the borrowed
;: field while `rb` is still read conflicts (Rust's outlives constraint between
;: the two parameters, #8449).
(defstruct RefBox
  (:lifetimes a)
  (value (& a i64)))

(defstruct Pair
  (l i64)
  (r i64))

(define (store [b : (&mut (RefBox a))] [v : (& a i64)]) : unit
  (set! (deref b).value v))

(define (main) : i64
  (let
    [p : Pair (Pair 1 2)]
    [rb : (RefBox p) (RefBox (& p.l))]
    (store (&mut rb) (& p.r))
    (set! p.r 9)
    (deref rb.value)))