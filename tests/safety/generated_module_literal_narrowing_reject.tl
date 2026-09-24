;; A literal that fits the first identity is rejected for a narrower later one.
(defmacro (literal-narrowing [T : type (:kind i64 u8)]) : Module
  (let
    [module-name : Expr
      (expr-var (string-append "generated.literal_narrowing." (type-key T)))]
    `(begin
      (module ,module-name)
      (define (big) : ,T
        300))))

(import (literal-narrowing i64) as literal_i64)
(import (literal-narrowing u8) as literal_u8)

(define (main) : i64
  42)