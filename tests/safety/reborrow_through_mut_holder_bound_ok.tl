;: A reborrow of the `&mut` a holder stores, reached through `(&mut o ...)`,
;: has the outer lifetime `o` (#8449).
(defstruct RefBox
  (:lifetimes a)
  (value (& a i64)))

(defstruct Holder
  (:lifetimes i a)
  (m (&mut i (RefBox a))))

(define (inner [h : (&mut o (Holder i a))]) : (&mut o (RefBox a))
  (&mut (deref (deref h).m)))

(define (main) : i64
  (let
    [x : i64 42]
    [rb : (RefBox x) (RefBox (& x))]
    [holder : (Holder rb x) (Holder (&mut rb))]
    (deref (deref (inner (&mut holder))).value)))