;; The retention check reads the signature (#8897): `Marker` names lifetime
;; `a` without storing a reference, yet a by-value call scratch borrow of that
;; lifetime is still rejected beside a mutable `Marker` parameter.
(defstruct Marker
  (:lifetimes a)
  (value i64))

(define (write! [_marker : (&mut m (Marker a))] [item : (&mut a i64)]) : unit
  (set! (deref item) 42))

(define (main) : i64
  (let
    [value : i64 0]
    [marker : (Marker value) (Marker 0)]
    (write! (&mut marker) (&mut value))
    value))