;: SPEC borrow contract: disjoint sibling field reads are allowed while another
;: sibling field is mutably borrowed.
(import stdlib.array)

(defstruct Bag
  (left (__tl_dyn-array i64))
  (right i64))

(define (main) : i64
  (let
    [items : (__tl_dyn-array i64) (array.make-array i64 1)]
    [bag : Bag (Bag items 42)]
    [borrowed : (&mut bag (__tl_dyn-array i64)) (&mut (struct-get bag left))]
    [right : i64 (struct-get bag right)]
    (begin
      (array-set! borrowed 0 41)
      right)))