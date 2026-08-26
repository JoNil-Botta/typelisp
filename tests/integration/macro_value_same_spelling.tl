;; Values and macros occupy distinct namespaces. Expression operands resolve the
;; value while a call head with the same spelling resolves the macro, regardless
;; of declaration order.
(module macro_value_same_spelling)

(define same : i64
  40)

(defmacro (same [value : Expr]) : Expr
  `(+ ,value 2))

(defmacro (other [value : Expr]) : Expr
  `(+ ,value 1))

(define other : i64
  41)

(define (main) : i64
  (if (and (= (same same) 42) (= (other other) 42))
    42
    1))