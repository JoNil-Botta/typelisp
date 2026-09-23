(defmacro (bad-declarations) : Decls
  (let
    [head : Expr (expr-var "cfg")]
    [predicate : Expr
      (expr-call
        (expr-var "not")
        (expr-list-cons
          (expr-var "linux")
          (expr-list-cons (expr-var "windows") (expr-list-empty))))]
    `(,head
      ,predicate
      (define (answer) : i64
        42))))

(defmacro (bad-module) : Module
  (let
    [head : Expr (expr-var "cfg")]
    [predicate : Expr
      (expr-call
        (expr-var "not")
        (expr-list-cons
          (expr-var "linux")
          (expr-list-cons (expr-var "windows") (expr-list-empty))))]
    `(begin
      (module generated.bad_cfg)
      (,head
        ,predicate
        (define (answer) : i64
          42)))))

(cfg linux (bad-declarations))

(cfg windows (import (bad-module) as configured))

(define (main) : i64
  42)