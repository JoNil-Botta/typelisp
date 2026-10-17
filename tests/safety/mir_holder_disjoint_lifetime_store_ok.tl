;: A store into a holder's `m` reaches only the regions its type names:
;: the holder's other reference, typed with distinct lifetimes, keeps no loan
;: of `p` (#8449).
(defstruct RefBox
  (:lifetimes a)
  (value (& a i64)))

(defstruct Holder
  (:lifetimes i j a b)
  (m (&mut i (RefBox a)))
  (n (&mut j (RefBox b))))

(defstruct Pair
  (l i64)
  (r i64))

(define (store [h : (&mut (Holder i j a b))] [v : (& a i64)]) : unit
  (set! (deref (deref h).m).value v))

(define (main) : i64
  (let
    [p : Pair (Pair 1 2)]
    [q : i64 40]
    [rb : (RefBox p) (RefBox (& p.l))]
    [rq : (RefBox q) (RefBox (& q))]
    (let
      [holder : (Holder rb rq p q) (Holder (&mut rb) (&mut rq))]
      (store (&mut holder) (& p.r)))
    (set! p.r 9)
    (+ 2 (deref rq.value))))