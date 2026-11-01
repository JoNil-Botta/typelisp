(import macro_struct_pattern_defs as defs)

(defstruct RootPair
  (marker bool)
  (left i64)
  (right i64))

(defmacro (root-pair-sum [value : Expr]) : Expr
  `(match ,value
    [(RootPair _ a b) (+ a b)]))

(define (main [pair : defs.Pair]) : i64
  (root-pair-sum pair))