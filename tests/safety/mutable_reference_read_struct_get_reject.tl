;: SPEC borrow contract: field reads conflict with an overlapping live mutable
;: field borrow.
(import stdlib.array)

(defstruct Bag
  (left (__tl_dyn-array i64))
  (right i64))

(define (main) : i64
  (let
    [items : (__tl_dyn-array i64) (array.make-array i64 1)]
    [bag : Bag (Bag items 42)]
    [borrowed : (&mut bag (__tl_dyn-array i64)) (&mut (struct-get bag left))]
    [copy : (__tl_dyn-array i64) (struct-get bag left)]
    (begin
      (array-set! borrowed 0 41)
      (array-length copy))))