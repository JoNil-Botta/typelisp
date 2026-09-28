;; A value fixed at i64 does not satisfy a later u8 return type.
(defmacro (fixed-value [T : type (:kind i64 u8)]) : Module
  (let
    [module-name : Expr
      (expr-var (string-append "generated.fixed_value." (type-key T)))]
    `(begin
      (module ,module-name)
      (define fixed-value-i64 : i64
        42)
      (define (fixed-value [x : ,T]) : ,T
        fixed-value-i64))))

(import (fixed-value i64) as fixed_i64)
(import (fixed-value u8) as fixed_u8)

(define (main) : i64
  42)