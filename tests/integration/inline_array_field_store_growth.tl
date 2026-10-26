;; A store through an inline fixed-array field of a dynamic-array element
;; targets the buffer current after the value (#9057).
(import stdlib.test)

(defstruct Pair
  (a i64)
  (b i64))

(defstruct Row
  (tag i64)
  (cells (Array i64 3)))

(defstruct PairRow
  (tag i64)
  (cells (Array Pair 2)))

(define (row-growth) : unit
  (let
    [a : (__tl_dyn-array Row) (__tl_make-array Row 1)]
    [j : i64 2]
    (set! (array-ref a 0) (Row 1 (array 10 20 30)))
    (set!
      (array-ref (array-ref a 0).cells j)
      (begin
        (__tl_array-push! a (Row 2 (array 40 50 60)))
        (set! j 0)
        70))
    (test.assert-i64-eq (array-ref (array-ref a 0).cells 2) 70 "inline element")
    (test.assert-i64-eq (array-ref (array-ref a 0).cells 0) 10 "inline sibling")
    (test.assert-i64-eq (array-ref (array-ref a 1).cells 2) 60 "appended row")))

(define (pair-row-growth) : unit
  (let
    [a : (__tl_dyn-array PairRow) (__tl_make-array PairRow 1)]
    (set! (array-ref a 0) (PairRow 1 (array (Pair 1 2) (Pair 3 4))))
    (set!
      (array-ref (array-ref a 0).cells 1).b
      (begin
        (__tl_array-push! a (PairRow 2 (array (Pair 5 6) (Pair 7 8))))
        (__tl_array-push! a (PairRow 3 (array (Pair 9 10) (Pair 11 12))))
        70))
    (test.assert-i64-eq (array-ref (array-ref a 0).cells 1).b 70 "inline field")
    (test.assert-i64-eq
      (array-ref (array-ref a 0).cells 1).a
      3
      "inline field sibling")
    (test.assert-i64-eq
      (array-ref (array-ref a 2).cells 1).b
      12
      "appended pair row")))

(define (main) : i64
  (row-growth)
  (pair-row-growth)
  42)