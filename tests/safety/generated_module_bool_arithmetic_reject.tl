;; Arithmetic that is valid for the first identity is rejected for bool.
(defmacro (bool-arithmetic [T : type (:kind i64 bool)]) : Module
  (let
    [module-name : Expr
      (expr-var (string-append "generated.bool_arithmetic." (type-key T)))]
    `(begin
      (module ,module-name)
      (define (plus-one [x : ,T]) : ,T
        (+ x 1)))))

(import (bool-arithmetic i64) as arithmetic_i64)
(import (bool-arithmetic bool) as arithmetic_bool)

(define (main) : i64
  42)