;; A reflection-selected generated body keeps its fixed-array element check.
(defmacro (reflection-fixed-shape [T : type (:kind i64 bool)]) : Module
  (let
    [module-name : Expr
      (expr-var
        (string-append "generated.reflection_fixed_shape." (type-key T)))]
    (if (__tl_string_eq (type-kind T) "i64")
      `(begin
        (module ,module-name)
        (define fixed : (Array i64 2)
          (array 1 2)))
      `(begin
        (module ,module-name)
        (define fixed : (Array i64 2)
          (array 1 true))))))

(import (reflection-fixed-shape i64) as fixed_i64)
(import (reflection-fixed-shape bool) as fixed_bool)

(define (main) : i64
  42)