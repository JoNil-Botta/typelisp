;# Generated scalar equality modules.
;: Generate an equality module for concrete scalar type `T`.
(defmacro (eq [T : type]) : Module
  (let
    [module-name : Expr
      (expr-var (string-append "stdlib.eq.generated." (type-key T)))]
    [body : Expr
      (match (type-kind T)
        ["string" `(__tl_string_eq left right)]
        ["unit" `true]
        [_ `(= left right)])]
    `(begin
      (module ,module-name)
      (define (eq [left : ,T] [right : ,T]) : bool
        ,body)
      (define (eq? [left : ,T] [right : ,T]) : bool
        ,body))))