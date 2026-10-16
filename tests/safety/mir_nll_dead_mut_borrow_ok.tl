;: Non-lexical lifetimes: a mutable borrow that is never used again ends at
;: once, so a second mutable borrow of the same field is accepted.
(defstruct Bags
  (left (__tl_dyn-array i64))
  (right (__tl_dyn-array i64)))

(define (main) : i64
  (let
    [bags : Bags (Bags (__tl_make-array i64 1) (__tl_make-array i64 1))]
    [first : (&mut bags (__tl_dyn-array i64)) (&mut bags.left)]
    [second : (&mut bags (__tl_dyn-array i64)) (&mut bags.left)]
    (begin
      (__tl_array-push! second 40)
      (+ (array-length bags.left) (array-ref bags.left 1)))))