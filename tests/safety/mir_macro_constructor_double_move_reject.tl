;: A constructor a macro expands to consumes its arguments like a direct one.
(defstruct Owned
  (items (__tl_dyn-array i64)))

(defenum Pair
  (Two (Box Owned) (Box Owned))
  (None))

(defmacro (pair-of [value : Expr]) : Expr
  `(Pair.Two (box ,value) (box ,value)))

(define (make [value : Owned]) : Pair
  (pair-of value))

(define (main) : i64
  0)