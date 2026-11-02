;; Returned mutable borrows cannot retain by-value call scratch (#8897).
(define (forward [value : (&mut value i64)]) : (&mut value i64)
  value)

(define (again [item : (&mut item i64)]) : (&mut item i64)
  (forward item))

(define (main) : i64
  (let
    [value : i64 0]
    [reference : (&mut value i64) (again (&mut value))]
    (set! (deref reference) 42)
    value))