;; #3175: simultaneous mutable borrows of disjoint storage-backed struct fields
;; are accepted and remain usable through ordinary array operations.
(defstruct Bags
  (left (__tl_dyn-array i64))
  (right (__tl_dyn-array i64)))

(define (set-both
  [left : (&mut bags (__tl_dyn-array i64))]
  [right : (&mut bags (__tl_dyn-array i64))]) : i64
  (begin
    (set! (array-ref left 0) 18)
    (set! (array-ref right 0) 24)
    (+ (array-ref left 0) (array-ref right 0))))

(define (main) : i64
  (let
    [left-items : (__tl_dyn-array i64) (__tl_make-array i64 1)]
    [right-items : (__tl_dyn-array i64) (__tl_make-array i64 1)]
    [bags : Bags (Bags left-items right-items)]
    (set-both (&mut bags.left) (&mut bags.right))))