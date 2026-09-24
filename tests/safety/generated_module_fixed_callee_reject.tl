;; A callee fixed at i64 rejects the argument of a later u8 identity.
(defmacro (fixed-callee [T : type (:kind i64 u8)]) : Module
  (let
    [module-name : Expr
      (expr-var (string-append "generated.fixed_callee." (type-key T)))]
    `(begin
      (module ,module-name)
      (define (fixed-callee-only-i64 [x : i64]) : i64
        x)
      (define (fixed-callee-caller [x : ,T]) : ,T
        (fixed-callee-only-i64 x)))))

(import (fixed-callee i64) as fixed_i64)
(import (fixed-callee u8) as fixed_u8)

(define (main) : i64
  42)