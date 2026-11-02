;; A callee cannot keep a by-value small-aggregate call scratch borrow through
;; another mutable argument (#8897).
(defstruct Counter
  (len i64)
  (cap i64))

(defstruct Slot
  (:lifetimes a)
  (reference (&mut a Counter)))

(define (stash! [slot : (&mut s (Slot a))] [item : (&mut a Counter)]) : unit
  (set! (deref slot).reference item))

(define (main) : i64
  (let
    [values : (Array Counter 2) (make-array Counter 2)]
    [counter : Counter (Counter 0 2)]
    [slot : (Slot counter) (Slot (&mut (array-ref values 0)))]
    (stash! (&mut slot) (&mut counter))
    (set! (deref slot.reference).len 42)
    counter.len))