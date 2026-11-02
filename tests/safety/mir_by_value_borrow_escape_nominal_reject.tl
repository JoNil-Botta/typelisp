;; Returned mutable borrows cannot retain by-value call scratch (#8897).
(define (forward [value : (&mut value i64)]) : (&mut value i64)
  value)

(defstruct Borrowed
  (:lifetimes a)
  (reference (&mut a i64)))

(define (main) : i64
  (let
    [value : i64 0]
    [reference : (Borrowed value) (Borrowed (&mut value))]
    (set! (deref reference.reference) 42)
    value))