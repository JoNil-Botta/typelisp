;: A store through a by-value holder borrowed for a call relates the stored
;: reference to the holder's signature region: writing `*x` afterwards
;: conflicts (#8449).
(defstruct RefBox
  (:lifetimes a)
  (value (& a i64)))

(defstruct Holder
  (:lifetimes i a)
  (m (&mut i (RefBox a))))

(define (store2 [w : (&mut (Holder i a))] [v : (& a i64)]) : unit
  (set! (deref (deref w).m).value v))

(define (keep-then-write [h : (Holder i a)] [x : (&mut a i64)]) : unit
  (store2 (&mut h) (& (deref x)))
  (set! (deref x) 9))

(define (main) : i64
  42)