;; A fixed i64 let annotation rejects the value of a later u8 identity.
(defmacro (fixed-local-annotation [T : type (:kind i64 u8)]) : Module
  (let
    [module-name : Expr
      (expr-var
        (string-append "generated.fixed_local_annotation." (type-key T)))]
    `(begin
      (module ,module-name)
      (define (fixed-local-annotation [x : ,T]) : ,T
        (let
          [y : i64 x]
          y)))))

(import (fixed-local-annotation i64) as fixed_i64)
(import (fixed-local-annotation u8) as fixed_u8)

(define (main) : i64
  42)