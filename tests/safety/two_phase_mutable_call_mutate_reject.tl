;: SPEC borrow contract: owner mutation during a call-argument reservation is rejected.
(define (take-mut-and-value [items : (&mut items (Array i64))] [value : i64]) : unit
  unit)

(define (main) : unit
  (let
    [items : (Array i64) (make-array i64 1)]
    (take-mut-and-value
      (&mut items)
      (begin
        (array-push! items 1)
        0))))