;; Template binding-clause hygiene follows the callee that expansion selects,
;; including a callee head the caller supplies, a use-site macro that shadows a
;; prelude name, and a binding-clause parameter whose type is a selected alias.
(import stdlib.comptime)
(import stdlib.comptime.ExprBindingClause as Binding)

(define flag : bool
  true)

;; This module's `for` takes an ExprClause, not the prelude's ExprBindingClause,
;; so the template's `[flag 99]` is a clause expression naming the global.
(defmacro (for [clause : ExprClause] [body : Expr]) : i64
  (let
    [test : comptime.Expr (comptime.expr-clause-first clause)]
    `(if ,test
      ,body
      0)))

(defmacro (bind-one [binding : ExprBindingClause] [body : Expr]) : i64
  (comptime.expr-let-scope
    (comptime.expr-binding-clause-name binding)
    (comptime.expr-binding-clause-init binding)
    body))

;; The parameter type resolves to ExprBindingClause through the alias.
(defmacro (bind-aliased [binding : Binding] [body : Expr]) : i64
  (comptime.expr-let-scope
    (comptime.expr-binding-clause-name binding)
    (comptime.expr-binding-clause-init binding)
    body))

(defmacro (aliased-binder [body : Expr]) : i64
  `(bind-aliased [i (cast 3 : i64)] ,body))

;; The caller names the callee; the clause and its binder are template syntax.
(defmacro (call-with-clause [callee : Expr] [body : Expr]) : i64
  `(,callee [flag 99] ,body))

(defmacro (call-with-binder [callee : Expr] [body : Expr]) : i64
  `(,callee [i (cast 3 : i64)] ,body))

(define (main) : i64
  (let
    [i : i64 40]
    (if (and
      (= (call-with-clause for 42) 42)
      ;; The template's `i` binds only template syntax; the caller's `i` is 40.
      (= (call-with-binder bind-one i) 40)
      (= (aliased-binder i) 40))
      42
      1)))