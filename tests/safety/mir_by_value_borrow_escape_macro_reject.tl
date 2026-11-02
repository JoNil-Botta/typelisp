;; Returned mutable borrows cannot retain by-value call scratch (#8897).
(define (forward [value : (&mut value i64)]) : (&mut value i64)
  value)

(defmacro (forward-place [place : Expr]) : Expr
  `(forward (&mut ,place)))

(define (main) : i64
  (let
    [value : i64 0]
    [reference : (&mut value i64) (forward-place value)]
    (set! (deref reference) 42)
    value))