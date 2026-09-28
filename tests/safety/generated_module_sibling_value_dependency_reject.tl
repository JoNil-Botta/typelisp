;; A generated value is checked against the sibling helper of its own identity.
(import stdlib.comptime)
(import stdlib.string)

(defmacro (sibling-value [T : type (:kind i64 i32)] [flavor : String]) : Module
  (let
    [flavor-text : String (comptime.expr-string-value flavor)]
    [module-name : Expr
      (expr-var
        (string-append
          (string-append
            (string-append "generated.sibling_value." (type-key T))
            ".")
          flavor-text))]
    (if (string.eq flavor-text "integer")
      `(begin
        (module ,module-name)
        (define (helper) : i64
          1)
        (define shared
          (+ (helper) 1)))
      `(begin
        (module ,module-name)
        (define (helper) : bool
          true)
        (define shared
          (+ (helper) 1))))))

(import (sibling-value i64 "integer") as first)
(import (sibling-value i32 "boolean") as second)

(define (main) : i64
  0)