;; Array element storage persists after a callee keeps its borrow through
;; another mutable argument (#8897).
(defstruct Slot
  (:lifetimes a)
  (reference (&mut a i64)))

(define (stash! [slot : (&mut s (Slot a))] [item : (&mut a i64)]) : unit
  (set! (deref slot).reference item))

(define (main) : i64
  (let
    [values : (Array i64 2) (make-array i64 2)]
    [targets : (Array i64 2) (make-array i64 2)]
    [slot : (Slot targets) (Slot (&mut (array-ref values 0)))]
    (stash! (&mut slot) (&mut (array-ref targets 0)))
    (set! (deref slot.reference) 42)
    (array-ref targets 0)))