;; Generated identities of one macro may produce different sibling catalogs.
(import stdlib.comptime)
(import stdlib.string)

(defmacro (partial-catalog [T : type (:kind i64 i32)] [extra : String]) : Module
  (let
    [extra-text : String (comptime.expr-string-value extra)]
    [module-name : Expr
      (expr-var
        (string-append
          (string-append "generated.partial_catalog." (type-key T))
          (if (string.eq extra-text "extra")
            ".extra"
            ".base")))]
    (if (string.eq extra-text "extra")
      `(begin
        (module ,module-name)
        (defstruct Box
          (value ,T))
        (define (identity [x : ,T]) : ,T
          x)
        (define partial-catalog-extra : i64
          0))
      `(begin
        (module ,module-name)
        (defstruct Box
          (value ,T))
        (define (identity [x : ,T]) : ,T
          x)))))

(import (partial-catalog i64 "extra") as partial_i64)
(import (partial-catalog i32 "base") as partial_i32)

(define partial-i64-value : i64
  (partial_i64.identity 7))
(define partial-i32-value : i32
  (partial_i32.identity 7))

(define (main) : i64
  (+ partial-i64-value (cast partial-i32-value : i64)))