;; A fixed i64 return type rejects the parameter of a later u8 identity.
(defmacro (fixed-return [T : type (:kind i64 u8)]) : Module
  (let
    [module-name : Expr
      (expr-var (string-append "generated.fixed_return." (type-key T)))]
    `(begin
      (module ,module-name)
      (define (fixed-return [x : ,T]) : i64
        x))))

(import (fixed-return i64) as fixed_i64)
(import (fixed-return u8) as fixed_u8)

(define (main) : i64
  42)