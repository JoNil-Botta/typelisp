;: A call stores `&p.r` through a `&mut` returned for an implicit reborrow of
;: `r`, so it lands in what `r` points to, `rb`: writing `p.r` while `rb.value`
;: is read later conflicts (Rust E0506, #8449).
(defstruct RefBox
  (:lifetimes a)
  (value (& a i64)))

(defstruct Pair
  (l i64)
  (r i64))

(define (store [b : (&mut (RefBox a))] [v : (& a i64)]) : unit
  (set! (deref b).value v))

(define (pass [b : (&mut m (RefBox a))]) : (&mut m (RefBox a))
  b)

(define (main) : i64
  (let
    [p : Pair (Pair 1 2)]
    [rb : (RefBox p) (RefBox (& p.l))]
    (let
      [r (&mut rb)]
      [m (pass r)]
      (store m (& p.r)))
    (set! p.r 9)
    (deref rb.value)))