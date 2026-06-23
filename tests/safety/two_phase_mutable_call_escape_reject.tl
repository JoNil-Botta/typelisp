;: SPEC borrow contract: compatibility dynamic-array shared borrow created
;: during reservation cannot escape activation (#3581 keeps this surface staged).
(define (borrow-items [items : (& items (Array i64))]) : (& items (Array i64))
  items)

(define (take-mut-and-view
  [items : (&mut items (Array i64))]
  [view : (& items (Array i64))]) : unit
  unit)

(define (main) : unit
  (let
    [items : (Array i64) (make-array i64 1)]
    (take-mut-and-view (&mut items) (borrow-items (& items)))))