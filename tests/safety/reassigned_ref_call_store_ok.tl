;: As `reassigned_ref_call_store_reject`, but `p.z` is written after the last
;: read of `rb` (#8449).
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
    (let
      [seen : i64 (deref rb.value)]
      (set! p.z 39)
      (+ seen p.z))))