;; A fixed i64 field does not satisfy a later u8 return type.
(defmacro (fixed-field-access [T : type (:kind i64 u8)]) : Module
  (let
    [module-name : Expr
      (expr-var (string-append "generated.fixed_field_access." (type-key T)))]
    `(begin
      (module ,module-name)
      (defstruct Box
        (fixed i64)
        (payload ,T))
      (define (fixed-field-access [value : Box]) : ,T
        value.fixed))))

(import (fixed-field-access i64) as fixed_i64)
(import (fixed-field-access u8) as fixed_u8)

(define (main) : i64
  42)