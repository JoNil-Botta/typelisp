;: As `call_store_contract_returned_ref_reject`, but `p.r` is written after
;: the last read of `rb` (#8449).
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
    [p : Pair (Pair 1 40)]
    [rb : (RefBox p) (RefBox (& p.l))]
    (let
      [m (pass (&mut rb))]
      (store m (& p.r)))
    (let
      [seen : i64 (deref rb.value)]
      (set! p.r 2)
      (+ seen p.r))))