;; Returned mutable borrows cannot retain by-value call scratch (#8897).
(define (forward [value : (&mut value i64)]) : (&mut value i64)
  value)

(define (nested [item : (&mut item i64)]) : (Tuple (&mut item i64) i64)
  (tuple item 0))

(define (main) : i64
  (let
    [value : i64 0]
    [reference : (Tuple (&mut value i64) i64) (nested (&mut value))]
    (set! (deref (tuple-ref reference 0)) 42)
    value))