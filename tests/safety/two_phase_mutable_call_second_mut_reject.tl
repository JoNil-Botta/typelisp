;: SPEC borrow contract: a reservation rejects a second overlapping mutable borrow.
(define (take-two
  [left : (&mut left (Array i64))]
  [right : (&mut right (Array i64))]) : unit
  unit)

(define (main) : unit
  (let
    [items : (Array i64) (make-array i64 1)]
    (take-two (&mut items) (&mut items))))