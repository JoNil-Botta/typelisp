;; #9052: as arena_clone_escape_reject, cloning through a reference.
(defstruct Cell
  (items (__tl_dyn-array i64)))

(define (first [c : (& c Cell)]) : i64
  (array-ref c.items 0))

(define (f [r : (& r Cell)]) : Cell
  (with-arena phase (clone (deref r))))

(define (main) : i64
  (let
    [src : Cell (Cell (__tl_make-array 7))]
    [out : Cell (f (& src))]
    [reuse : i64
      (with-arena again (first (& (Cell (__tl_make-array 5 5 5 5 5 5 5 5)))))]
    (if (= (first (& out)) 7)
      42
      1)))