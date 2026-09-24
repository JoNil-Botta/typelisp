;; A constructor field fixed at i64 rejects the argument of a later u8 identity.
(defmacro (fixed-constructor-argument [T : type (:kind i64 u8)]) : Module
  (let
    [module-name : Expr
      (expr-var
        (string-append "generated.fixed_constructor_argument." (type-key T)))]
    `(begin
      (module ,module-name)
      (defstruct Box
        (fixed i64)
        (payload ,T))
      (define (fixed-constructor-argument [x : ,T]) : Box
        (Box x x)))))

(import (fixed-constructor-argument i64) as fixed_i64)
(import (fixed-constructor-argument u8) as fixed_u8)

(define (main) : i64
  42)