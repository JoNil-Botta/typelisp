;# Generic recoverable-error result module macro.
;#
;# Import with `(import stdlib.result)`, then instantiate a concrete module
;# with `(import (result.result i64 String) as result_i64_string)`.
(import stdlib.comptime)

;: Emit a generated recoverable-error result module for success type `T` and
;: error type `E`.
(defmacro (result [T : type] [E : type]) : Module
  (let
    [module-name : Expr
      (expr-var
        (comptime.string-append
          (comptime.string-append "stdlib.result.generated." (type-key T))
          (comptime.string-append "." (type-key E))))]
    [result-name : Expr (expr-var "Result")]
    [ok-name : Expr (expr-var "Ok")]
    [err-name : Expr (expr-var "Err")]
    `(begin
      (module ,module-name)
      (defenum ,result-name
        (Ok ,T)
        (Err ,E))
      (define (ok [value : ,T]) : ,result-name
        (,ok-name value))
      (define (err [error : ,E]) : ,result-name
        (,err-name error))
      (define (is-ok? [value : (& value ,result-name)]) : bool
        (match value
          [(Ok _) true]
          [(Err _) false]))
      (define (is-err? [value : (& value ,result-name)]) : bool
        (match value
          [(Ok _) false]
          [(Err _) true]))
      (define (value-or [value : ,result-name] [fallback : ,T]) : ,T
        (match value
          [(Ok inner) inner]
          [(Err _) fallback]))
      (define (map [value : ,result-name] [mapper : (-> ,T ,T)]) : ,result-name
        (match value
          [(Ok inner) (ok (mapper inner))]
          [(Err error) (err error)])))))