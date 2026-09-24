;; A generated module's own generated import is checked even though nothing
;; demands its declaration.
(defmacro (nested-inner [T : type (:kind i64 u8)]) : Module
  (let
    [module-name : Expr
      (expr-var (string-append "generated.nested_inner." (type-key T)))]
    `(begin
      (module ,module-name)
      (define (unused-inner-invalid) : ,T
        300))))

(defmacro (nested-outer [T : type (:kind i64 u8)]) : Module
  (let
    [module-name : Expr
      (expr-var (string-append "generated.nested_outer." (type-key T)))]
    `(begin
      (module ,module-name)
      (import (nested-inner ,T) as inner))))

(import (nested-outer i64) as nested_i64)
(import (nested-outer u8) as nested_u8)

(define (main) : i64
  42)