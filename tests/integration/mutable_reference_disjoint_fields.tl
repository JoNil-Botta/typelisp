;; #3175: simultaneous mutable borrows of disjoint storage-backed struct fields
;; are accepted and remain usable through ordinary array operations.
(defstruct Bags
  (left (Array i64))
  (right (Array i64)))

(define (set-both
  [left : (&mut bags (Array i64))]
  [right : (&mut bags (Array i64))]) : i64
  (begin
    (array-set! left 0 18)
    (array-set! right 0 24)
    (+ (array-ref left 0) (array-ref right 0))))

(define (main) : i64
  (let
    [left-items : (Array i64) (make-array i64 1)]
    [right-items : (Array i64) (make-array i64 1)]
    [bags : Bags (Bags left-items right-items)]
    (set-both (&mut (struct-get bags left)) (&mut (struct-get bags right)))))