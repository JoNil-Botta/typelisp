;: As `mir_reborrow_call_store_reject` through a `&mut` parameter: the stored
;: loan lands in the parameter's referent, which keeps it until the body
;: returns, so writing `(deref p).r` conflicts (Rust E0506, #8449).
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

(define (f [rb : (&mut q (RefBox a))] [p : (&mut a Pair)]) : i64
  (let
    [m (pass rb)]
    (store m (& (deref p).r)))
  (set! (deref p).r 9)
  (deref (deref rb).value))

(define (main) : i64
  (let
    [p : Pair (Pair 1 2)]
    [q : Pair (Pair 3 4)]
    [rb : (RefBox q) (RefBox (& q.l))]
    (f (&mut rb) (&mut p))))