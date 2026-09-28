;; Equality over each generated identity typechecks.
(defmacro (equality [T : type (:kind i64 u8)]) : Module
  (let
    [module-name : Expr
      (expr-var (string-append "generated.equality." (type-key T)))]
    `(begin
      (module ,module-name)
      (define (same [a : ,T] [b : ,T]) : bool
        (= a b)))))

(import (equality i64) as equality_i64)
(import (equality u8) as equality_u8)

(define (main) : i64
  42)