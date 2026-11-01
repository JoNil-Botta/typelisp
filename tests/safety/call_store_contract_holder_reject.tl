;: A call with a `(&mut Holder)` parameter may store through the `&mut` the
;: holder holds: `&p.r` lands in `rb`, so writing `p.r` while `rb.value` is
;: read later conflicts (Rust E0506, #8449).
(defstruct RefBox
  (:lifetimes a)
  (value (& a i64)))

(defstruct Holder
  (:lifetimes i a)
  (m (&mut i (RefBox a))))

(defstruct Pair
  (l i64)
  (r i64))

(define (store [h : (&mut (Holder i a))] [v : (& a i64)]) : unit
  (set! (deref (deref h).m).value v))

(define (main) : i64
  (let
    [p : Pair (Pair 1 2)]
    [rb : (RefBox p) (RefBox (& p.l))]
    [holder : (Holder rb p) (Holder (&mut rb))]
    (store (&mut holder) (& p.r))
    (set! p.r 9)
    (deref rb.value)))