;; Retain the header-less, root-module reproducer as well as its direct control.
(import string)

(defstruct Pair
  (left i64)
  (right i64))

(defstruct Label
  (text String)
  (extra i64))

(defenum Item
  (PairItem Pair)
  (LabelItem Label))

(defmacro (pair-sum [value : Expr]) : Expr
  `(match ,value
    [(Pair a b) (+ a b)]))

(defmacro (item-score [value : Expr]) : Expr
  `(match ,value
    [(PairItem (Pair a b)) (+ a b)]
    [(LabelItem (Label text extra)) (+ (string.string-length text) extra)]))

(define (main) : i64
  (let
    [pair : Pair (Pair 20 22)]
    [pair-item : Item (PairItem (Pair 20 22))]
    [label-item : Item (LabelItem (Label "abc" 39))]
    (unless
      (=
        (match pair
          [(Pair a b) (+ a b)])
        42)
      (return 1))
    (unless (= (pair-sum pair) 42) (return 2))
    (unless (= (pair-sum (& pair)) 42) (return 3))
    (unless
      (=
        (match (& label-item)
          [(PairItem (Pair a b)) (+ a b)]
          [(LabelItem (Label text extra)) (+ (string.string-length text) extra)])
        42)
      (return 4))
    (unless (= (item-score (& pair-item)) 42) (return 5))
    (unless (= (item-score pair-item) 42) (return 6))
    (unless (= (item-score (& label-item)) 42) (return 7))
    (unless (= (item-score label-item) 42) (return 8))
    42))