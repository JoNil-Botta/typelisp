;: SPEC borrow contract: compatibility dynamic-array reservation rejects a
;: second overlapping mutable borrow (#3581 keeps this surface staged).
(import stdlib.array)

(define (take-two
  [left : (&mut left (Array i64))]
  [right : (&mut right (Array i64))]) : unit
  unit)

(define (main) : unit
  (let
    [items : (Array i64) (array.make-array i64 1)]
    (take-two (&mut items) (&mut items))))