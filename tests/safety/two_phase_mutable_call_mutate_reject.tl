;: SPEC borrow contract: compatibility dynamic-array owner mutation during a
;: call-argument reservation is rejected (#3581 keeps this surface staged).
(import stdlib.array)

(define (take-mut-and-value [items : (&mut items (Array i64))] [value : i64]) : unit
  unit)

(define (main) : unit
  (let
    [items : (Array i64) (array.make-array i64 1)]
    (take-mut-and-value
      (&mut items)
      (begin
        (array.array-push! items 1)
        0))))