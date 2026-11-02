;; Array element storage persists after a returned-borrow call (#8897).
(define (forward [place : (&mut place i64)]) : (&mut place i64)
  place)

(define (main) : i64
  (let
    [values : (Array i64 2) (make-array i64 2)]
    [reference : (&mut values i64) (forward (&mut (array-ref values 0)))]
    (set! (deref reference) 42)
    (array-ref values 0)))