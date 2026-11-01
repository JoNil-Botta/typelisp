;: Projections out of a call result read, move and write a temporary in place.
(defstruct Pair
  (left (__tl_dyn-array i64))
  (right i64))

(define (make) : Pair
  (Pair (__tl_make-array i64 3) 4))

(define (read-field) : i64
  (+ (make).right (array-ref (make).left 0) (array-length (make).left)))

(define (take-field) : (__tl_dyn-array i64)
  (make).left)

(define (write-field) : i64
  (begin
    (set! (array-ref (make).left 0) 5)
    38))

(define (main) : i64
  (+ (read-field) (array-length (take-field)) (write-field) 1))