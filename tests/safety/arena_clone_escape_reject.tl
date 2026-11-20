;; #9052: a clone inside an arena is allocated there and carries its region.
(defstruct Cell
  (items (__tl_dyn-array i64)))

(define (first [c : (& c Cell)]) : i64
  (array-ref c.items 0))

(define (f [x : Cell]) : Cell
  (with-arena phase (clone x)))

(define (main) : i64
  (let
    [out : Cell (f (Cell (__tl_make-array 7)))]
    [reuse : i64
      (with-arena again (first (& (Cell (__tl_make-array 5 5 5 5 5 5 5 5)))))]
    (if (= (first (& out)) 7)
      42
      1)))