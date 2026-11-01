;: `rb` is reassigned whole, then a call may store `&p.z` into it through
;: `(&mut rb)`. Its later read may see that loan, so writing `p.z` before the
;: read conflicts, as in Rust (#8449).
(defstruct RefBox
  (:lifetimes a)
  (value (& a i64)))

(defstruct P
  (l i64)
  (r i64)
  (z i64))

(define (store [b : (&mut (RefBox a))] [v : (& a i64)]) : unit
  (set! (deref b).value v))

(define (main) : i64
  (let
    [p : P (P 1 2 3)]
    [rb : (RefBox p) (RefBox (& p.l))]
    (set! rb (RefBox (& p.r)))
    (store (&mut rb) (& p.z))
    (set! p.z 5)
    (deref rb.value)))