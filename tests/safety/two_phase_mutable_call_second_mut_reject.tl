;: SPEC borrow contract: compatibility dynamic-array reservation rejects a
;: second overlapping mutable borrow (#3581 keeps this surface staged).
(import stdlib.array)

(define (take-two
  [left : (&mut left (__tl_dyn-array i64))]
  [right : (&mut right (__tl_dyn-array i64))]) : unit
  unit)

(define (main) : unit
  (let
    [items : (__tl_dyn-array i64) (array.make-array i64 1)]
    (take-two (&mut items) (&mut items))))