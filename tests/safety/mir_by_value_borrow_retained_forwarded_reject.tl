;; Forwarding a by-value call scratch borrow to a retaining callee is still
;; rejected at the outer call (#8897).
(defstruct Slot
  (:lifetimes a)
  (reference (&mut a i64)))

(define (stash! [slot : (&mut s (Slot a))] [item : (&mut a i64)]) : unit
  (set! (deref slot).reference item))

(define (forward-stash! [slot : (&mut s (Slot a))] [item : (&mut a i64)]) : unit
  (stash! slot item))

(define (main) : i64
  (let
    [values : (Array i64 2) (make-array i64 2)]
    [value : i64 0]
    [slot : (Slot value) (Slot (&mut (array-ref values 0)))]
    (forward-stash! (&mut slot) (&mut value))
    (set! (deref slot.reference) 42)
    value))