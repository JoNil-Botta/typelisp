;; A field store retains the inner check after resolving a grown outer array.
(import stdlib.io)

(defstruct Pair
  (a i64)
  (b i64))

(defstruct Row
  (tag i64)
  (cells (Array Pair 3)))

(define (main) : i64
  (let
    [a : (__tl_dyn-array Row) (__tl_make-array Row 1)]
    [j : i64 3]
    (set!
      (array-ref (array-ref a 0).cells j).b
      (begin
        (__tl_array-push! a (Row 2 (array (Pair 4 5) (Pair 6 7) (Pair 8 9))))
        (io.println "RHS grew")
        (set! j 0)
        70))
    0))