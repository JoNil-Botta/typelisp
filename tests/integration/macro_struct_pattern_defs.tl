;; The caller declares another Pair; macro heads retain this module's owner.
(module macro_struct_pattern_defs)

(defstruct Pair
  (marker bool)
  (left i64)
  (right i64))

(defmacro (pair-sum [value : Expr]) : Expr
  `(match ,value
    [(Pair _ a b) (+ a b)]))

(defmacro (pair-named-sum [value : Expr]) : Expr
  `(match ,value
    [(fields [b right] [a left]) (+ a b)]))