;: SPEC borrow contract: compatibility dynamic-array shared borrow created
;: during reservation cannot escape activation (#3581 keeps this surface staged).
(import stdlib.array)

(define (borrow-items [items : (& items (__tl_dyn-array i64))]) : (&
    items
    (__tl_dyn-array i64))
  items)

(define (take-mut-and-view
  [items : (&mut items (__tl_dyn-array i64))]
  [view : (& items (__tl_dyn-array i64))]) : unit
  unit)

(define (main) : unit
  (let
    [items : (__tl_dyn-array i64) (array.make-array i64 1)]
    (take-mut-and-view (&mut items) (borrow-items (& items)))))