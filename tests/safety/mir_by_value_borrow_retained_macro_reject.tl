;; A macro-expanded by-value call scratch borrow cannot be kept through another
;; mutable argument (#8897).
(defstruct Slot
  (:lifetimes a)
  (reference (&mut a i64)))

(define (stash! [slot : (&mut s (Slot a))] [item : (&mut a i64)]) : unit
  (set! (deref slot).reference item))

(defmacro (stash-place! [slot : Expr] [place : Expr]) : Expr
  `(stash! ,slot (&mut ,place)))

(define (main) : i64
  (let
    [values : (Array i64 2) (make-array i64 2)]
    [value : i64 0]
    [slot : (Slot value) (Slot (&mut (array-ref values 0)))]
    (stash-place! (&mut slot) value)
    (set! (deref slot.reference) 42)
    value))