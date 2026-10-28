;; Retain the header-less, root-module reproducer as well as its direct control.
(defstruct Pair
  (left i64)
  (right i64))

(defmacro (pair-sum [value : Expr]) : Expr
  `(match ,value
    [(Pair a b) (+ a b)]))

(define (main) : i64
  (let
    [pair : Pair (Pair 20 22)]
    (unless
      (=
        (match pair
          [(Pair a b) (+ a b)])
        42)
      (return 1))
    (unless (= (pair-sum pair) 42) (return 2))
    (unless (= (pair-sum (& pair)) 42) (return 3))
    42))