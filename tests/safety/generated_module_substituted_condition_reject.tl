;; An if condition of a later u8 identity must still be bool.
(defmacro (substituted-condition [T : type (:kind bool u8)]) : Module
  (let
    [module-name : Expr
      (expr-var (string-append "generated.substituted_condition." (type-key T)))]
    `(begin
      (module ,module-name)
      (define (substituted-condition [x : ,T]) : ,T
        (if x
          x
          x)))))

(import (substituted-condition bool) as condition_bool)
(import (substituted-condition u8) as condition_u8)

(define (main) : i64
  42)