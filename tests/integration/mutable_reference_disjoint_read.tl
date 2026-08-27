;; #3176: a live mutable borrow of one struct field does not block direct reads
;; of a disjoint sibling field.
(defstruct Bag
  (left (__tl_dyn-array i64))
  (right i64))

(define (main) : i64
  (let
    [items : (__tl_dyn-array i64) (__tl_make-array i64 1)]
    [bag : Bag (Bag items 42)]
    [borrowed : (&mut bag (__tl_dyn-array i64)) (&mut bag.left)]
    [right : i64 bag.right]
    (begin
      (set! (array-ref borrowed 0) 41)
      right)))