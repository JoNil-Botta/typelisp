;; The retention check reads the signature (#8897): `peek!` never stores
;; `item`, but its holder parameter's referent names `item`'s lifetime, so a
;; by-value call scratch borrow is still rejected. Precise acceptance would need
;; escape analysis of the callee's body.
(defstruct Slot
  (:lifetimes a)
  (reference (&mut a i64)))

(define (peek! [_slot : (&mut s (Slot a))] [item : (&mut a i64)]) : unit
  (set! (deref item) (+ (deref item) 42)))

(define (main) : i64
  (let
    [values : (Array i64 2) (make-array i64 2)]
    [value : i64 0]
    [slot : (Slot value) (Slot (&mut (array-ref values 0)))]
    (peek! (&mut slot) (&mut value))
    value))