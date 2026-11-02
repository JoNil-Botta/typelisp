;; A holder parameter whose referent does not name the by-value borrow's
;; lifetime cannot keep it: the borrow writes back after the call (#8897).
(defstruct Slot
  (:lifetimes a)
  (reference (&mut a i64)))

(define (peek! [slot : (&mut s (Slot a))] [item : (&mut b i64)]) : unit
  (set! (deref (deref slot).reference) (deref item))
  (set! (deref item) 0))

(define (main) : i64
  (let
    [values : (Array i64 2) (make-array i64 2)]
    [value : i64 42]
    [slot : (Slot values) (Slot (&mut (array-ref values 0)))]
    (peek! (&mut slot) (&mut value))
    (+ (array-ref values 0) value)))