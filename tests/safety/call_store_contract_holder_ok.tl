;: As `call_store_contract_holder_reject`, but `p.r` is never written while
;: `rb` holds it (#8449).
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
    [p : Pair (Pair 1 41)]
    [rb : (RefBox p) (RefBox (& p.l))]
    (let
      [holder : (Holder rb p) (Holder (&mut rb))]
      (store (&mut holder) (& p.r)))
    (+ 1 (deref rb.value))))