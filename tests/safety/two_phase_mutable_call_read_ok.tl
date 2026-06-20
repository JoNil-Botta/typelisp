;: SPEC safe-code contract: call-argument mutable borrows reserve before activation.
(define (read-len [items : (& items (Array i64))]) : i64
  (array-length items))

(define (push-with-len [items : (&mut items (Array i64))] [value : i64]) : unit
  (array-push! items value))

(define (main) : i64
  (let
    [items : (Array i64) (make-array i64 1)]
    (begin
      (push-with-len (&mut items) (read-len (& items)))
      (push-with-len (&mut items) (array-length items))
      (array-length items))))