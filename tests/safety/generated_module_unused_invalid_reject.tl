;; An unreferenced declaration in a generated module is still typechecked.
(defmacro (unused-invalid [T : type (:kind i64 u8)]) : Module
  (let
    [module-name : Expr
      (expr-var (string-append "generated.unused_invalid." (type-key T)))]
    `(begin
      (module ,module-name)
      (define (unused-invalid-value) : ,T
        300))))

(import (unused-invalid u8) as unused_invalid)

(define (main) : i64
  42)