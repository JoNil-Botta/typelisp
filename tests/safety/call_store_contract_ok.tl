;: A call that may store its argument's reference into a `(&mut (RefBox a))`
;: keeps that loan only while the box is used: after the box's last read the
;: field is writable again (#8449).
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
    [p : Pair (Pair 1 40)]
    [rb : (RefBox p) (RefBox (& p.l))]
    (store (&mut rb) (& p.r))
    (let
      [seen : i64 (deref rb.value)]
      (set! p.r 2)
      (+ seen p.r))))